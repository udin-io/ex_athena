defmodule ExAthena.Agents.Summariser do
  @moduledoc """
  Builds a worker's report from its transcript, instead of catching it from
  whatever the worker happened to say last.

  A worker's report used to be `Result.text` — its final assistant message.
  Worker `subagent_fqB0WqCf` spent 794,377 input tokens writing a codebase map
  and then ended with "the report above is the complete deliverable… delivered
  in the previous turn". That sign-off was the report, and the parent re-spawned
  a second worker to redo the work (issue 251).

  Reading `ExAthena.Agents.Transcript` instead removes the class of failure
  rather than the instance. A worker that summarises itself, runs out of clock
  or is killed outright still leaves turns on disk, and those turns are what
  this summarises.

  ## What it is allowed to do

  Nothing but read text and write text. It runs as a fresh `ExAthena.Loop.run/2`
  with **no tools**, which is what makes "it cannot spawn workers of its own"
  and "it does not inherit the parent's todos" true by construction rather than
  by instruction. Only provider settings are carried over from the worker's own
  options (see `@carried_opts`), so it speaks to the same backend and queues on
  the same `ExAthena.RequestQueue` slots.

  ## Size

  One pass if the transcript fits in `:chunk_chars`. Otherwise it is split on
  turn boundaries, each chunk is summarised into a block of at most
  `:block_chars`, and the blocks are combined in ONE final pass — never
  recursively, because on a single-GPU host an unbounded fan-out of model runs
  is the failure this is supposed to prevent.

  `:max_chunks` is the cost rail: it bounds the model runs one worker can cause.
  Past it the MIDDLE chunks are dropped, because the ends of a run carry the
  brief and the conclusions. Dropping is acceptable; dropping silently is not,
  so the combine prompt carries a marker naming `read_worker_report` with
  `source: "transcript"` — the dropped turns are still on disk.

  ## Failure is the caller's to handle

  Every failure returns `{:error, reason}` and never a partial or blank report,
  so `ExAthena.Tools.SpawnAgent` can fall back to the worker's own final message
  and say in the report that it did. A summariser that returned "" on error
  would hand the parent nothing and look like success.
  """

  alias ExAthena.Agents.Transcript
  alias ExAthena.Tuning

  # Enough transcript for one pass on a small local model (~6k tokens), which is
  # the constrained case; a large-context model simply never chunks.
  @default_chunk_chars 24_000

  # One chunk's summary. Eight of these is 32k characters, which the combine
  # pass has to read.
  @default_block_chars 4_000

  # Model runs one worker may cause. Eight covers a 192,000-character
  # transcript — an order of magnitude past the worst run observed.
  @default_max_chunks 8

  # The WHOLE summarise, chunks and combine together, not per call.
  @default_timeout_ms 120_000

  # Everything the summariser needs to reach the same backend as the worker —
  # and nothing else. Tools, assigns, hooks, deadlines, todos and the parent
  # session are all deliberately absent: this list is the tool ceiling.
  @carried_opts [:provider, :model, :base_url, :api_key, :mock, :mock_events]

  @chunk_prompt """
  You are given part of the transcript of an agent's run — its own words, turn
  by turn. Write down what this part establishes, as findings a reader who
  never saw the run can act on.

  Keep every concrete fact: file paths, names, commands, numbers, snippets,
  and NEGATIVE findings ("X does not exist"). Drop the narration — "I will now
  look at", "let me check". Do not add anything the transcript does not say.
  Write the findings themselves, never a description of them.
  """

  @combine_prompt """
  You are given summaries of consecutive parts of one agent's run. Combine them
  into a single report for whoever delegated the work.

  Keep every concrete fact: file paths, names, commands, numbers, snippets and
  NEGATIVE findings. Remove repetition between the parts. Do not add anything
  the summaries do not say, and do not describe the report — write it.
  """

  @doc """
  Build the report for the worker whose transcript is at `path`.

  `worker_opts` is the worker's own `ExAthena.Loop.run/2` option list; only
  `#{inspect(@carried_opts)}` are carried over.

  Options:

    * `:enabled?` — `false` returns `{:error, :disabled}` without calling a
      model. Defaults to `config :ex_athena, :agents, summarise_reports`.
    * `:chunk_chars`, `:block_chars`, `:max_chunks`, `:timeout_ms` — see the
      moduledoc; each defaults to its `:agents` config key.

  Returns `{:ok, report}`, or `{:error, reason}` for the caller to fall back on.
  """
  @spec summarise(String.t(), keyword(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def summarise(path, worker_opts, opts \\ []) do
    if enabled?(opts) do
      case Transcript.read(path) do
        [] -> {:error, :no_transcript}
        records -> run(records, worker_opts, opts)
      end
    else
      {:error, :disabled}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp run(records, worker_opts, opts) do
    timeout = setting(opts, :timeout_ms, :summariser_timeout_ms, @default_timeout_ms)
    task = Task.async(fn -> build(records, worker_opts, opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      # A summariser still talking when its budget ran out is a summariser the
      # parent is waiting on. Kill it and let the caller use the worker's text.
      _ -> {:error, :timeout}
    end
  end

  defp build(records, worker_opts, opts) do
    chunk_chars = setting(opts, :chunk_chars, :summariser_chunk_chars, @default_chunk_chars)
    block_chars = setting(opts, :block_chars, :summariser_block_chars, @default_block_chars)
    max_chunks = setting(opts, :max_chunks, :summariser_max_chunks, @default_max_chunks)

    {chunks, dropped} =
      records
      |> chunk(chunk_chars)
      |> cap(max_chunks)

    with {:ok, blocks} <- summarise_chunks(chunks, worker_opts, block_chars) do
      combine(blocks, dropped, worker_opts, chunk_chars)
    end
  end

  # Split on TURN boundaries, never mid-turn: a chunk that starts halfway
  # through a finding asks the model to summarise half a sentence.  A single
  # turn longer than the chunk size becomes its own oversized chunk —
  # `Transcript` already capped it at `transcript_line_chars`.
  defp chunk(records, chunk_chars) do
    chunk_chars = max(chunk_chars, 1)

    records
    |> Enum.chunk_while(
      {[], 0},
      fn record, {acc, size} ->
        text = Transcript.to_text([record])
        len = String.length(text)

        if acc != [] and size + len > chunk_chars do
          {:cont, Enum.reverse(acc), {[record], len}}
        else
          {:cont, {[record | acc], size + len}}
        end
      end,
      fn
        {[], _size} -> {:cont, []}
        {acc, _size} -> {:cont, Enum.reverse(acc), {[], 0}}
      end
    )
    |> Enum.reject(&(&1 == []))
    |> Enum.map(&Transcript.to_text/1)
  end

  # The ends of a run hold the brief and the conclusions; the middle holds the
  # search. When something must go, the middle goes.
  defp cap(chunks, max_chunks) when length(chunks) <= max_chunks, do: {chunks, 0}

  defp cap(chunks, max_chunks) do
    keep = max(max_chunks, 1)
    head = div(keep + 1, 2)
    tail = keep - head

    kept = Enum.take(chunks, head) ++ Enum.take(chunks, -tail)
    {kept, length(chunks) - keep}
  end

  defp summarise_chunks(chunks, worker_opts, block_chars) do
    Enum.reduce_while(chunks, {:ok, []}, fn chunk, {:ok, acc} ->
      case ask(worker_opts, @chunk_prompt, chunk) do
        {:ok, text} -> {:cont, {:ok, [String.slice(text, 0, max(block_chars, 1)) | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, blocks} -> {:ok, Enum.reverse(blocks)}
      err -> err
    end
  end

  defp combine([single], 0, _worker_opts, _chunk_chars), do: {:ok, single}

  defp combine(blocks, dropped, worker_opts, chunk_chars) do
    body = Enum.join(blocks, "\n\n") <> dropped_note(dropped)

    # Never recurse. If the blocks alone exceed what one pass can read, hand
    # back the labelled concatenation: more model runs on a host whose worker
    # already serialised for 17 minutes is the cost this whole rail exists to
    # bound.
    if String.length(body) > chunk_chars do
      {:ok, body}
    else
      case ask(worker_opts, @combine_prompt, body) do
        {:ok, text} -> {:ok, text}
        {:error, _} = err -> err
      end
    end
  end

  defp dropped_note(0), do: ""

  defp dropped_note(n) do
    "\n\n[#{n} middle section(s) of this run were not summarised — the transcript " <>
      "holds them in full. Read them with read_worker_report and " <>
      ~s(source: "transcript".])
  end

  defp ask(worker_opts, system_prompt, body) do
    opts =
      worker_opts
      |> Keyword.take(@carried_opts)
      |> Keyword.merge(
        tools: [],
        memory: false,
        system_prompt: system_prompt,
        # One turn. With no tools there is nothing to iterate on, and a cap of
        # one means a chatty model cannot turn a summary into a conversation.
        max_iterations: 1
      )

    case ExAthena.Loop.run(body, opts) do
      {:ok, %{text: text}} when is_binary(text) ->
        if String.trim(text) == "", do: {:error, :blank_report}, else: {:ok, text}

      {:ok, _} ->
        {:error, :blank_report}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enabled?(opts) do
    case Keyword.fetch(opts, :enabled?) do
      {:ok, value} -> value not in [false, 0]
      :error -> Tuning.get(:agents, :summarise_reports, 1) not in [false, 0]
    end
  end

  defp setting(opts, key, config_key, default) do
    case Keyword.get(opts, key) do
      n when is_integer(n) and n > 0 -> n
      _ -> Tuning.get(:agents, config_key, default)
    end
  end
end
