defmodule ExAthena.Agents.Journal do
  @moduledoc """
  A per-worker forensic record, written to disk while the worker is alive.

  Everything else an orchestrator learns about a worker is derived at hand-back
  from the `ExAthena.Result` it returns: its report, its conclusions ledger, the
  `ExAthena.Provenance` footer. A worker that is killed outright — deadline,
  supervisor shutdown, OOM — returns no `Result`, so all of it is lost at once.
  Session 5906635b743d lost three workers that way, each with its deliverable
  already written, and re-delegated every one of them.

  The journal exists so the evidence is on disk *before* the worker dies. It is
  not a transcript: arguments are digested, streamed text is refused outright,
  and the file is capped. It answers "what did this worker actually do", not
  "what did it say".

  ## Reach

  `ExAthena.Orchestrator.Coordinator` holds similar facts in memory and
  `SpawnAgent.timed_out/4` already salvages what it can from them — but
  `Coordinator.start_for/2` has exactly one caller, the web UI. Every other
  entry point (`mix athena.chat`, a headless `ExAthena.Loop.run/2`, tests) has
  no coordinator at all, so a killed worker there leaves nothing whatsoever.
  This file is the one record that exists for every entry point, and the only
  one that survives the parent dying too.

  ## Why the writer holds no state

  `on_event` is invoked from inside `Task.async_stream` tasks when tool calls
  run concurrently (`ExAthena.Loop.Parallel`), so there is no single process to
  hang a counter or a call-id map on. Every line is therefore derived from its
  own event alone, and correlation is the reader's job: a `tool_result` carries
  the `tool_call_id` and not the tool name, because `%ToolResult{}` does not
  have one. Iteration numbers come from the `iteration` lines they follow.

  This costs one `stat` and one open/write/close per line and buys a writer
  that cannot lose buffered state when the process it runs in is killed.

  ## Why no `:delayed_write`

  The parent reads this file microseconds after brutal-killing the worker.
  `:delayed_write` would leave the last seconds of lines in a buffer the reader
  cannot see, and discard any error reported at close because nobody holds the
  handle. `File.write/3` with `:append` opens, writes and closes per call, so a
  returned write is visible to every other process on the machine. There is no
  `fsync`: a machine crash can still lose the tail, a process kill cannot.

  A kill between formatting a line and writing it loses that line outright, and
  a large line can be torn — which is why the format is NDJSON and why `read/1`
  drops a line it cannot decode rather than raising.
  """

  alias ExAthena.Agents.Sidechain
  alias ExAthena.Messages.{ToolCall, ToolResult}
  alias ExAthena.{Provenance, Result, Tuning}

  # ~60x the largest worker observed in session 5906635b743d (roughly 100 lines,
  # 30 KB). A runaway guard, not a budget.
  @default_bytes 2_000_000

  # The cap AgentInfo already applies to the same information in its transcript
  # rows. One number, two places.
  @default_line_chars 400

  @doc """
  Where one worker's journal lives: beside the sidechain transcript, under the
  PARENT's session directory.

  Separate files, shared directory. `ReadWorkerReport` treats the LAST line of
  `sidechains/<id>.jsonl` as the worker's report, so appending events there
  would make every report read return an event instead.
  """
  @spec path(String.t(), String.t(), String.t()) :: String.t()
  def path(cwd, parent_session_id, subagent_id) do
    Path.join([Sidechain.session_dir(cwd, parent_session_id), "journal", "#{subagent_id}.ndjson"])
  end

  @doc """
  Wrap an `on_event` callback so every journallable event is recorded first.

  The inner callback is always called, with every event — including the ones
  the journal refuses. Journalling is an observation, never a filter.

  Options:

    * `:cwd` — the worker's own directory, used to resolve and `stat` the paths
      its shell commands name. Without it, no bash write is ever claimed.
    * `:max_bytes` — size cap for the whole file; `0` disables journalling.
      Defaults to `config :ex_athena, :agents, journal_bytes`.
    * `:line_chars` — cap on the digested arguments in one line. Defaults to
      `config :ex_athena, :agents, journal_line_chars`.
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
  Append one event, if it is one the journal keeps.

  Always returns `:ok`. A worker's job is the work, not the record of it, so
  nothing here may reach the loop — this runs inside the worker's own
  `on_event` callback, and the filesystem is an external boundary.
  """
  @spec write(String.t(), term(), keyword()) :: :ok
  def write(path, event, opts \\ []) do
    cap = Keyword.get(opts, :max_bytes) || Tuning.get(:agents, :journal_bytes, @default_bytes)

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

  Lines that will not decode are dropped. That is the normal end of a journal
  whose writer was killed mid-line, and a truncated record must not stop the
  reader seeing the intact ones before it. A journal that was never written
  reads as `[]`.
  """
  @spec read(String.t()) :: [map()]
  def read(path) do
    case File.read(path) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.flat_map(&decode/1)
      {:error, _} -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

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
            ev: "journal_truncated",
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

  defp record({:iteration, n}, _opts) when is_integer(n), do: %{ev: "iteration", i: n}

  defp record({:tool_call, %ToolCall{} = call}, opts) do
    %{
      ev: "tool_call",
      id: call.id,
      name: call.name,
      path: declared_path(call.arguments),
      args: digest(call.arguments, opts)
    }
  end

  defp record({:tool_result, %ToolResult{} = result}, opts) do
    %{ev: "tool_result", id: result.tool_call_id, ok: result.is_error != true}
    |> Map.merge(evidence(result.ui_payload, opts))
  end

  defp record({:usage, usage}, _opts) when is_map(usage) do
    %{ev: "usage", in: usage[:input_tokens] || 0, out: usage[:output_tokens] || 0}
  end

  defp record({:conclusion, %{text: text} = entry}, opts) do
    %{
      ev: "conclusion",
      i: Map.get(entry, :iteration),
      source: to_string(Map.get(entry, :source, :derived)),
      text: cap_chars(text, opts)
    }
  end

  defp record({:subagent_spawn, %{id: id}}, _opts),
    do: %{ev: "subagent_spawn", id: to_string(id)}

  defp record({:subagent_result, %{id: id}}, _opts),
    do: %{ev: "subagent_result", id: to_string(id)}

  defp record({:done, %Result{finish_reason: reason}}, _opts),
    do: %{ev: "done", finish_reason: to_string(reason)}

  # Streamed text and thinking arrive one delta per token; everything else is
  # either already durable in the Result or not evidence of anything.
  defp record(_event, _opts), do: nil

  # `write` / `edit` resolve the model's argument to an absolute path and report
  # it back through the diff payload; the size is taken here because this is the
  # one moment the file is certain to exist.
  defp evidence(%{kind: :diff, payload: %{path: path}}, _opts) when is_binary(path) do
    %{path: path, bytes: size_of(path)}
  end

  defp evidence(%{kind: :process, payload: %{command: command} = payload}, opts) do
    %{
      exit_code: Map.get(payload, :exit_code),
      writes: confirmed_writes(command, Keyword.get(opts, :cwd))
    }
  end

  defp evidence(_ui_payload, _opts), do: %{}

  # A guess that survives a stat is not a guess. One that does not is dropped:
  # a fabricated path in a forensic record is worse than a missing one.
  defp confirmed_writes(_command, nil), do: []

  defp confirmed_writes(command, cwd) do
    command
    |> Provenance.write_targets()
    |> Enum.flat_map(fn target ->
      case File.stat(Path.expand(target, cwd)) do
        {:ok, %File.Stat{size: size, type: :regular}} -> [%{path: target, bytes: size}]
        _ -> []
      end
    end)
  end

  defp size_of(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> nil
    end
  end

  defp declared_path(args) when is_map(args) do
    case Map.get(args, "path") || Map.get(args, "file_path") do
      path when is_binary(path) -> path
      _ -> nil
    end
  end

  defp declared_path(_args), do: nil

  # `printable_limit` bounds each string DURING formatting, so a write call
  # carrying an 85 KB body never builds an 85 KB digest only to slice it away.
  defp digest(args, opts) do
    max = line_chars(opts)

    args
    |> inspect(limit: 20, printable_limit: max)
    |> String.slice(0, max)
  end

  defp cap_chars(text, opts) when is_binary(text), do: String.slice(text, 0, line_chars(opts))
  defp cap_chars(text, _opts), do: text

  defp line_chars(opts) do
    Keyword.get(opts, :line_chars) ||
      Tuning.get(:agents, :journal_line_chars, @default_line_chars)
  end
end
