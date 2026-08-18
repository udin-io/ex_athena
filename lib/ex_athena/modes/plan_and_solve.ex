defmodule ExAthena.Modes.PlanAndSolve do
  @moduledoc """
  Plan-and-Solve mode.

  Two-phase operation: on the first iteration, the agent is asked to
  **plan** before it acts. Subsequent iterations execute the plan using
  `ExAthena.Modes.ReAct`'s standard cycle.

  Rationale (Plan-and-Solve literature): models produce better
  tool-calling behaviour when they articulate a plan before diving into
  actions. Forcing the first turn to be planning-only prevents the
  "immediate tool call" failure mode you see with small models on
  complex prompts.

  ## State

  Plan-mode state is kept in `state.mode_state[:phase]`:

    * `:planning` — on the first iteration. A planning-only system-prompt
      addendum is injected, forbidding tool calls.
    * `:executing` — subsequent iterations fall through to the ReAct
      cycle.

  ## Configuration

      ExAthena.run(prompt, mode: :plan_and_solve, …)

  No extra options. The planning system prompt is hardcoded; consumers
  who want a custom planning instruction should implement their own Mode
  (the `ReAct` module is 200 lines of reference).
  """

  @behaviour ExAthena.Loop.Mode

  alias ExAthena.Loop.{Inference, State}

  @planning_addendum """

  ## Planning phase

  Before you take any action, produce a plan. Your response this turn
  MUST be plain text with no tool calls. Structure your plan as:

    1. **Goal** — what is the user asking for?
    2. **Approach** — how will you get there? Which tools will you need,
       in what order? If your plan depends on external facts you are
       unsure of (a library/API, convention, version, or current
       information), note that you will web_search to confirm them in the
       first execution step.
    3. **Risks** — what could go wrong, and how will you detect + recover?

  Once you finish your plan, wait for the next turn to begin executing.
  """

  @impl ExAthena.Loop.Mode
  def init(%State{} = state) do
    # Start in :planning phase. A planning-addendum is appended to the
    # system prompt; tools are withheld on this iteration.
    {:ok, %{state | mode_state: %{phase: :planning}}}
  end

  @impl ExAthena.Loop.Mode
  def iterate(%State{mode_state: %{phase: :planning}} = state) do
    # Run one inference with planning addendum + no tools. Append plan to
    # messages, transition to :executing, continue.
    request = build_planning_request(state)

    # Stream the planning turn like any ReAct turn (otherwise the first
    # thinking/content appears as one sudden blob). The shared inference
    # path supplies the request-queue slot, ChatParams hooks, the chat
    # telemetry span, and budget folding. The planning turn is a full,
    # turn-shaped call, so a starved response surfaces the kernel's typed
    # capacity signal and it retries planning once with an escalated
    # max_tokens. Mirrors ReAct.
    {stream_cb, counters} = ExAthena.Modes.ReAct.stream_callback(state)

    case Inference.call(state, request,
           purpose: :planning,
           starvation: :surface,
           stream_cb: stream_cb
         ) do
      {:halt, reason} ->
        state =
          %{state | halted_reason: reason}
          |> put_finish_reason(:error_halted)

        {:halt, state}

      {:ok, response, state} ->
        streamed_text? = counters != nil and :counters.get(counters, 1) > 0
        streamed_thinking? = counters != nil and :counters.get(counters, 2) > 0

        if not streamed_thinking? and is_binary(response.thinking) and response.thinking != "" do
          ExAthena.Loop.Events.emit(state.on_event, {:thinking, response.thinking})
        end

        if not streamed_text? and is_binary(response.text) and response.text != "" do
          ExAthena.Loop.Events.emit(state.on_event, {:content, response.text})
        end

        new_messages =
          state.messages ++ [ExAthena.Messages.assistant(response.text || "")]

        {:continue, %{state | messages: new_messages, mode_state: %{phase: :executing}}}

      # Output-starved planning turn: no visible plan text was produced
      # because the whole completion budget went to reasoning. Surface the
      # kernel's typed capacity signal so it retries planning once with an
      # escalated max_tokens. Mirrors ReAct.
      {:error, {:error_thinking_starved, _info, %State{}}} = starved ->
        starved

      # Context overflow during planning: surface the kernel's typed capacity
      # signal so it force-compacts the existing context and retries planning,
      # rather than dying as a generic execution error. Mirrors ReAct.
      {:error, %ExAthena.Error{kind: :context_length_exceeded}} ->
        {:error, :error_prompt_too_long}

      {:error, reason} ->
        {:error, {:plan_and_solve_planning_failed, reason}}
    end
  end

  def iterate(%State{mode_state: %{phase: :executing}} = state) do
    # Delegate to ReAct for the remaining iterations.
    ExAthena.Modes.ReAct.iterate(state)
  end

  def iterate(%State{} = state) do
    # No mode state (direct call) — behave like ReAct.
    ExAthena.Modes.ReAct.iterate(state)
  end

  # ── Internal ──────────────────────────────────────────────────────

  defp build_planning_request(state) do
    system_prompt =
      case state.request_template.system_prompt do
        nil -> @planning_addendum
        "" -> @planning_addendum
        str -> str <> @planning_addendum
      end

    %{
      state.request_template
      | messages: state.messages,
        system_prompt: system_prompt,
        # Explicitly no tools this turn — the planning phase is text-only.
        tools: nil
    }
  end

  defp put_finish_reason(state, reason) do
    put_in(state.meta[:finish_reason], reason)
  end
end
