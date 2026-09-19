defmodule ExAthena.Agents.Transcript do
  @moduledoc """
  What a worker SAID, written to disk while it is still saying it.

  `ExAthena.Agents.Journal` records what a worker DID and refuses prose on
  purpose. This is the other half: one line per conversational turn, carrying
  that turn's text. Together they sit in the same session directory, written by
  the same `on_event` wrapper style, and neither is a copy of the other.

  ## Why it cannot wait for the Result

  A worker's report used to be `Result.text` — its last non-blank assistant
  message. A worker that writes its report at turn 19 and signs off at turn 20
  with "delivered in the previous turn" hands back the sign-off, and
  `Result.messages` cannot be consulted for the rest: `Compactors.Summary`
  replaces everything between the pinned prefix and the live suffix with one
  digest, and `Compactors.EpisodicArchive` keeps the sliced text in
  `state.meta` — in memory, dying with the process. The prose has to leave the
  process as it is produced or not at all (issue 251).

  ## Why one line per turn, and not per `{:content, _}`

  `{:content, _}` is one event per token under streaming and one per turn
  without it — `ExAthena.Modes.ReAct.handle_turn/5` suppresses the end-of-turn
  emission when deltas already streamed. Keying on it would mean one
  open/write/close per token. `ExAthena.Loop.Inference.call/3` emits
  `{:assistant_turn, …}` once per turn with the whole text instead, and that is
  the only event this writer keeps.

  ## Why the writer holds no state

  The same reason the journal's does: `on_event` is invoked from inside
  `Task.async_stream` tasks when tool calls run concurrently, so there is no
  single process to hang a buffer on. One `stat` and one open/write/close per
  line buys a writer that cannot lose buffered prose when the process it runs
  in is brutal-killed — which is exactly the worker whose prose is worth
  having.

  A kill between formatting a line and writing it loses that line, and a large
  line can be torn. Hence NDJSON, and hence `read/1` drops a line it cannot
  decode rather than raising.
  """

  alias ExAthena.Agents.Sidechain
  alias ExAthena.Tuning

  # Prose is bulkier than the journal's digests, so this is 2x the journal's
  # cap. A runaway guard, not a budget: the largest worker observed in session
  # 5906635b743d produced roughly 30 KB of journal and well under 1 MB of text.
  @default_bytes 4_000_000

  # One turn. Long enough for a full codebase map written in a single message
  # (the 18k-character case this ticket exists for), short enough that a model
  # dumping a binary into the text channel cannot fill the file in one line.
  @default_line_chars 20_000

  @doc """
  Where one worker's transcript lives: beside its journal, under the PARENT's
  session directory.

  Separate directory from `sidechains/`, because `ReadWorkerReport` treats the
  last line of `sidechains/<id>.jsonl` as the worker's Result — appending turns
  there would make every report read return a turn instead.
  """
  @spec path(String.t(), String.t(), String.t()) :: String.t()
  def path(cwd, parent_session_id, subagent_id) do
    Path.join([
      Sidechain.session_dir(cwd, parent_session_id),
      "transcript",
      "#{subagent_id}.ndjson"
    ])
  end

  @doc """
  Wrap an `on_event` callback so every conversational turn is recorded first.

  The inner callback is always called, with every event — including the ones
  this refuses. Recording is an observation, never a filter.

  Options are `:max_bytes` and `:line_chars`; see `write/3`.
  """
  @spec compose((term() -> term()) | nil, String.t(), keyword()) :: (term() -> :ok)
  def compose(inner, path, opts \\ []) do
    fn event ->
      write(path, event, opts)
      if is_function(inner, 1), do: inner.(event)
      :ok
    end
  end

  @doc """
  Append one turn, if the event is one.

  Always returns `:ok`. A worker's job is the work, not the record of it, so
  nothing here may reach the loop — this runs inside the worker's own
  `on_event` callback, and the filesystem is an external boundary.

  Options:

    * `:max_bytes` — size cap for the whole file; `0` disables the transcript.
      Defaults to `config :ex_athena, :agents, transcript_bytes`.
    * `:line_chars` — cap on one turn's text. A longer turn is cut and the line
      records its original length. Defaults to
      `config :ex_athena, :agents, transcript_line_chars`.
  """
  @spec write(String.t(), term(), keyword()) :: :ok
  def write(path, event, opts \\ []) do
    cap = Keyword.get(opts, :max_bytes) || Tuning.get(:agents, :transcript_bytes, @default_bytes)

    with true <- cap > 0,
         record when is_map(record) <- record(event, opts) do
      append(path, Map.put(record, :t, System.system_time(:millisecond)), cap)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Every decodable line, oldest first.

  Lines that will not decode are dropped — the normal end of a transcript whose
  writer was killed mid-line. A transcript that was never written reads as `[]`.
  """
  @spec read(String.t()) :: [map()]
  def read(path) do
    case File.read(path) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.flat_map(&decode/1)
      {:error, _} -> []
    end
  end

  @doc """
  Render records as the prose a reader (or a summariser) works on.

  Turns are labelled and separated, so a chunker can split on turn boundaries
  and whoever reads a chunk can say which turn a line came from.
  """
  @spec to_text([map()]) :: String.t()
  def to_text(records) when is_list(records) do
    records
    |> Enum.map_join("\n\n", fn
      %{"ev" => "turn", "text" => text} = record ->
        "── turn #{Map.get(record, "i", "?")} ──\n#{text}#{cut_note(record)}"

      %{"ev" => "transcript_truncated"} ->
        "── the transcript reached its size cap here; later turns were not recorded ──"

      _ ->
        ""
    end)
    |> String.trim()
  end

  defp cut_note(%{"cut" => n}) when is_integer(n),
    do: "\n[this turn was #{n} characters; the rest was not recorded]"

  defp cut_note(_record), do: ""

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp record({:assistant_turn, %{text: text} = payload}, opts) when is_binary(text) do
    if String.trim(text) == "" do
      nil
    else
      cap = line_chars(opts)

      if String.length(text) > cap do
        %{
          ev: "turn",
          i: Map.get(payload, :i),
          text: String.slice(text, 0, cap),
          cut: String.length(text)
        }
      else
        %{ev: "turn", i: Map.get(payload, :i), text: text}
      end
    end
  end

  # Everything else. Tool calls and results are already digested in the journal
  # with their paths, sizes and exit codes; a second copy here would be most of
  # the bytes for none of the value. Streamed deltas are refused for the reason
  # the moduledoc gives.
  defp record(_event, _opts), do: nil

  defp line_chars(opts) do
    Keyword.get(opts, :line_chars) ||
      Tuning.get(:agents, :transcript_line_chars, @default_line_chars)
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) -> [map]
      _ -> []
    end
  end

  defp append(path, record, cap) do
    size = current_size(path)

    if size < cap do
      File.mkdir_p(Path.dirname(path))
      line = Jason.encode!(record) <> "\n"
      :ok = File.write(path, line, [:append])

      if size + byte_size(line) >= cap do
        File.write(
          path,
          Jason.encode!(%{
            t: System.system_time(:millisecond),
            ev: "transcript_truncated",
            cap_bytes: cap
          }) <> "\n",
          [:append]
        )
      end
    end
  end

  defp current_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end
end
