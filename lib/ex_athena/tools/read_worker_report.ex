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

  ## Pull, not push

  The runs that need a worker's detail are the runs with the least context
  headroom left, so nothing here is pushed into the parent's transcript. The
  parent reads only when the summary surprises it, and pays a context cost
  proportional to its confusion.

  ## Relationship to the forensic journal (issue 215)

  Issue 215 adds a per-worker NDJSON journal (`workers/<id>.ndjson`) and wants a
  `read_worker_log(subagent_id, filter)` to query it. That is this tool with
  more sources, not a second tool: the argument, the id validation and the path
  resolution below are the parts they share. When the journal lands, add its
  source and the `filter:` / `tail:` options HERE rather than introducing a
  parallel path.

  ## Offsets are characters

  Issue 216 sketched `bytes:`, but the cap this has to interoperate with —
  `SpawnAgent.truncate_result/3` — counts characters (`String.length/1`), and a
  notice reading "2,000 of 21,697 characters shown" must be followed by
  `from: 2000` meaning the same unit. `from` and `max_chars` are characters.
  """

  @behaviour ExAthena.Tool

  alias ExAthena.ToolContext

  # Matches the ids SpawnAgent generates: "subagent_" plus url-safe base64.
  # The id arrives from the model, so it is validated as a whole rather than
  # sanitised — anything that is not exactly this shape is refused, never
  # resolved against the filesystem.
  @id_re ~r/^subagent_[A-Za-z0-9_-]{1,64}$/

  # A worker report is prose, not a transcript. This bounds one pull; the model
  # pages with `from:` when it genuinely needs more.
  @default_max_chars 8_000

  @impl true
  def name, do: "read_worker_report"

  @impl true
  def description do
    "Fetch the full, untruncated report of a worker you previously spawned, " <>
      "when the tool result you received was cut short. Takes the subagent_id " <>
      "named in the truncation notice. Use `from` to continue from where the " <>
      "truncation stopped rather than re-reading what you already have. Never " <>
      "re-run a worker just to see its report again."
  end

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        subagent_id: %{
          type: "string",
          description: "The worker's id, as named in the truncation notice."
        },
        from: %{
          type: "integer",
          description: "Character offset to start at. Defaults to 0."
        },
        max_chars: %{
          type: "integer",
          description: "Characters to return. Defaults to #{@default_max_chars}."
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
       "#{inspect(id)} is not a worker id. Use the subagent_id from the " <>
         "truncation notice (it looks like \"subagent_AbC123\")."}
    end
  end

  def execute(_args, _ctx), do: {:error, "subagent_id is required"}

  defp fetch(id, args, ctx) do
    path = report_path(ctx, id)

    with {:ok, raw} <- read_last_line(path),
         {:ok, %{"result" => %{"text" => text}}} when is_binary(text) <- decode(raw) do
      {:ok, slice(text, offset(args, "from", 0), offset(args, "max_chars", @default_max_chars))}
    else
      _ ->
        {:error,
         "no report on disk for #{id}. Either the worker was never spawned in " <>
           "this session, or it was killed before it returned anything."}
    end
  end

  defp report_path(%ToolContext{cwd: cwd, session_id: session_id}, id) do
    Path.join([
      cwd || File.cwd!(),
      ".exathena",
      "sessions",
      session_id || "unknown",
      "sidechains",
      "#{id}.jsonl"
    ])
  end

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
