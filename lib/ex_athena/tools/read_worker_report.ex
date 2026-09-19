defmodule ExAthena.Tools.ReadWorkerReport do
  @moduledoc """
  Fetch a delegated worker's full report after the parent's own cap cut it.

  An orchestrator that tells a worker "write the payload to a file and reply
  with ten lines" is right to pass a small `max_result_chars`. When the worker
  replies with the payload in chat anyway, that cap destroys it. Session
  5906635b743d: worker `Ut1hUSMB` produced a 21,697-character extraction, the
  orchestrator saw 2,000 of it and recorded "the data has been lost from my
  context", then re-delegated — which costs more than the whole mechanism.

  The text was never actually lost. `ExAthena.Agents.Sidechain` persists every
  worker's untruncated report before either result branch runs. What was missing
  was an address the model could act on and a tool to act on it with. This is
  that tool; `SpawnAgent`'s truncation notice names it with the offset the cut
  happened at, so the model asks for the remainder instead of re-running the
  worker.

  Truncation is not the only reason to want it. Web session 272a4251558c
  called this tool after a worker SUMMARISED instead of quoting — nothing was
  truncated — and had no id to pass because back then only the truncation
  notice carried one. `SpawnAgent` now names the worker's id on every spawn
  result's runtime line (issue 245), truncated or not, so the id is always in
  the conversation by the time it is needed.

  ## Pull, not push

  The runs that need a worker's detail are the runs with the least context
  headroom left, so nothing here is pushed into the parent's transcript. The
  parent reads only when the summary surprises it, and pays a context cost
  proportional to its confusion.

  ## Three sources

  `source: "report"` (the default) is the report the parent already received —
  since issue 251 that is a SUMMARY of the run, written by
  `ExAthena.Agents.Summariser` from the transcript, and therefore lossy by
  design. `source: "journal"` reads `ExAthena.Agents.Journal` — what the worker
  DID, files with sizes and commands with exit codes. `source: "transcript"`
  reads `ExAthena.Agents.Transcript` — what it SAID, verbatim, turn by turn.

  The transcript is the one to reach for when the summary is not enough: an
  exact snippet, a path, the wording of an error. Re-spawning the worker to get
  it back costs what this whole mechanism exists to avoid — 838,180 tokens and
  16.8 minutes, live, in web session `0f73f270b133`. Reading the transcript
  costs a file read and no model run at all.

  One tool, because the argument, the id validation and the path resolution are
  the same for all three. Issue 215 sketched a separate `read_worker_log`; a
  second tool would have duplicated all three and cost every orchestrator
  another tool schema in its prompt.

  ## Offsets are characters

  Issue 216 sketched `bytes:`, but the cap this has to interoperate with —
  `SpawnAgent.truncate_result/3` — counts characters (`String.length/1`), and a
  notice reading "2,000 of 21,697 characters shown" must be followed by
  `from: 2000` meaning the same unit. `from` and `max_chars` are characters.
  """

  @behaviour ExAthena.Tool

  alias ExAthena.Agents.{Journal, Sidechain, Transcript}
  alias ExAthena.Provenance
  alias ExAthena.ToolContext

  # Matches the ids SpawnAgent generates: "subagent_" plus url-safe base64.
  # The id arrives from the model, so it is validated as a whole rather than
  # sanitised — anything that is not exactly this shape is refused, never
  # resolved against the filesystem.
  @id_re ~r/^subagent_[A-Za-z0-9_-]{1,64}$/

  # A worker report is prose, not a transcript. This bounds one pull; the model
  # pages with `from:` when it genuinely needs more.
  @default_max_chars 8_000

  # A tail is for "what was it doing when it stopped", not for reading the run
  # back. Everything else is a filter.
  @default_tail 20

  @filters ~w(writes commands errors tail)

  @impl true
  def name, do: "read_worker_report"

  @impl true
  def description do
    "Fetch what a worker you previously spawned said or did. `source: \"report\"` " <>
      "returns its full untruncated summary when the tool result you received was " <>
      "cut short; `source: \"journal\"` returns the record it wrote as it worked — " <>
      "files with sizes, commands with exit codes — which survives even a worker " <>
      "that was killed and reported nothing. Takes the subagent_id named on the " <>
      "runtime line at the end of the spawn result. Never re-run a worker just " <>
      "to see what it did."
  end

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        subagent_id: %{
          type: "string",
          description:
            "The worker's id, named on the \"Worker id:\" runtime line at the end " <>
              "of the spawn result (also repeated in the truncation notice when a " <>
              "report was cut short)."
        },
        from: %{
          type: "integer",
          description: "Character offset to start at. Defaults to 0."
        },
        max_chars: %{
          type: "integer",
          description: "Characters to return. Defaults to #{@default_max_chars}."
        },
        source: %{
          type: "string",
          enum: ["report", "journal", "transcript"],
          description:
            "\"report\" (default) is the summary you already received. " <>
              "\"transcript\" is what the worker SAID, verbatim, turn by turn — use it " <>
              "when you need an exact snippet, path or wording the summary lost. " <>
              "\"journal\" is what it DID — files written with their sizes, commands " <>
              "run with their exit codes — and survives a worker killed before it " <>
              "reported. Never re-run a worker for something one of these holds."
        },
        filter: %{
          type: "string",
          enum: ["writes", "commands", "errors", "tail"],
          description:
            "Journal only. \"writes\" for files it changed, \"commands\" for what it " <>
              "ran, \"errors\" for what failed, \"tail\" (default) for its last steps."
        },
        n: %{
          type: "integer",
          description: "Journal tail length. Defaults to #{@default_tail}."
        }
      },
      required: ["subagent_id"]
    }
  end

  @impl true
  def parallel_safe?, do: true

  @impl true
  def read_only?, do: true

  @impl true
  def execute(%{"subagent_id" => id} = args, %ToolContext{} = ctx) when is_binary(id) do
    if Regex.match?(@id_re, id) do
      fetch(id, args, ctx)
    else
      {:error,
       "#{inspect(id)} is not a worker id. Take it from the \"Worker id:\" " <>
         "line at the end of the spawn result you got back — it looks like " <>
         "\"subagent_AbC123\"."}
    end
  end

  def execute(_args, _ctx), do: {:error, "subagent_id is required"}

  defp fetch(id, args, ctx) do
    case Map.get(args, "source") do
      "journal" -> fetch_journal(id, args, ctx)
      "transcript" -> fetch_transcript(id, args, ctx)
      _ -> fetch_report(id, args, ctx)
    end
  end

  # The worker's own words, off disk, with no model run. `to_text/1` labels the
  # turns, so a parent that wants one can page to it with `from:` and say which
  # it read.
  defp fetch_transcript(id, args, ctx) do
    case Transcript.read(transcript_path(ctx, id)) do
      [] ->
        {:error,
         "no transcript on disk for #{id}. Either the worker was never spawned " <>
           "in this session, or transcripts are switched off (Workers → worker " <>
           "transcript size cap)." <> journal_hint(ctx, id)}

      records ->
        {:ok,
         records
         |> Transcript.to_text()
         |> slice(offset(args, "from", 0), offset(args, "max_chars", @default_max_chars))}
    end
  end

  defp fetch_report(id, args, ctx) do
    path = report_path(ctx, id)

    with {:ok, raw} <- read_last_line(path),
         {:ok, %{"result" => %{"text" => text}}} when is_binary(text) <- decode(raw) do
      {:ok, slice(text, offset(args, "from", 0), offset(args, "max_chars", @default_max_chars))}
    else
      _ ->
        {:error,
         "no report on disk for #{id}. Either the worker was never spawned in " <>
           "this session, or it was killed before it returned anything." <>
           journal_hint(ctx, id)}
    end
  end

  defp fetch_journal(id, args, ctx) do
    filter = Map.get(args, "filter") || "tail"

    with true <- filter in @filters,
         [_ | _] = records <- Journal.read(journal_path(ctx, id)) do
      {:ok,
       records
       |> render(filter, offset(args, "n", @default_tail))
       |> slice(offset(args, "from", 0), offset(args, "max_chars", @default_max_chars))}
    else
      false ->
        {:error, "filter must be one of: #{Enum.join(@filters, ", ")}."}

      [] ->
        {:error,
         "no journal on disk for #{id}. Either the worker was never spawned in " <>
           "this session, or journalling is switched off (Workers → journal size cap)."}
    end
  end

  # A worker killed before it could report has no sidechain but usually has a
  # journal. Saying so costs one line and saves a re-delegation.
  defp journal_hint(ctx, id) do
    case Journal.read(journal_path(ctx, id)) do
      [] -> ""
      _ -> " It did leave a journal: call this again with source: \"journal\"."
    end
  end

  # Call order, not map order: "wrote the test, ran it, then edited source" and
  # the reverse carry different meanings, which is why Provenance preserves
  # order in the first place. A map's enumeration order would also vary with its
  # size.
  defp render(records, "writes", _n) do
    sizes = Journal.sizes(records)
    paths = records |> Journal.provenance_events() |> Provenance.changed_files()

    case paths do
      [] ->
        "This worker changed no files."

      _ ->
        header(records, "wrote #{length(paths)} file(s)") <>
          Enum.map_join(paths, "\n", fn path ->
            case Map.get(sizes, path) do
              bytes when is_integer(bytes) -> "wrote #{path} (#{bytes} B)"
              _ -> "wrote #{path}"
            end
          end)
    end
  end

  defp render(records, "commands", _n) do
    case commands(records) do
      [] -> "This worker ran no commands."
      lines -> header(records, "ran #{length(lines)} command(s)") <> Enum.join(lines, "\n")
    end
  end

  defp render(records, "errors", _n) do
    case Enum.flat_map(records, &error_line/1) do
      [] -> "Nothing this worker did reported a failure."
      lines -> header(records, "#{length(lines)} failure(s)") <> Enum.join(lines, "\n")
    end
  end

  defp render(records, "tail", n) do
    tail = Enum.take(records, -max(n, 1))

    header(records, "last #{length(tail)} of #{length(records)} entries") <>
      Enum.map_join(tail, "\n", &describe/1)
  end

  defp header(records, what) do
    "Worker journal — #{what}, from #{length(records)} recorded steps.\n"
  end

  defp commands(records) do
    for %{"ev" => "tool_result", "cmd" => cmd} = record <- records, is_binary(cmd) do
      "ran #{cmd} (exit #{Map.get(record, "exit_code", "?")})"
    end
  end

  defp error_line(%{"ev" => "tool_result", "cmd" => cmd, "exit_code" => code})
       when is_integer(code) and code != 0,
       do: ["failed: #{cmd} (exit #{code})"]

  defp error_line(%{"ev" => "tool_result", "ok" => false, "id" => id} = record) do
    if Map.has_key?(record, "cmd"), do: [], else: ["tool call #{id} returned an error"]
  end

  defp error_line(%{"ev" => "done", "finish_reason" => reason})
       when reason not in ~w(stop submitted),
       do: ["the worker stopped on #{reason}"]

  defp error_line(_record), do: []

  defp describe(%{"ev" => "iteration", "i" => i}), do: "iteration #{i}"

  defp describe(%{"ev" => "tool_call", "name" => name} = record) do
    case record["path"] do
      path when is_binary(path) -> "calls #{name} on #{path}"
      _ -> "calls #{name}"
    end
  end

  defp describe(%{"ev" => "tool_result"} = record) do
    cond do
      is_binary(record["cmd"]) -> "  exit #{Map.get(record, "exit_code", "?")}"
      is_integer(record["bytes"]) -> "  wrote #{record["bytes"]} B"
      record["ok"] == false -> "  failed"
      true -> "  ok"
    end
  end

  defp describe(%{"ev" => "conclusion", "text" => text}), do: "concludes: #{text}"
  defp describe(%{"ev" => "usage", "in" => input}), do: "(#{input} input tokens so far)"
  defp describe(%{"ev" => "done", "finish_reason" => reason}), do: "stopped: #{reason}"
  defp describe(%{"ev" => "journal_truncated"}), do: "[journal reached its size cap here]"
  defp describe(%{"ev" => ev}), do: ev
  defp describe(_record), do: "?"

  defp report_path(%ToolContext{} = ctx, id) do
    Path.join([
      Sidechain.session_dir(cwd(ctx), ctx.session_id || "unknown"),
      "sidechains",
      "#{id}.jsonl"
    ])
  end

  defp journal_path(%ToolContext{} = ctx, id) do
    Journal.path(cwd(ctx), ctx.session_id || "unknown", id)
  end

  defp transcript_path(%ToolContext{} = ctx, id) do
    Transcript.path(cwd(ctx), ctx.session_id || "unknown", id)
  end

  defp cwd(%ToolContext{cwd: cwd}), do: cwd || File.cwd!()

  # Sidechain appends, so the newest record for a worker is the last line.
  defp read_last_line(path) do
    case File.read(path) do
      {:ok, contents} ->
        case contents |> String.split("\n", trim: true) |> List.last() do
          nil -> :error
          line -> {:ok, line}
        end

      {:error, _} ->
        :error
    end
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, map} -> {:ok, map}
      _ -> :error
    end
  end

  defp offset(args, key, default) do
    case Map.get(args, key) do
      n when is_integer(n) and n >= 0 ->
        n

      # HTML forms and small models both send integers as strings.
      s when is_binary(s) ->
        with({n, ""} <- Integer.parse(s), do: max(n, 0), else: (_ -> default))

      _ ->
        default
    end
  end

  defp slice(text, from, max_chars) do
    total = String.length(text)
    max_chars = max(max_chars, 1)
    body = String.slice(text, from, max_chars)

    cond do
      from >= total ->
        "(nothing at offset #{from}; the report is #{total} characters long)"

      from + max_chars < total ->
        body <>
          "\n\n[characters #{from}-#{from + max_chars} of #{total}. " <>
          "Continue with from: #{from + max_chars}.]"

      true ->
        body
    end
  end
end
