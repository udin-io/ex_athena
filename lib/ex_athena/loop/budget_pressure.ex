defmodule ExAthena.Loop.BudgetPressure do
  @moduledoc """
  How close a run is to each of its limits, and what to tell the model.

  A finite-budget loop that keeps gathering runs out mid-exploration and is
  cut off before it writes its report, so once it enters the final stretch it
  is pushed to stop and produce an answer. That nudge used to watch only the
  ITERATION budget — which was never what actually killed anything.

  Session 994a17bcff20: two workers with a 50-turn budget both died on the
  30 minute deadline. The nudge fires at turn 38, so the first was told to
  wrap up on its very last turn, and the second reached turn 30 and was never
  told at all. Both had a todo list they had barely started, and neither was
  ever asked to hand the rest back.

  So pressure is measured against every budget a run has — iterations, wall
  clock, input tokens — and the note names the todo list, because the useful
  move for a worker that cannot finish is not to try harder: it is to finish
  what it can and say which todos it is leaving, so the orchestrator can
  re-delegate them as separate, smaller steps. That is also the cheapest
  available correction for the brief having been too big in the first place.

  ## Two states, not one

  Session 5906635b743d: three workers read this note with their file already
  written — one recorded "I'm near my budget limit, so I need to wrap up
  quickly" — and each then chose ONE more verification pass. That pass is what
  killed them, and because they died mid-turn they never wrote a report, so the
  orchestrator learned nothing and re-delegated work already sitting complete on
  disk.

  Telling a worker to skip verification would trade a visible failure for a
  silent one, so the directive to verify stays. What the note adds is the case
  it never covered: a deliverable that EXISTS but is unchecked is handed back
  immediately, labelled unverified and naming the checks not run, so the
  orchestrator can re-delegate verification as its own cheap step. Ranking the
  two matters more than listing them — all three workers knew they were near the
  ceiling and went one more round anyway.

  Configure the trigger with
  `config :ex_athena, :loop, wrap_up_at_percent: 75`.
  """

  alias ExAthena.Agents.Deadline
  alias ExAthena.Tuning

  @default_wrap_up_at_percent 75

  @type fractions :: %{
          iterations: float() | nil,
          wall_clock: float() | nil,
          input_tokens: float() | nil
        }

  @doc "Fraction of each budget consumed, or nil where that budget is unset."
  @spec fractions(map(), integer()) :: fractions()
  def fractions(state, now) do
    %{
      iterations: ratio(state.iterations, state.max_iterations),
      input_tokens: ratio(input_used(state), state.max_input_tokens),
      wall_clock: wall_clock_fraction(state, now)
    }
  end

  @doc """
  The wrap-up note for a run in its final stretch, or nil.

  Ephemeral — the caller appends it to the request tail, never to the
  transcript, so the cached prefix stays byte-stable.
  """
  @spec note(map(), integer()) :: String.t() | nil
  def note(state, now) do
    spent =
      state
      |> fractions(now)
      |> Map.values()
      |> Enum.reject(&is_nil/1)

    if spent != [] and Enum.max(spent) >= threshold() do
      build_note(state)
    end
  end

  defp threshold do
    Tuning.get(:loop, :wrap_up_at_percent, @default_wrap_up_at_percent) / 100
  end

  defp build_note(state) do
    "[runtime] You are #{state.iterations} turns in and near the end of your budget. " <>
      todo_progress(state) <>
      "Verifying your work is still your job — but under budget pressure it is the FIRST " <>
      "thing to cut, not the last. Pick the state you are in:\n" <>
      "- Deliverable NOT yet produced: reduce scope NOW. Stop gathering, produce what you " <>
      "can, and state explicitly which todos you did NOT complete and what remains for " <>
      "each, so the orchestrator can re-delegate them as separate steps.\n" <>
      "- Deliverable produced but NOT fully verified: hand it back NOW, in this turn. Do " <>
      "not start another verification pass — a pass you do not survive loses the report as " <>
      "well as the check. Open your report with UNVERIFIED, name the artifact and where it " <>
      "is, and list the checks you did not run so the orchestrator can re-delegate " <>
      "verification as its own cheap step.\n" <>
      "An honest partial report is worth far more than being cut off mid-exploration, and " <>
      "an unverified artifact the orchestrator knows about beats a verified one it never " <>
      "hears about."
  end

  # Tolerates both the string keys the tool receives and the atom keys the
  # coordinator normalises to.
  defp todo_progress(state) do
    todos = get_in(state, [Access.key(:meta, %{}), :todos]) || []

    case length(todos) do
      0 ->
        ""

      total ->
        done = Enum.count(todos, &(field(&1, "status") in ["completed", :completed]))
        "Todos: #{done} of #{total} completed. "
    end
  end

  defp field(todo, key) when is_map(todo) do
    Map.get(todo, key) || Map.get(todo, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(todo, key)
  end

  defp field(_todo, _key), do: nil

  defp input_used(state) do
    case state.budget do
      %{usage: usage} when is_map(usage) -> Map.get(usage, :input_tokens, 0)
      _ -> 0
    end
  end

  # Queue time is credited back, so a worker parked behind the provider is not
  # burning its budget — the same rule the deadline itself enforces.
  defp wall_clock_fraction(state, now) do
    assigns = (state.ctx && state.ctx.assigns) || %{}

    with deadline when is_integer(deadline) <- Map.get(assigns, :agent_deadline_at),
         from when is_integer(from) <- Map.get(assigns, :agent_deadline_from),
         granted when granted > 0 <- deadline - from,
         [counter | _] <- Map.get(assigns, :agent_wait_counters) do
      remaining = Deadline.remaining(deadline, counter, now)
      if remaining == :paused, do: nil, else: clamp((granted - remaining) / granted)
    else
      _ -> nil
    end
  end

  defp ratio(_used, cap) when not is_integer(cap) or cap <= 0, do: nil
  defp ratio(used, cap), do: clamp(used / cap)

  defp clamp(f) when f < 0.0, do: 0.0
  defp clamp(f) when f > 1.0, do: 1.0
  defp clamp(f), do: f
end
