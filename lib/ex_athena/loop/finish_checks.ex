defmodule ExAthena.Loop.FinishChecks do
  @moduledoc """
  The four checks a run must pass before it may say it is done.

  A completed todo is the model's own claim, so it proves nothing. What the
  run's tool calls did can be read back off its history
  (`ExAthena.Provenance`), and these checks read that record when the run
  stops after changing files:

    1. **verification** — files changed and no command ran at all.
    2. **test** — something ran, but no test run passed.
    3. **coverage** — tests passed, but none executed a changed file.
    4. **audit** — nothing compared the delivered work with the request.

  Each check nudges the run once: the run gets a note naming what is missing
  and one more turn. A run that cannot meet it stops on its next halt, so no
  check can trap a run. "Once" spans a resume as well, which `mode_state`
  cannot carry (`init/1` rebuilds it on every `Loop.run`), so each note opens
  with its own name and `fired` reads those names back off the transcript
  (issue 232). `mode_state` keeps the in-run answer, because a compaction can
  drop the note but not the flag.
  """

  alias ExAthena.Agents.Quota
  alias ExAthena.Loop.State
  alias ExAthena.Tuning

  @audit_request_chars 1_500

  @gate_names %{
    verify_nudged: "verification",
    test_nudged: "test",
    coverage_nudged: "coverage",
    audit_nudged: "audit"
  }

  @doc """
  Run the checks on a halted state.

  Returns `{:continue, state}` when a check fires (the note is appended and
  the halt is undone), `{:halt, state}` when the run's worker allowance is
  spent and the unmet checks are written into its deliverable instead, and
  `:pass` when no check applies, so the caller decides the halt itself.

  Only a `finish` (`halted_reason` `{:submitted, ...}`) is checked: a
  bare-text stop is the caller's to handle.
  """
  @spec run(State.t()) :: {:continue, State.t()} | {:halt, State.t()} | :pass
  def run(%State{} = halted) do
    ev = if submitted?(halted), do: evidence(halted), else: nil

    # Every check below asks for ONE more worker. With the allowance spent
    # there is none, so the demand is one the run cannot meet: session
    # 227f7f480afa was told twice to spawn, refused twice, and failed. The
    # checks still matter, so they are named in the deliverable instead —
    # unverified work reported as unverified (issue 216).
    quota_spent? = ev != nil and Quota.exhausted?(halted.ctx.assigns || %{})

    cond do
      quota_spent? ->
        {:halt, note_unverified(halted, ev)}

      # Fires on an otherwise CLEAN finish, because that is exactly the shape
      # of the failure: every todo marked completed and a deliverable asserting
      # a build no worker ever ran.
      gate?(halted, ev, :verify_nudged, &(&1.changed != [] and not &1.acted?)) ->
        nudge(halted, :verify_nudged, verify_note(ev.changed))

      # A build proves the code parses; the live failure compiled cleanly and
      # raised on every page load.
      gate?(halted, ev, :test_nudged, &(&1.source_changed != [] and not &1.tested?)) ->
        nudge(halted, :test_nudged, test_note(ev.source_changed))

      # A live run tested a private helper it had just written, reported 252
      # passing, and shipped a page that raised on every load.
      gate?(halted, ev, :coverage_nudged, &(&1.uncovered != [])) ->
        nudge(halted, :coverage_nudged, coverage_note(ev.uncovered, ev.test_runs))

      # A live run was asked for "all records" and shipped a filter on invented
      # column values matching none of them: it compiled, tests passed, the
      # changed code ran. No mechanical check can see a dropped requirement.
      gate?(halted, ev, :audit_nudged, &(&1.source_changed != [])) ->
        nudge(halted, :audit_nudged, audit_note(original_request(halted)))

      true ->
        :pass
    end
  end

  @doc """
  Deliver a runtime note while keeping the transcript valid.

  When the last assistant turn made tool calls (e.g. `finish`), the note is the
  TOOL RESULT for each, since strict OpenAI-compatible servers answer 400 to an
  assistant tool call with no paired result. Otherwise it is a plain user turn.
  """
  @spec redirect(State.t(), String.t()) :: State.t()
  def redirect(state, text) do
    case List.last(state.messages) do
      %{role: :assistant, tool_calls: [_ | _] = calls} ->
        results =
          Enum.map(calls, fn c -> ExAthena.Messages.tool_result(c.id, text, true) end)

        %{state | messages: state.messages ++ results}

      _ ->
        %{state | messages: state.messages ++ [ExAthena.Messages.user(text)]}
    end
  end

  @doc "Whether the halt is a `finish` call (`{:submitted, ...}`)."
  @spec submitted?(State.t()) :: boolean()
  def submitted?(halted) do
    match?({:submitted, _}, halted.halted_reason) or
      match?({:submitted, _, _}, halted.halted_reason)
  end

  # The deliverable is what the caller reads; a runtime note anywhere else is
  # not part of the answer. Appended, never substituted — the run's own words
  # stay first.
  defp note_unverified(halted, ev) do
    case unverified(ev) do
      [] ->
        halted

      checks ->
        {deliverable, source} = submitted_payload(halted)

        note =
          "\n\n[orchestration runtime] UNVERIFIED — the run's worker allowance " <>
            "(#{Quota.limit(halted.ctx.assigns || %{})}) was spent, so these checks did not run:\n" <>
            Enum.map_join(checks, "\n", &("- " <> &1))

        %{halted | halted_reason: {:submitted, to_string(deliverable) <> note, source}}
    end
  end

  # `finish` halts with `{:submitted, payload, source}` (issue 263); a
  # `{:submitted, payload}` halt raised elsewhere is the same signal without a
  # named argument, and both end the run the same way.
  defp submitted_payload(%{halted_reason: {:submitted, payload, source}}), do: {payload, source}
  defp submitted_payload(%{halted_reason: {:submitted, payload}}), do: {payload, nil}

  # One line per check that is still deficient, in the checks' own order.
  defp unverified(ev) do
    [
      {ev.changed != [] and not ev.acted?,
       "no command was run to check " <> Enum.join(ev.changed, ", ")},
      {ev.source_changed != [] and not ev.tested?,
       "no test run covered " <> Enum.join(ev.source_changed, ", ")},
      {ev.uncovered != [], "no test executed " <> Enum.join(ev.uncovered, ", ")},
      {ev.source_changed != [], "the delivered work was not audited against the original request"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp gate?(_halted, nil, _flag, _deficient?), do: false

  defp gate?(halted, ev, flag, deficient?),
    do: halted.mode_state[flag] != true and flag not in ev.fired and deficient?.(ev)

  defp nudge(halted, flag, note) do
    {:continue,
     halted
     |> redirect(gate_prefix(flag) <> note)
     |> Map.put(:halted_reason, nil)
     |> put_in([Access.key(:mode_state), flag], true)
     |> Map.put(:meta, Map.delete(halted.meta, :finish_reason))}
  end

  # Doubles as the note's own header, so nothing invisible rides along in the
  # prompt or the chat UI just to be read back on the next run.
  defp gate_prefix(flag), do: "[orchestration runtime: #{@gate_names[flag]} gate] "

  defp fired_gates(transcript),
    do: Enum.filter(Map.keys(@gate_names), &String.contains?(transcript, gate_prefix(&1)))

  # What the workers' own tool calls prove about this run.
  #
  # `acted?` is a FLOOR, not a proof: any non-read-only command clears it, so a
  # worker that ran `mkdir` counts. It exists to make "nothing was checked"
  # impossible to finish through silently. `tested?` is the sharper check —
  # a test run that neither failed nor hid its result behind a pipe (see
  # `ExAthena.Provenance.command_outcome/3`).
  defp evidence(state) do
    transcript = transcript_text(state)
    events = ExAthena.Provenance.scan(transcript)
    files = ExAthena.Provenance.changed_files(events)
    commands = ExAthena.Provenance.commands(events)

    not_passing =
      ExAthena.Provenance.failed_commands(events) ++
        ExAthena.Provenance.unconfirmed_commands(events)

    source_changed = Enum.reject(files, &ExAthena.Provenance.test_file?/1)

    test_runs =
      Enum.filter(commands, &(ExAthena.Provenance.test_command?(&1) and &1 not in not_passing))

    tested? = test_runs != []

    %{
      changed: files,
      source_changed: source_changed,
      acted?:
        Enum.any?(commands, &(not ExAthena.Tools.Bash.read_only_command?(%{"command" => &1}))),
      tested?: tested?,
      test_runs: test_runs,
      # Checks this session has already fired, in this run or an earlier one.
      fired: fired_gates(transcript),
      # Only asked once tests are green: before that, checks 1 and 2 own the
      # conversation and a coverage demand would be noise on top of them.
      uncovered: if(tested?, do: uncovered(source_changed, transcript, state.ctx.cwd), else: [])
    }
  end

  # `:no_data` means the run never reported coverage at all, so nothing can be
  # concluded — ask for it rather than read silence as either pass or fail.
  defp uncovered([], _transcript, _cwd), do: []

  defp uncovered(source_changed, transcript, cwd) do
    case ExAthena.Coverage.unexercised(source_changed, transcript, cwd) do
      :no_data -> source_changed
      {:ok, files} -> files
    end
  end

  # Worker reports arrive as tool results, so both channels must be scanned.
  defp transcript_text(%State{messages: messages}) do
    messages
    |> Enum.flat_map(fn msg ->
      [to_string(msg.content || "")] ++
        Enum.map(msg.tool_results || [], &to_string(&1.content || ""))
    end)
    |> Enum.join("\n")
  end

  defp verify_note(files) do
    "Workers changed " <>
      Enum.join(files, ", ") <>
      " but no command was run to check them — a completed todo is your own " <>
      "claim, not evidence. Spawn ONE worker whose brief is to run this " <>
      "project's build/test command and report its RAW output, then call " <>
      "finish. If this task genuinely cannot be checked by a command, call " <>
      "finish again and say so in the deliverable."
  end

  # The human's FIRST turn, verbatim. The audit must run against what was
  # actually asked, never the run's own restatement of it — a paraphrase is
  # where the dropped requirement went missing in the first place.
  #
  # `ExAthena.Memory` injects each AGENTS.md / CLAUDE.md file as a user-role
  # message in FRONT of the prompt, so "the first user message" is the project
  # memory in every session that has one. Skipping those is what makes this the
  # request rather than the conventions (issue 232). "" when the run has no
  # human turn yet — `audit_note/1` then quotes nothing.
  defp original_request(%State{messages: messages}) do
    Enum.find_value(messages, "", fn
      %{role: :user, content: content} = message when is_binary(content) ->
        if ExAthena.Memory.memory_message?(message), do: nil, else: content

      _ ->
        nil
    end)
  end

  defp audit_note(request) do
    "Before finishing: nothing has checked the " <>
      "delivered work against the ORIGINAL request. Compiling, passing tests " <>
      "and covered code do not show that you built what was asked. Spawn ONE " <>
      "worker to audit it. Give that worker the request below VERBATIM and " <>
      "tell it to: list every explicit requirement as a separate item; for " <>
      "each, read the actual delivered code and state MET or NOT MET with the " <>
      "file and line as evidence; and check every literal value the code " <>
      "compares against real data (enum codes, status strings, column values) " <>
      "by querying or reading the data — a value that was assumed rather than " <>
      "observed is NOT MET. It must actively look for requirements that were " <>
      "narrowed, widened or dropped. Fix anything NOT MET, then finish." <>
      quoted_request(request)
  end

  # No human turn, no quotation: an empty "ORIGINAL REQUEST:" heading invites
  # the model to fill it in from the nearest text it can see, which is the
  # project memory `original_request/1` skips.
  defp quoted_request(request) do
    limit = Tuning.get(:orchestrate, :audit_request_chars, @audit_request_chars)

    if String.trim(request) == "" do
      ""
    else
      body =
        if String.length(request) > limit,
          do: String.slice(request, 0, limit) <> "…",
          else: request

      "\n\nORIGINAL REQUEST:\n" <> body
    end
  end

  # States what the runtime observed — a command, its exit code, the absence of
  # a failure summary — and never "the suite is green". Session 227f7f480afa's
  # orchestrator repeated that sentence in its deliverable over 4 failing tests.
  defp coverage_note(files, test_runs) do
    "A test run exited zero with no failure summary " <>
      "in its output (" <>
      Enum.join(test_runs, "; ") <>
      "), but no test executed " <>
      Enum.join(files, ", ") <>
      " — a passing run proves a test EXISTS, not that it covers your " <>
      "change. Spawn ONE worker to add a test that calls the changed code " <>
      "through its real entry point (the function or route a caller actually " <>
      "uses, not a private helper), run the suite WITH COVERAGE " <>
      "(e.g. `mix test --cover`), and paste the coverage table plus the raw " <>
      "test output. Then call finish. If this code genuinely cannot be " <>
      "executed by a test, call finish again and say why."
  end

  defp test_note(files) do
    "Workers changed " <>
      Enum.join(files, ", ") <>
      " and no test run covered them — a build proves the code parses, not " <>
      "that it works. Spawn ONE worker to run this project's test suite, and " <>
      "to ADD a test exercising the changed behaviour if none does; it must " <>
      "report the raw output. Then call finish. If this change genuinely " <>
      "cannot be tested, call finish again and say why in the deliverable."
  end
end
