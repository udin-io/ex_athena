defmodule ExAthena.Modes.Orchestrate do
  @moduledoc """
  Orchestrator mode: plan → todo → delegate each step to a subagent →
  integrate summaries → finish.

  Prompt-driven delegation inside **deterministic runtime rails** — the 2026
  consensus across Claude Code, Anthropic's multi-agent research system,
  OpenAI's manager pattern, and LangGraph's supervisor:

    * **Depth 1** — workers never spawn workers (enforced in SpawnAgent).
    * **Fan-out ≤ provider slots** — `max_concurrency` is capped at the
      provider's request-queue depth, so parallel workers can never exceed
      what the GPU actually serves.
    * **Strict task briefs** — `assigns[:strict_spawn]` makes SpawnAgent
      reject delegation without the four-field brief (objective,
      expected_output, tool_guidance, boundaries).
    * **Summary-only returns** — workers' final messages are the only thing
      entering this context (and the prompt forbids restating them).

  Mechanically it follows the PlanAndSolve shape: one tool-free planning
  iteration, then delegation-driven ReAct. The worker contract rides in as
  `assigns[:subagent_prompt_suffix]` (appended by SpawnAgent to every
  worker's system prompt) unless the caller supplied their own.
  """

  @behaviour ExAthena.Loop.Mode

  alias ExAthena.Loop.{Parallel, State}
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Permissions.Denial
  alias ExAthena.Tuning

  # ONE byte-stable protocol for both phases — phase-varying system prompts
  # (and toolsets) break prefix caching on local servers at token ~0.
  # Phase steering rides as an EPHEMERAL tail note instead (meta[:phase_note]).
  @protocol_addendum """
  ## Orchestration protocol
  You are the orchestrator. You NEVER read files, fetch URLs, or run
  commands yourself — delegate ALL exploration and execution to
  spawn_agent workers. Match the worker to the step:
    • agent: "explore" — read-only investigation of the codebase.
    • agent: "research" — external/up-to-date facts (web_search + web_fetch).
    • agent: "implementer" — steps that CHANGE the workspace: writing or
      editing code, creating files, applying patches, running commands.
  The explore/research workers are read-only and CANNOT modify files, so
  every implementation todo MUST be delegated to "implementer" (or another
  write-capable agent) — never to "explore". Work strictly through your
  todo list:
  1. FIRST record a draft plan with todo_write (one todo per step) based
     on what you already know — include ONE broad "Explore …" todo as step
     1 when investigation is needed (a single worker maps the whole
     structure; do NOT spawn several overlapping explorers — consult its
     report instead of re-exploring). Each todo must be small and
     self-contained enough to hand to a worker that cannot see this
     conversation.
  2. Delegate each substantial step to spawn_agent. Workers cannot see
     this conversation — every spawn needs `prompt:` (the instruction the
     worker acts on — ALWAYS include it), a self-contained brief
     (objective, expected_output, tool_guidance, boundaries) and `todo:`
     set to the exact todo content the worker handles. spawn_agent is
     SYNCHRONOUS: it runs the worker to completion and the worker's report
     is returned to you immediately as the tool result — it is already in
     your context on your very next turn. NEVER say you are "waiting" for a
     worker and never emit a turn with no tool call to wait — act on the
     report you just received, or call finish. If a worker's report is
     empty or unhelpful, record that and either re-delegate with a sharper
     brief or proceed with what you know.
  3. After each worker returns, update todo_write (mark completed, add
     newly discovered steps). ALWAYS send the FULL list — completed items
     included, new todos appended at the end; never drop finished work.
     Record decisions only — never restate worker output verbatim.
     Treat NEGATIVE findings ("X does not exist") as SETTLED facts: never
     re-delegate a search for something already reported absent. Record
     the absence and move on to the next step of the plan. When a worker
     reports it could NOT find something locally and the task plausibly
     depends on external/up-to-date information (library APIs, framework
     conventions, versions, web facts), delegate a research worker
     (agent: "research") whose brief says to web_search + web_fetch —
     do NOT keep re-delegating local-only exploration for information the
     codebase does not contain.
  4. Never delegate work that is not on the todo list — FIRST add the
     todo with todo_write, THEN spawn the worker with `todo:` set to it.
     One todo per worker; do not bundle several steps into one spawn.
  4b. Brief the OUTCOME, not the code. You hold no read tools, so any
     implementation you write into a brief was composed without seeing the
     file — that is how wrong code and invented values get typed in
     verbatim. State what the change must achieve, the constraints it must
     respect, and how to tell it worked; the worker can see the file and
     the data, so let it choose the code. Exact code is for the rare case
     where the precise text matters — then say what you based it on.
  5. Effort scaling: one worker for a simple step, two for comparisons.
     Workers run one at a time — delegate sequentially.
  6. When every todo is completed, call finish with a deliverable
     summarizing the outcome.
  7. When you need a DECISION or CLARIFICATION from the user (an ambiguous
     requirement, a choice between approaches, a missing precondition), you
     MUST call the ask_user tool with your question and options. Writing the
     question as plain text does NOTHING — it does not pause the run or reach
     the user, and you will just continue acting on a guess. Never proceed on
     an ambiguous choice without either a clearly-correct default or an
     ask_user call. Do NOT say "I will wait for your clarification" in text —
     that is not waiting; only ask_user waits.
  """

  @planning_note """
  [orchestration runtime] PLANNING: no plan is recorded yet — your next
  action should be todo_write with your draft plan (or spawn ONE explore
  worker first if you cannot draft anything). A tool-free numbered plan in
  text also works. If you cannot draft the plan because you lack external
  knowledge (a library API, framework convention, versions, or current
  facts), spawn a research worker (agent: "research") that uses web_search
  before drafting.\
  """

  # Deterministic research rail. If the orchestrator burns this many planning
  # turns without recording any plan, it is context-starved — steer it (once)
  # to delegate online research rather than keep spinning (half the planning
  # budget, so it fires before the hard transition at @max_planning_turns). If
  # that directive is ignored and planning STILL stalls by the escalation
  # threshold, the runtime delegates research itself (a `research` worker) —
  # prompts alone don't bind small models.
  @research_planning_threshold 4
  @research_escalation_threshold 6

  @research_planning_note """
  [orchestration runtime] PLANNING is stalling and no plan is recorded yet. If
  you lack the external knowledge to draft the plan (a library/API, framework
  convention, version, or current fact), delegate it NOW: spawn_agent(agent:
  "research") with a focused brief to web_search the open question, then use its
  findings to record your todos with todo_write.\
  """

  @worker_suffix """
  ## Worker contract
  You are a sub-agent responsible for ONE step of a larger task.
  - Maintain your own todo list with todo_write as you work.
  - For Elixir code, prefer the `lsp` tool over `grep`: `workspace_symbol`
    finds a module/function/type by name project-wide, `definition`/
    `references` trace it, and `document_symbol` outlines a file — all
    AST-accurate. Use `grep` for plain-text or cross-language search.
  - Record NEGATIVE findings explicitly ("X does not exist", "no blog
    directory") — never re-search for something already established absent.
    If a search (glob/grep) returns no matches TWICE for the same target,
    record it as absent and STOP searching — do not rephrase the query.
    If a fact is absent locally but the task needs it (an external API,
    library docs, current information), use web_search then web_fetch ONCE
    to get it from authoritative sources, then record what you found —
    never web_search the same query twice.
  - NEVER state how a library, framework or API behaves from memory. Call
    `usage_rules` for that package first (it reads the local docs the
    dependency ships); if it has none, web_search the official docs. A
    confident wrong answer about an API costs far more than the lookup.
  - If you CHANGE code you must verify it: write or update a test that
    exercises the new behaviour BEFORE editing the source where practical,
    then run the project's test command and paste the RAW output tail into
    your report. Building is not testing — code that compiles can still fail
    on its first real call. Never report success from reading your own diff,
    and never claim a command's outcome without having run it.
  - Any literal your code compares against real data (enum codes, status
    strings, column values) must be OBSERVED, not guessed — read it from the
    data or an existing use, and say where. If you could not observe it, list
    it as an ASSUMPTION in your report.
  - Deliver what was ASKED. Do not add conditions nobody requested or narrow
    a stated scope; if the request seems wrong, implement it and say so.
  - Test through the REAL entry point a caller uses, not a private helper you
    just wrote — a helper test passes while the feature stays broken.
  - Your FINAL message is the ONLY thing the orchestrator sees — make it a
    complete, self-contained report: every concrete fact discovered (exact
    paths, file names, patterns, config/frontmatter formats, snippets),
    NEGATIVE findings, decisions made, and files changed. Completeness
    beats brevity — never summarize away specifics the next step will
    need (up to ~800 words).
  """

  # The orchestrator gets coordination tools ONLY — no specialist tools on
  # the supervisor, NO exceptions (LangGraph supervisor rule). Live testing
  # showed even read/glob/grep let a small local model burn every iteration
  # on self-investigation instead of delegating. Any inspection now costs a
  # worker spawn, which is the point. It also shrinks the tool-schema
  # prompt for weak models.
  @orchestrator_tools ~w(todo_write spawn_agent finish ask_user)

  # Exploration during planning is bounded — after this many planning turns
  # the runtime forces the transition to execution with what is known.
  # (Planning uses the SAME coordination toolset as executing — tool
  # schemas render into the prompt prefix, so phase-varying toolsets break
  # prefix caching.)
  @max_planning_turns 8

  # Auto-delegation watchdog: with pending todos, after this many
  # consecutive turns without a spawn_agent call the runtime delegates the
  # first pending todo itself (deterministic rail — prompts alone don't
  # bind small models).
  @max_turns_without_spawn 2

  @impl true
  def init(%State{} = state) do
    assigns =
      state.ctx.assigns
      |> Map.put(:strict_spawn, true)
      |> Map.put_new(:subagent_prompt_suffix, String.trim(@worker_suffix))

    request_template = %{
      state.request_template
      | system_prompt:
          append_prompt(state.request_template.system_prompt, String.trim(@protocol_addendum))
    }

    {:ok,
     %{
       state
       | mode_state: %{
           phase: :planning,
           turns_without_spawn: 0,
           planning_turns: 0
         },
         # Uncapped by design (user-directed): the orchestrator runs until
         # the todos are done. The no-progress guard, mistake counter,
         # budget cap, and the host's stop control bound the run. An
         # explicitly passed cap is honored.
         max_iterations: orchestrator_iterations(state),
         max_concurrency: min(state.max_concurrency, slot_cap(state)),
         tool_specs: Enum.filter(state.tool_specs, &(&1.name in @orchestrator_tools)),
         ctx: %{state.ctx | assigns: assigns},
         # Ephemeral phase steering (request tail, never persisted) —
         # cleared by to_executing/1.
         meta: Map.put(state.meta, :phase_note, String.trim(@planning_note)),
         request_template: request_template
     }}
  end

  defp orchestrator_iterations(%State{meta: %{explicit_max_iterations?: true}} = state),
    do: state.max_iterations

  defp orchestrator_iterations(_state), do: :infinity

  @impl true
  def productivity_signal(prev_state, new_state),
    do: ExAthena.Modes.ReAct.productivity_signal(prev_state, new_state)

  @impl true
  def iterate(%State{mode_state: %{phase: :planning} = mode_state} = state) do
    # Planning is plain ReAct with the SAME toolset/system prompt as
    # executing (byte-stable prefix for cache reuse) — only an ephemeral
    # tail note (meta[:phase_note]) steers the phase. Planning ends when
    # the plan exists: a todo_write (the todo list IS the plan) or a
    # tool-free reply.
    case ExAthena.Modes.ReAct.iterate(state) do
      {:halt, halted} ->
        cond do
          halted.meta[:finish_reason] == :stop ->
            # The tool-free plan turn — transition instead of terminating.
            {:continue, to_executing(halted)}

          # A premature `finish` with NO plan would end the run as
          # :submitted success having done nothing — redirect once.
          match?({:submitted, _}, halted.halted_reason) and current_todos(halted) == [] ->
            {:continue,
             halted
             |> redirect(
               "[orchestration runtime] You called finish before recording any plan — " <>
                 "record your todos with todo_write and delegate the work first."
             )
             |> Map.put(:halted_reason, nil)
             |> to_executing()}

          true ->
            # Real terminations (errors) propagate untouched.
            {:halt, halted}
        end

      {:continue, new_state} ->
        turns = (mode_state[:planning_turns] || 0) + 1

        cond do
          # The kernel records meta[:todos] only from SUCCESSFUL todo_write
          # calls — a rejected/invalid one must not end planning (and could
          # not seed an empty plan).
          new_state.meta[:todos] != state.meta[:todos] and new_state.meta[:todos] != nil ->
            {:continue, new_state |> put_watch(0) |> to_executing()}

          turns >= tuning(:max_planning_turns, @max_planning_turns) ->
            {:continue,
             new_state
             |> redirect(
               "[orchestration runtime] Planning budget exhausted — proceed to execution " <>
                 "with what you know: record your todos with todo_write and delegate."
             )
             |> to_executing()}

          true ->
            next = put_in(new_state.mode_state[:planning_turns], turns)
            {:continue, maybe_research_nudge(next, turns)}
        end

      other ->
        other
    end
  end

  def iterate(%State{mode_state: %{phase: :executing}} = state) do
    prev_count = length(state.messages)

    case ExAthena.Modes.ReAct.iterate(state) do
      {:continue, new_state} ->
        watchdog(new_state, prev_count)

      {:halt, halted} ->
        maybe_nudge_stop(halted)

      other ->
        other
    end
  end

  # Small models routinely narrate intent ("I will now create the post")
  # with no tool call — a bare-text :stop OR a premature `finish` with
  # PENDING todos would end the run mid-task as "success". Nudge once;
  # honor the second stop. (`stop_nudged` is re-armed by put_watch when a
  # successful spawn happens or the todo list changes.)
  defp maybe_nudge_stop(halted) do
    pending = pending_todos(halted)
    todos = current_todos(halted)

    premature? =
      halted.meta[:finish_reason] == :stop or match?({:submitted, _}, halted.halted_reason)

    # A clean halt requires todos that are ALL done. `pending == []` alone
    # is also true when NO plan was ever recorded (todos == []) — stopping
    # there delegated nothing, so nudge to record a plan.
    all_done? = todos != [] and pending == []

    # Only a `finish` can be gated on evidence: a bare-text stop is already
    # handled below, and scanning the transcript is wasted work otherwise.
    ev = if match?({:submitted, _}, halted.halted_reason), do: evidence(halted), else: nil

    cond do
      # Gate 1 — nothing ran at all. Fires on an otherwise CLEAN finish,
      # because that is exactly the shape of the failure: every todo marked
      # completed (self-reported, so it proves nothing) and a deliverable
      # asserting a build no worker ever ran. Worker provenance is derived
      # from the workers' own tool calls, so it cannot be narrated away.
      gate?(halted, ev, :verify_nudged, &(&1.changed != [] and not &1.acted?)) ->
        nudge(halted, :verify_nudged, verify_note(ev.changed))

      # Gate 2 — something ran, but nothing exercised the change. A build
      # proves the code parses; the live failure compiled cleanly and raised
      # on every page load.
      gate?(halted, ev, :test_nudged, &(&1.source_changed != [] and not &1.tested?)) ->
        nudge(halted, :test_nudged, test_note(ev.source_changed))

      # Gate 3 — tests ran green, but never executed the changed code. A live
      # run tested a private helper it had just written, reported 252 passing,
      # and shipped a page that raised on every load.
      gate?(halted, ev, :coverage_nudged, &(&1.uncovered != [])) ->
        nudge(halted, :coverage_nudged, coverage_note(ev.uncovered))

      # Gate 4 — everything mechanical is satisfied, but nothing has compared
      # the delivered work to what was actually asked for. A live run was
      # asked for "all records" and shipped a filter on invented column values
      # matching none of them: it compiled, tests passed, the changed code
      # ran. No mechanical check can see a requirement silently dropped.
      gate?(halted, ev, :audit_nudged, &(&1.source_changed != [])) ->
        nudge(halted, :audit_nudged, audit_note(original_request(halted)))

      not premature? or all_done? ->
        {:halt, halted}

      halted.mode_state[:stop_nudged] ->
        {:halt, halted}

      true ->
        note =
          if pending == [] do
            "[orchestration runtime] You stopped without recording any plan — " <>
              "record your todos with todo_write and delegate the work."
          else
            "[orchestration runtime] You stopped with PENDING todos: " <>
              Enum.map_join(pending, "; ", &field(&1, :content)) <>
              ". Delegate the next one with spawn_agent, or call finish if the task is truly done."
          end

        {:continue,
         halted
         |> redirect(note)
         |> Map.put(:halted_reason, nil)
         |> put_in([Access.key(:mode_state), :stop_nudged], true)
         |> Map.put(:meta, Map.delete(halted.meta, :finish_reason))}
    end
  end

  # Each gate is one-shot: it raises the floor without ever trapping a run that
  # genuinely cannot verify, and the run terminates after at most one extra
  # iteration per gate.
  defp gate?(_halted, nil, _flag, _deficient?), do: false

  defp gate?(halted, ev, flag, deficient?),
    do: halted.mode_state[flag] != true and deficient?.(ev)

  defp nudge(halted, flag, note) do
    {:continue,
     halted
     |> redirect(note)
     |> Map.put(:halted_reason, nil)
     |> put_in([Access.key(:mode_state), flag], true)
     |> Map.put(:meta, Map.delete(halted.meta, :finish_reason))}
  end

  # What the workers' own tool calls prove about this run.
  #
  # `acted?` is a FLOOR, not a proof: any non-read-only command clears it, so a
  # worker that ran `mkdir` counts. It exists to make "nothing was checked"
  # impossible to finish through silently. `tested?` is the sharper check —
  # a test runner that actually exited zero.
  defp evidence(state) do
    transcript = transcript_text(state)
    events = ExAthena.Provenance.scan(transcript)
    files = ExAthena.Provenance.changed_files(events)
    commands = ExAthena.Provenance.commands(events)
    failed = ExAthena.Provenance.failed_commands(events)
    source_changed = Enum.reject(files, &ExAthena.Provenance.test_file?/1)
    tested? = Enum.any?(commands, &(ExAthena.Provenance.test_command?(&1) and &1 not in failed))

    %{
      changed: files,
      source_changed: source_changed,
      acted?:
        Enum.any?(commands, &(not ExAthena.Tools.Bash.read_only_command?(%{"command" => &1}))),
      tested?: tested?,
      # Only asked once tests are green: before that, gates 1 and 2 own the
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
    "[orchestration runtime] Workers changed " <>
      Enum.join(files, ", ") <>
      " but no command was run to check them — a completed todo is your own " <>
      "claim, not evidence. Spawn ONE worker whose brief is to run this " <>
      "project's build/test command and report its RAW output, then call " <>
      "finish. If this task genuinely cannot be checked by a command, call " <>
      "finish again and say so in the deliverable."
  end

  # The FIRST user turn, verbatim. The audit must run against what was
  # actually asked, never the orchestrator's own restatement of it — a
  # paraphrase is where the dropped requirement went missing in the first
  # place. (Compaction was not the cause: the live failure ran 37 iterations
  # with zero compaction events, so the request was in context throughout and
  # simply was never re-read.)
  defp original_request(%State{messages: messages}) do
    Enum.find_value(messages, "", fn
      %{role: :user, content: content} when is_binary(content) -> content
      _ -> nil
    end)
  end

  @audit_request_chars 1_500

  defp audit_note(request) do
    request =
      if String.length(request) > tuning(:audit_request_chars, @audit_request_chars),
        do: String.slice(request, 0, tuning(:audit_request_chars, @audit_request_chars)) <> "…",
        else: request

    "[orchestration runtime] Before finishing: nothing has checked the " <>
      "delivered work against the ORIGINAL request. Compiling, passing tests " <>
      "and covered code do not show that you built what was asked. Spawn ONE " <>
      "worker to audit it. Give that worker the request below VERBATIM and " <>
      "tell it to: list every explicit requirement as a separate item; for " <>
      "each, read the actual delivered code and state MET or NOT MET with the " <>
      "file and line as evidence; and check every literal value the code " <>
      "compares against real data (enum codes, status strings, column values) " <>
      "by querying or reading the data — a value that was assumed rather than " <>
      "observed is NOT MET. It must actively look for requirements that were " <>
      "narrowed, widened or dropped. Fix anything NOT MET, then finish.\n\n" <>
      "ORIGINAL REQUEST:\n" <> request
  end

  defp coverage_note(files) do
    "[orchestration runtime] The suite is green but no test executed " <>
      Enum.join(files, ", ") <>
      " — a passing suite proves a test EXISTS, not that it covers your " <>
      "change. Spawn ONE worker to add a test that calls the changed code " <>
      "through its real entry point (the function or route a caller actually " <>
      "uses, not a private helper), run the suite WITH COVERAGE " <>
      "(e.g. `mix test --cover`), and paste the coverage table plus the raw " <>
      "test output. Then call finish. If this code genuinely cannot be " <>
      "executed by a test, call finish again and say why."
  end

  defp test_note(files) do
    "[orchestration runtime] Workers changed " <>
      Enum.join(files, ", ") <>
      " and no test run covered them — a build proves the code parses, not " <>
      "that it works. Spawn ONE worker to run this project's test suite, and " <>
      "to ADD a test exercising the changed behaviour if none does; it must " <>
      "report the raw output. Then call finish. If this change genuinely " <>
      "cannot be tested, call finish again and say why in the deliverable."
  end

  # Deliver a runtime redirect message while keeping the transcript valid:
  # if the last assistant turn made tool calls (e.g. `finish`), respond with
  # a TOOL RESULT for each (strict OpenAI-compatible servers 400 on an
  # assistant tool_call with no paired result); otherwise append a plain
  # user note.
  defp redirect(state, text) do
    case List.last(state.messages) do
      %{role: :assistant, tool_calls: [_ | _] = calls} ->
        results =
          Enum.map(calls, fn c -> ExAthena.Messages.tool_result(c.id, text, true) end)

        %{state | messages: state.messages ++ results}

      _ ->
        %{state | messages: state.messages ++ [ExAthena.Messages.user(text)]}
    end
  end

  defp current_todos(state), do: state.meta[:todos] || []

  defp pending_todos(state) do
    Enum.filter(current_todos(state), fn t ->
      field(t, :status) in [nil, "pending", "in_progress"]
    end)
  end

  # ── Auto-delegation watchdog ──────────────────────────────────────

  # Track the latest todo list and whether the model delegated this turn;
  # after @max_turns_without_spawn spawn-less turns with pending todos, the
  # RUNTIME delegates the first pending todo (jido directive style: the
  # decision stays observable, the effect is executed by code).
  defp watchdog(state, prev_count) do
    new_msgs = Enum.drop(state.messages, prev_count)
    state = capture_findings(state, new_msgs)

    calls =
      Enum.flat_map(new_msgs, fn
        %{role: :assistant, tool_calls: tcs} when is_list(tcs) -> tcs
        _ -> []
      end)

    # Only a SUCCESSFUL spawn counts as delegation — live testing showed a
    # model repeating an invalid spawn call verbatim every turn, which must
    # not keep resetting the watchdog.
    spawn_ids = for tc <- calls, tc.name == "spawn_agent", do: tc.id

    spawned? =
      new_msgs
      |> Enum.flat_map(fn
        %{role: :tool, tool_results: trs} when is_list(trs) -> trs
        _ -> []
      end)
      |> Enum.any?(fn tr -> tr.tool_call_id in spawn_ids and tr.is_error != true end)

    turns = if spawned?, do: 0, else: (state.mode_state[:turns_without_spawn] || 0) + 1

    # Never auto-delegate the same todo twice — a model that doesn't
    # rewrite its todos would otherwise respawn the same first pending
    # item every 2 turns, forever (the run is :infinity-capped).
    delegated = state.mode_state[:auto_delegated] || MapSet.new()

    fresh_pending =
      Enum.reject(pending_todos(state), fn t -> MapSet.member?(delegated, field(t, :content)) end)

    {state, repeated?} = track_repeat(state, calls)
    {state, dictating?} = track_dictated_code(state, calls)

    cond do
      # Writing implementations into briefs is the orchestrator acting as an
      # implementer while configured as a coordinator: it must know the file
      # to write the diff, but only receives worker summaries — so it
      # re-requests files and guesses the rest. Steer it back to outcomes.
      dictating? ->
        {:continue, put_watch(redirect(state, dictated_code_note()), turns)}

      # Re-delegating the SAME objective over and over is not progress, but the
      # no-progress guard cannot see it: spawning is activity. A live run spent
      # its last hour re-spawning "make mix test pass cleanly" against tests
      # that could not pass in that environment.
      repeated? ->
        {:continue, put_watch(redirect(state, repeat_note()), turns)}

      fresh_pending != [] and turns >= tuning(:max_turns_without_spawn, @max_turns_without_spawn) ->
        todo = hd(fresh_pending)
        state = auto_delegate(state, todo)

        state =
          put_in(
            state.mode_state[:auto_delegated],
            MapSet.put(delegated, field(todo, :content))
          )

        {:continue, put_watch(state, 0)}

      true ->
        {:continue, put_watch(state, turns)}
    end
  end

  # One dictated implementation can be a deliberate, well-founded choice
  # (the orchestrator may genuinely know the change). A habit of it is the
  # coordinator/implementer mismatch, so the rail fires on the second.
  @max_dictated_briefs 2

  defp track_dictated_code(state, calls) do
    dictated =
      Enum.count(calls, fn tc ->
        tc.name == "spawn_agent" and
          ExAthena.Tools.SpawnAgent.dictated_code?(brief_prompt(tc.arguments))
      end)

    total = (state.mode_state[:dictated_briefs] || 0) + dictated

    fire? =
      not (state.mode_state[:dictated_nudged] || false) and
        total >= tuning(:max_dictated_briefs, @max_dictated_briefs)

    mode_state =
      state.mode_state
      |> Map.put(:dictated_briefs, total)
      |> then(fn ms -> if fire?, do: Map.put(ms, :dictated_nudged, true), else: ms end)

    {%{state | mode_state: mode_state}, fire?}
  end

  defp brief_prompt(args) when is_map(args), do: Map.get(args, "prompt") || ""
  defp brief_prompt(_), do: ""

  defp dictated_code_note do
    "[orchestration runtime] You are writing implementations into your " <>
      "briefs. You have not read these files — you hold no read tools — so " <>
      "that code is composed blind, and it is why you keep spending workers " <>
      "on \"report the contents of X\". Delegate the OUTCOME instead: state " <>
      "what the change must achieve, the constraints it must respect, and " <>
      "how to tell it worked — then let the worker, which can see the file " <>
      "and the data, decide the code. Reserve exact code for cases where the " <>
      "precise text genuinely matters, and say what you based it on."
  end

  # How many times the same objective may be delegated before the runtime
  # says so. Two is a legitimate retry with a sharper brief; three is a loop.
  @max_same_objective 3

  # Objectives are compared on a normalised prefix: a model re-delegating the
  # same work rarely reproduces it byte-for-byte, but the opening line is
  # stable ("You are working on `/x`. Your ONLY job is to make mix test pass…").
  defp track_repeat(state, calls) do
    objectives =
      for tc <- calls,
          tc.name == "spawn_agent",
          obj = repeat_key(tc.arguments),
          obj != "",
          do: obj

    counts = state.mode_state[:objective_counts] || %{}

    counts =
      Enum.reduce(objectives, counts, fn obj, acc -> Map.update(acc, obj, 1, &(&1 + 1)) end)

    repeated? =
      not (state.mode_state[:repeat_nudged] || false) and
        Enum.any?(
          objectives,
          &(Map.get(counts, &1, 0) >= tuning(:max_same_objective, @max_same_objective))
        )

    mode_state =
      state.mode_state
      |> Map.put(:objective_counts, counts)
      |> then(fn ms -> if repeated?, do: Map.put(ms, :repeat_nudged, true), else: ms end)

    {%{state | mode_state: mode_state}, repeated?}
  end

  @repeat_key_chars 120

  defp repeat_key(args) when is_map(args) do
    (Map.get(args, "objective") || Map.get(args, "prompt") || "")
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, Tuning.get(:orchestrate, :repeat_key_chars, @repeat_key_chars))
  end

  defp repeat_key(_), do: ""

  defp repeat_note do
    "[orchestration runtime] You have now delegated the same objective " <>
      "#{tuning(:max_same_objective, @max_same_objective)} times. Repeating it is not progress — the " <>
      "obstacle is not that the worker misunderstood. Either change the " <>
      "approach (a different angle, a smaller step, or fixing a blocker the " <>
      "reports keep naming), or accept that this step cannot be completed in " <>
      "this environment: record what blocks it, mark the todo, and move on to " <>
      "the remaining work or finish with the blocker stated in your " <>
      "deliverable. Do NOT spawn this objective again."
  end

  # Todos come from the KERNEL's meta[:todos] (success-filtered — see
  # ReAct.record_todos); the mode keeps only the watch counters. A
  # successful spawn or a changed todo list re-arms the stop nudge.
  defp put_watch(state, turns) do
    todos = current_todos(state)

    mode_state =
      state.mode_state
      |> Map.put(:turns_without_spawn, turns)
      |> then(fn ms ->
        if turns == 0 or ms[:seen_todos] != todos,
          do: Map.delete(ms, :stop_nudged),
          else: ms
      end)
      |> Map.put(:seen_todos, todos)

    # Surface completed-todo contents into ctx.assigns so SpawnAgent can
    # short-circuit a re-delegation of finished work (ctx.assigns flows
    # into tool execution). Deterministic "don't repeat steps" rail.
    completed =
      for t <- todos, field(t, :status) == "completed", into: MapSet.new(), do: field(t, :content)

    %{
      state
      | mode_state: mode_state,
        ctx: put_assign(state.ctx, :completed_todos, completed),
        # Live plan-status block at the request tail (ephemeral, cache-safe)
        # — keeps the orchestrator ON its plan and surfaces what each step
        # already established so it never re-investigates settled work.
        meta: Map.put(state.meta, :phase_note, plan_status(state))
    }
  end

  defp put_assign(ctx, key, value),
    do: %{ctx | assigns: Map.put(ctx.assigns || %{}, key, value)}

  # Pair each completed spawn with its linked todo so the plan-status block
  # can show "[x] step — <finding>". Findings accumulate across turns.
  defp capture_findings(state, new_msgs) do
    results =
      new_msgs
      |> Enum.flat_map(fn
        %{role: :tool, tool_results: trs} when is_list(trs) -> trs
        _ -> []
      end)
      |> Map.new(fn tr -> {tr.tool_call_id, to_string(tr.content || "")} end)

    spawn_findings =
      for %{role: :assistant, tool_calls: tcs} <- new_msgs,
          is_list(tcs),
          tc <- tcs,
          tc.name == "spawn_agent",
          todo = tc.arguments["todo"],
          is_binary(todo),
          result = results[tc.id],
          is_binary(result) and result != "",
          into: %{} do
        {todo, truncate(result, 150)}
      end

    findings = Map.merge(state.mode_state[:findings] || %{}, spawn_findings)
    put_in(state.mode_state[:findings], findings)
  end

  defp plan_status(state) do
    todos = current_todos(state)
    findings = state.mode_state[:findings] || %{}

    if todos == [] do
      nil
    else
      {lines, _flagged} =
        Enum.map_reduce(todos, false, fn t, flagged_next ->
          content = field(t, :content)
          status = field(t, :status)
          marker = todo_marker(status)

          suffix =
            cond do
              status == "completed" and is_binary(findings[content]) ->
                " — #{findings[content]}"

              status not in ["completed"] and not flagged_next ->
                "  ← work on THIS next"

              true ->
                ""
            end

          flag? = flagged_next or status not in ["completed"]
          {"  #{marker} #{content}#{suffix}", flag?}
        end)

      "[orchestration runtime] Plan status:\n" <>
        Enum.join(lines, "\n") <>
        "\nDo NOT re-investigate completed steps or re-search facts already established above."
    end
  end

  defp todo_marker("completed"), do: "[x]"
  defp todo_marker("in_progress"), do: "[~]"
  defp todo_marker(_), do: "[ ]"

  defp truncate(text, max) do
    text = String.trim(text)
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp auto_delegate(state, todo) do
    content = field(todo, :content) || "the next pending step"

    args = %{
      "prompt" => "Complete this step of a larger task: #{content}",
      "objective" => content,
      "expected_output" =>
        "a self-contained summary (max 300 words) of findings, decisions, and files changed",
      "tool_guidance" =>
        "use any available tools (read, glob, grep, bash, write, edit) as needed",
      "boundaries" => "do only this step; do not start other todos",
      "todo" => content,
      # Generous: exploration reports carry exact paths/patterns the next
      # step needs — a 2k cap was destroying the discovered detail.
      "max_result_chars" => 8_000
    }

    case gated_auto_spawn(state, args, "auto_delegate_#{System.unique_integer([:positive])}") do
      {:halt, reason} ->
        halt_early(state, reason)

      gate_result ->
        note =
          case gate_result do
            {:ok, {:ok, text, _ui}} ->
              "[orchestration runtime] You did not delegate, so the runtime delegated the " <>
                ~s(pending todo "#{content}" to a worker. Worker summary:\n#{text}\n) <>
                "Update your todo list, then delegate the next pending todo with spawn_agent."

            {:ok, {:error, reason}} ->
              "[orchestration runtime] Auto-delegation of \"#{content}\" failed: " <>
                "#{inspect(reason)}. Revise the plan or delegate it yourself with spawn_agent."

            {:deny, reason} ->
              "[orchestration runtime] Auto-delegation of \"#{content}\" was blocked by " <>
                "permissions: #{deny_reason(reason)}. spawn_agent is not permitted in this " <>
                "run — revise the plan or finish with what you have."
          end

        %{state | messages: state.messages ++ [ExAthena.Messages.user(note)]}
    end
  end

  # Runtime-issued spawns run through the SAME pre-tool gate (permissions +
  # PreToolUse hooks) as model-initiated calls — issue #130: a
  # `disallowed_tools: ["spawn_agent"]` blocklist or a PreToolUse deny hook
  # must stop auto-delegation too, and `PermissionDenied`/`ToolDenied`
  # lifecycle hooks fire exactly as they would for a model call.
  defp gated_auto_spawn(state, args, id) do
    call = %ToolCall{id: id, name: "spawn_agent", arguments: args}

    case Parallel.pre_tool_gate(call, state) do
      :allow ->
        ctx = %{state.ctx | tool_call_id: id}
        {:ok, ExAthena.Tools.SpawnAgent.execute(args, ctx)}

      {:deny, _reason} = deny ->
        deny

      {:halt, _reason} = halt ->
        halt
    end
  end

  # A `{:halt, reason}` from the gate (can_use_tool or a hook requesting a
  # hard stop) is honored via the kernel's meta[:early_halt] check at the
  # next loop entry — the watchdog/nudge paths themselves only ever
  # continue.
  defp halt_early(state, reason), do: put_in(state.meta[:early_halt], reason)

  defp deny_reason(%Denial{reason: r}), do: r
  defp deny_reason(r) when is_binary(r), do: r
  defp deny_reason(r), do: inspect(r)

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  # ── Internal ──────────────────────────────────────────────────────

  # Fan-out can never exceed what the provider actually serves concurrently.
  defp slot_cap(%State{meta: %{provider_atom: atom}}) when is_atom(atom) and not is_nil(atom),
    do: ExAthena.Config.request_queue_max_depth(atom)

  defp slot_cap(_state), do: 4

  defp append_prompt(nil, addendum), do: addendum
  defp append_prompt("", addendum), do: addendum
  defp append_prompt(existing, addendum), do: existing <> "\n\n" <> addendum

  # Deterministic research rail (planning phase), with escalation:
  #
  #   1. Directive — once planning has burned @research_planning_threshold turns
  #      with still no plan, replace the ephemeral planning tail note (once)
  #      with a directive to delegate online research. The orchestrator can't
  #      search itself, so this steers it to spawn a research worker. Cleared at
  #      to_executing/1 like any phase note.
  #   2. Escalation — if that directive is ignored and planning STILL stalls by
  #      @research_escalation_threshold, the runtime delegates research itself
  #      (a `research` worker) and feeds the findings back as a note. Once only,
  #      latched by mode_state[:research_spawned].
  defp maybe_research_nudge(state, turns) do
    nudged? = state.mode_state[:research_nudged] == true
    spawned? = state.mode_state[:research_spawned] == true

    cond do
      turns >= tuning(:research_planning_threshold, @research_planning_threshold) and not nudged? and
          current_todos(state) == [] ->
        %{
          state
          | mode_state: Map.put(state.mode_state, :research_nudged, true),
            meta: Map.put(state.meta, :phase_note, String.trim(@research_planning_note))
        }

      turns >= tuning(:research_escalation_threshold, @research_escalation_threshold) and nudged? and
        not spawned? and
          current_todos(state) == [] ->
        state
        |> Map.update!(:mode_state, &Map.put(&1, :research_spawned, true))
        |> auto_delegate_research()

      true ->
        state
    end
  end

  # Runtime-issued online research when planning stays context-starved. Mirrors
  # auto_delegate/2 but spawns the `research` agent (web_search/web_fetch/
  # usage_rules) and feeds its findings back so the orchestrator can finally
  # record a plan.
  defp auto_delegate_research(state) do
    objective = research_objective(state)

    args = %{
      "agent" => "research",
      "prompt" =>
        "Research online to gather the external context needed for this task: #{objective}",
      "objective" => objective,
      "expected_output" =>
        "a self-contained, source-cited summary (max 300 words) of the facts needed to plan the task",
      "tool_guidance" =>
        "web_search then web_fetch; for an Elixir dependency call usage_rules first",
      "boundaries" => "research only — do not modify any files",
      "max_result_chars" => 8_000
    }

    case gated_auto_spawn(state, args, "auto_research_#{System.unique_integer([:positive])}") do
      {:halt, reason} ->
        halt_early(state, reason)

      gate_result ->
        note =
          case gate_result do
            {:ok, {:ok, text, _ui}} ->
              "[orchestration runtime] Planning stalled, so the runtime delegated online " <>
                "research to a worker. Findings:\n#{text}\n" <>
                "Now record your todos with todo_write using these findings and delegate the work."

            {:ok, {:error, reason}} ->
              "[orchestration runtime] Auto-research failed: #{inspect(reason)}. " <>
                "Record your todos with todo_write from what you know and delegate."

            {:deny, reason} ->
              "[orchestration runtime] Auto-research was blocked by permissions: " <>
                "#{deny_reason(reason)}. Record your todos with todo_write from what " <>
                "you know."
          end

        %{state | messages: state.messages ++ [ExAthena.Messages.user(note)]}
    end
  end

  # The task to research = the original user request (first user message).
  defp research_objective(state) do
    Enum.find_value(state.messages, "the user's task", fn
      %{role: :user, content: c} when is_binary(c) and c != "" -> String.slice(c, 0, 500)
      _ -> false
    end)
  end

  # Switch phases: clear the stale :stop set by a tool-free plan turn and
  # drop the ephemeral planning tail note.
  defp to_executing(state) do
    %{
      state
      | mode_state: Map.put(state.mode_state, :phase, :executing),
        meta: state.meta |> Map.delete(:finish_reason) |> Map.delete(:phase_note)
    }
  end

  # Every rail below is a config key whose default is the attribute it was
  # first tuned to. See `ExAthena.Tuning`.
  defp tuning(key, default), do: Tuning.get(:orchestrate, key, default)
end
