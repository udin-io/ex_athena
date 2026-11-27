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
  alias ExAthena.Provenance
  alias ExAthena.Tools.Bash
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

  `voice:` picks who the notes speak to:

    * `:orchestrator` (default) — a coordinator that holds no workspace
      tools. Only a `finish` (`halted_reason` `{:submitted, ...}`) is checked,
      the whole transcript is the evidence, and each note asks for a worker.
    * `:chat` — the one chat, which holds every tool. A plain-text stop is
      checked as well as a `finish`, and the evidence is the current task
      alone: everything since the person's latest message. A chat runs many
      tasks, and each one gets its own checks; a resume with no new message
      is the same task, so a check it already fired stays fired. A chat that
      can neither run a command nor send a helper is not checked, since no
      note could be acted on.
  """
  @spec run(State.t(), keyword()) :: {:continue, State.t()} | {:halt, State.t()} | :pass
  def run(%State{} = halted, opts \\ []) do
    voice = Keyword.get(opts, :voice, :orchestrator)
    ev = if checked?(halted, voice), do: evidence(halted, voice), else: nil

    # Every check below asks for ONE more worker. With the allowance spent
    # there is none, so the demand is one the run cannot meet: session
    # 227f7f480afa was told twice to spawn, refused twice, and failed. The
    # checks still matter, so they are named in the deliverable instead —
    # unverified work reported as unverified (issue 216).
    quota_spent? =
      voice == :orchestrator and ev != nil and Quota.exhausted?(halted.ctx.assigns || %{})

    cond do
      quota_spent? -> {:halt, note_unverified(halted, ev)}
      ev == nil -> :pass
      true -> first_failing(halted, ev, voice)
    end
  end

  # In order; the first deficient check that has not fired yet is the one
  # nudged, so a run meets them one at a time.
  defp first_failing(halted, ev, voice) do
    Enum.find_value(checks(), :pass, fn {flag, deficient?, note_args} ->
      if gate?(halted, ev, flag, deficient?),
        do: nudge(halted, voice, flag, apply_note(voice, note_args, ev))
    end)
  end

  defp apply_note(voice, {kind, args}, ev), do: note(voice, kind, args.(ev))

  defp checks do
    [
      # Fires on an otherwise CLEAN finish, because that is exactly the shape
      # of the failure: every todo marked completed and a deliverable asserting
      # a build no worker ever ran.
      {:verify_nudged, &(&1.changed != [] and not &1.acted?), {:verify, & &1.changed}},
      # A build proves the code parses; the live failure compiled cleanly and
      # raised on every page load.
      {:test_nudged, &(&1.source_changed != [] and not &1.tested?), {:test, & &1.source_changed}},
      # A live run tested a private helper it had just written, reported 252
      # passing, and shipped a page that raised on every load.
      {:coverage_nudged, &(&1.uncovered != []), {:coverage, &{&1.uncovered, &1.test_runs}}},
      # A live run was asked for "all records" and shipped a filter on invented
      # column values matching none of them: it compiled, tests passed, the
      # changed code ran. No mechanical check can see a dropped requirement.
      {:audit_nudged, &(&1.source_changed != []), {:audit, & &1.request}}
    ]
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

  defp checked?(halted, :orchestrator), do: submitted?(halted)

  defp checked?(halted, :chat) do
    (halted.meta[:finish_reason] == :stop or submitted?(halted)) and can_act?(halted) and
      turn_left?(halted)
  end

  # A nudge spends one more turn. When the run has none left, the nudge would
  # turn a clean stop into `:error_max_turns` (or a budget stop), so the run
  # ends as it stands instead.
  defp turn_left?(%State{} = s) do
    not (is_integer(s.max_iterations) and s.iterations + 1 >= s.max_iterations) and
      not ExAthena.Budget.exceeded?(s.budget, s.max_budget_usd) and
      not ExAthena.Budget.input_exceeded?(s.budget, s.max_input_tokens)
  end

  # In the read-only phase nothing could have changed, and without `bash` or
  # `spawn_agent` the chat has no way to run a check.
  defp can_act?(%State{ctx: ctx, tool_specs: specs}) do
    ctx.phase != :plan and
      Enum.any?(specs || [], &(&1.name in ["bash", "spawn_agent"]))
  end

  defp gate?(halted, ev, flag, deficient?),
    do: halted.mode_state[flag] != true and flag not in ev.fired and deficient?.(ev)

  defp nudge(halted, voice, flag, note) do
    {:continue,
     halted
     |> redirect(gate_prefix(voice, flag) <> note)
     |> Map.put(:halted_reason, nil)
     |> put_in([Access.key(:mode_state), flag], true)
     |> Map.put(:meta, Map.delete(halted.meta, :finish_reason))}
  end

  # Doubles as the note's own header, so nothing invisible rides along in the
  # prompt or the chat UI just to be read back on the next run.
  defp gate_prefix(:orchestrator, flag),
    do: "[orchestration runtime: #{@gate_names[flag]} gate] "

  defp gate_prefix(:chat, flag), do: "[chat runtime: #{@gate_names[flag]} check] "

  defp fired_gates(transcript, _messages, :orchestrator),
    do:
      Enum.filter(
        Map.keys(@gate_names),
        &String.contains?(transcript, gate_prefix(:orchestrator, &1))
      )

  # Only a note the runtime wrote counts: a user turn or an error tool result
  # that OPENS with the check's name (`redirect/2` writes exactly those). The
  # same words inside a file the chat read, a fetched page or a helper's report
  # would otherwise switch the check off for the whole request.
  defp fired_gates(_transcript, messages, :chat) do
    notes = runtime_notes(messages)

    Enum.filter(Map.keys(@gate_names), fn flag ->
      prefix = gate_prefix(:chat, flag)
      Enum.any?(notes, &String.starts_with?(&1, prefix))
    end)
  end

  @doc false
  # The texts `redirect/2` can have written: user-role turns, and the error
  # results it pairs with a tool call.
  @spec runtime_notes([ExAthena.Messages.Message.t()]) :: [String.t()]
  def runtime_notes(messages) do
    # `redirect/2` pairs a note with each call of a turn that halted, and a
    # turn halts with tool calls only through `finish`, so the note always
    # sits on the `finish` call's result. Any other tool's own error (an MCP
    # server's text, a helper's partial report) is not a note.
    halting_ids =
      for %{role: :assistant, tool_calls: [_ | _] = calls} <- messages,
          %{name: "finish", id: id} <- calls,
          into: MapSet.new(),
          do: id

    Enum.flat_map(messages, fn
      %{role: :user, content: c} when is_binary(c) ->
        [c]

      %{tool_results: [_ | _] = results} ->
        for %{is_error: true, content: c, tool_call_id: id} <- results,
            is_binary(c),
            MapSet.member?(halting_ids, id),
            do: c

      _ ->
        []
    end)
  end

  # What the workers' own tool calls prove about this run.
  #
  # `acted?` is a FLOOR, not a proof: any non-read-only command clears it, so a
  # worker that ran `mkdir` counts. It exists to make "nothing was checked"
  # impossible to finish through silently. `tested?` is the sharper check —
  # a test run that neither failed nor hid its result behind a pipe (see
  # `Provenance.command_outcome/3`).
  defp evidence(state, voice) do
    {messages, request} = scope(state, voice)
    transcript = transcript_text(messages)
    events = own_events(messages, voice) ++ Provenance.scan(footer_text(messages, voice))
    files = Provenance.changed_files(events)
    commands = Provenance.commands(events)

    not_passing =
      Provenance.failed_commands(events) ++
        Provenance.unconfirmed_commands(events)

    source_changed = Enum.reject(files, &Provenance.test_file?/1)

    test_runs =
      Enum.filter(commands, &(Provenance.test_command?(&1) and &1 not in not_passing))

    tested? = test_runs != []

    %{
      changed: files,
      source_changed: source_changed,
      acted?: Enum.any?(commands, &(not Bash.read_only_command?(%{"command" => &1}))),
      tested?: tested?,
      test_runs: test_runs,
      # Checks this session has already fired, in this run or an earlier one.
      fired: fired_gates(transcript, messages, voice),
      request: request,
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

  # The orchestrator holds no workspace tools, so only its workers' footers
  # carry evidence. The chat edits and runs commands itself, so its own calls
  # count too.
  # Helpers' footers are read only off `spawn_agent` results in the chat: the
  # chat's own tool output (a file, a command's output, a fetched page) can
  # hold any text, a forged footer line included.
  defp footer_text(messages, :orchestrator), do: transcript_text(messages)

  defp footer_text(messages, :chat) do
    spawn_ids =
      for %{role: :assistant, tool_calls: [_ | _] = calls} <- messages,
          %{name: "spawn_agent", id: id} <- calls,
          into: MapSet.new(),
          do: id

    messages
    |> Enum.flat_map(&(&1.tool_results || []))
    |> Enum.filter(&MapSet.member?(spawn_ids, &1.tool_call_id))
    |> Enum.map_join("\n", &to_string(&1.content || ""))
  end

  defp own_events(_messages, :orchestrator), do: []
  defp own_events(messages, :chat), do: Provenance.events(messages)

  defp scope(%State{messages: messages}, :orchestrator),
    do: {messages, original_request(messages)}

  defp scope(%State{messages: messages} = state, :chat) do
    case request_index(messages, state.meta[:request_message]) do
      nil -> {messages, ""}
      i -> {Enum.drop(messages, i), request_text(Enum.at(messages, i))}
    end
  end

  @doc """
  The person's message among the ones a caller sent: the last user turn that
  is neither project memory nor one of the runtime's own notes. Nil when there
  is none.

  `Loop.run/2` records it before any hook adds messages, because a hook's
  inject is a user-role turn too and must never stand in for the request.
  """
  @spec request_message([ExAthena.Messages.Message.t()]) :: ExAthena.Messages.Message.t() | nil
  def request_message(messages) do
    case latest_request_index(messages) do
      nil -> nil
      i -> Enum.at(messages, i)
    end
  end

  # The recorded request, found again by value. A compaction that rewrote it
  # leaves the latest human-looking turn as the best answer.
  defp request_index(messages, nil), do: latest_request_index(messages)

  defp request_index(messages, request) do
    case last_index(messages, request) do
      nil -> latest_request_index(messages)
      i -> i
    end
  end

  defp last_index(messages, request) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {m, i} -> if m == request, do: i end)
  end

  # The person's latest message. Project memory and the runtime's own notes
  # are user-role turns too, and neither one starts a task.
  defp latest_request_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {message, i} -> if human_turn?(message), do: i end)
  end

  # The person's turns carry no `name`; project memory ("memory"), a hook's
  # inject ("hook", or the name the hook chose) and skills all do.
  defp human_turn?(%{role: :user} = message) do
    Map.get(message, :name) == nil and not runtime_note?(request_text(message))
  end

  defp human_turn?(_), do: false

  @runtime_prefixes ["[chat runtime", "[orchestration runtime", "[runtime:"]

  defp runtime_note?(text), do: String.starts_with?(text, @runtime_prefixes)

  defp request_text(%{content: content}) when is_binary(content), do: content

  defp request_text(%{content: parts}) when is_list(parts) do
    parts
    |> Enum.flat_map(fn
      %{type: :text, text: text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp request_text(_), do: ""

  # Worker reports arrive as tool results, so both channels must be scanned.
  defp transcript_text(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(fn msg ->
      [to_string(msg.content || "")] ++
        Enum.map(msg.tool_results || [], &to_string(&1.content || ""))
    end)
    |> Enum.join("\n")
  end

  defp note(:orchestrator, :verify, files), do: verify_note(files)
  defp note(:orchestrator, :test, files), do: test_note(files)
  defp note(:orchestrator, :coverage, {files, runs}), do: coverage_note(files, runs)
  defp note(:orchestrator, :audit, request), do: audit_note(request)

  defp note(:chat, :verify, files) do
    "You changed " <>
      Enum.join(files, ", ") <>
      " but ran no command to check the change. Run this project's build or " <>
      "test command now (yourself, or through a helper) and read its RAW " <>
      "output before you say you are done. If this change cannot be checked " <>
      "by a command, say so plainly in your answer."
  end

  defp note(:chat, :test, files) do
    "You changed " <>
      Enum.join(files, ", ") <>
      " and no passing test run covers them. A build proves the code parses, " <>
      "not that it works. Run this project's tests (yourself, or through a helper), and ADD a test for the " <>
      "changed behaviour if none exists; read the raw output. If this change " <>
      "cannot be tested, say why in your answer."
  end

  defp note(:chat, :coverage, {files, runs}) do
    "A test run exited zero with no failure summary (" <>
      Enum.join(runs, "; ") <>
      "), but no test executed " <>
      Enum.join(files, ", ") <>
      ". A passing run proves a test exists, not that it covers your change. " <>
      "Add a test that calls the changed code through its real entry point " <>
      "(the function or route a caller uses, not a private helper), run the " <>
      "suite WITH COVERAGE yourself or through a helper " <>
      "(e.g. `mix test --cover`) and read the table. If " <>
      "this code cannot be executed by a test, say why in your answer."
  end

  defp note(:chat, :audit, request) do
    "Before you answer: nothing has checked the work against the request. " <>
      "Compiling, passing tests and covered code do not show that you built " <>
      "what was asked. Yourself, or through a helper given the request below " <>
      "word for word: list every explicit requirement in it " <>
      "as a separate item. For each, read the delivered code and mark it MET " <>
      "or NOT MET with the file and line. Check every literal the code " <>
      "compares against real data (enum codes, status strings, column " <>
      "values) by reading the data: a value assumed rather than observed is " <>
      "NOT MET. Fix anything NOT MET, then answer." <>
      quoted_request(request)
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
  defp original_request(messages) do
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
