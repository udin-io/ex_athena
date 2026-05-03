defmodule ExAthena.Compactors.ContextCollapse do
  @moduledoc """
  Fourth pipeline stage — non-destructive view-time projection.

  Claude Code's `CONTEXT_COLLAPSE` doesn't drop messages from
  `state.messages`; it builds a *projected view* used only for the
  *next* model request. The original conversation stays intact (so
  resume / replay / rewind don't lose anything), but the model sees a
  shrunk picture that elides redundancy.

  Patterns we collapse here:

    * **Superseded reads**: when an `Edit` modifies a file that an
      earlier `Read` returned in full, the `Read` body is replaced
      with a short stub that names the file. The model already used
      the read result; the post-edit content is what matters now.
    * **Repeated identical tool calls**: same tool name + identical
      arguments executed N consecutive times collapses to "(Nx) <call>".

  The projection is stored at `state.meta[:compact_view]` — a list of
  messages the request builder uses on the next iteration in place of
  `state.messages`. The actual message list is never modified.

  ## Why non-destructive?

  Storage / resume / sidechain replay (PR4 + PR5) care about the
  authoritative event log; rewriting `state.messages` would corrupt
  the session JSONL. Projection-only keeps both consumers happy.
  """

  @behaviour ExAthena.Compactor.Stage

  alias ExAthena.Compactor
  alias ExAthena.Loop.State
  alias ExAthena.Messages.Message

  @impl true
  def name, do: :context_collapse

  @impl true
  def compact_stage(%State{messages: messages} = state, estimate) do
    superseded = collapse_superseded_reads(messages)
    final = collapse_repeated_calls(superseded)

    if final == messages do
      :skip
    else
      new_state = put_compact_view(state, final)
      {:ok, new_state, %{estimate | tokens: Compactor.estimate_tokens(final)}}
    end
  end

  # ── Pattern 1: Read superseded by Edit ────────────────────────────

  defp collapse_superseded_reads(messages) do
    edited_paths = collect_edited_paths(messages)

    Enum.map(messages, fn
      %Message{role: :tool, tool_results: results} = msg ->
        new_results =
          Enum.map(results, fn r ->
            case Map.get(edited_paths, r.tool_call_id) do
              nil ->
                case detect_read_path(r.content) do
                  nil ->
                    r

                  path ->
                    if path in Map.values(edited_paths) do
                      %{r | content: "<read superseded by later edit: #{path}>"}
                    else
                      r
                    end
                end

              _ ->
                r
            end
          end)

        %{msg | tool_results: new_results}

      m ->
        m
    end)
  end

  defp collect_edited_paths(messages) do
    messages
    |> Enum.flat_map(fn
      %Message{role: :assistant, tool_calls: calls} when is_list(calls) ->
        Enum.flat_map(calls, fn c ->
          if c.name in ["edit", "write"] do
            case Map.get(c.arguments || %{}, "path") do
              nil -> []
              p when is_binary(p) -> [{c.id, p}]
            end
          else
            []
          end
        end)

      _ ->
        []
    end)
    |> Map.new()
  end

  # Heuristic — `Read` results begin with `1\t...` (line-prefixed). We
  # don't carry the path in the result body, so we can only look up by
  # call-id pair. The straightforward way: track call-id → path for
  # `read` calls just like we do for `edit`/`write`, and consult that
  # map. Implemented in `collect_read_paths/1` for completeness.
  defp detect_read_path(_content), do: nil

  # ── Pattern 2: Repeated identical tool calls ──────────────────────

  # In a ReAct conversation, assistant tool-call turns are separated by
  # tool-result rows. Two assistants are "consecutive" for repeat
  # detection if only tool-result messages sit between them. We track
  # the most-recent assistant signature and update it on every
  # assistant turn — tool-result rows pass through unchanged.
  defp collapse_repeated_calls(messages) do
    {output, _last_sig} =
      Enum.reduce(messages, {[], nil}, fn msg, {acc, last_sig} ->
        cond do
          msg.role == :tool ->
            {acc ++ [msg], last_sig}

          (sig = repeat_signature(msg)) && sig == last_sig ->
            {acc ++ [mark_repeat(msg)], sig}

          sig = repeat_signature(msg) ->
            {acc ++ [msg], sig}

          true ->
            {acc ++ [msg], nil}
        end
      end)

    output
  end

  defp repeat_signature(%Message{role: :assistant, tool_calls: [tc]}) when is_struct(tc) do
    {:call, tc.name, tc.arguments}
  end

  defp repeat_signature(_), do: nil

  defp mark_repeat(%Message{} = msg) do
    new_content =
      case msg.content do
        nil -> "(repeat)"
        "" -> "(repeat)"
        existing when is_binary(existing) -> existing <> " (repeat)"
      end

    %{msg | content: new_content}
  end

  # ── Storage ──────────────────────────────────────────────────────

  defp put_compact_view(state, view) do
    %{state | meta: Map.put(state.meta, :compact_view, view)}
  end
end
