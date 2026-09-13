defmodule ExAthena.Loop.BudgetPressureTest do
  @moduledoc """
  The wrap-up nudge existed but watched only the ITERATION budget, and that
  was never what killed anything. Both runaway workers in session
  994a17bcff20 had a 50-turn budget and died on the 30-minute deadline: the
  first was told to wrap up on turn 38, its very last turn, and the second
  reached turn 30 and was never told at all — the nudge fires at 38.

  It also never mentioned the worker's todo list, so a worker with eight jobs
  and no time was not asked to do the one thing that would have helped: finish
  what it could and say which ones it was leaving.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Loop.BudgetPressure

  defp state(fields) do
    Map.merge(
      %{
        iterations: 0,
        max_iterations: 50,
        max_input_tokens: 0,
        budget: ExAthena.Budget.new(),
        meta: %{},
        ctx: nil
      },
      Map.new(fields)
    )
  end

  defp with_tokens(state, used) do
    %{state | budget: ExAthena.Budget.add(state.budget, %{input_tokens: used}, nil)}
  end

  describe "fractions/2 — how close each budget is to spent" do
    test "iterations" do
      assert %{iterations: f} = BudgetPressure.fractions(state(iterations: 25), 0)
      assert_in_delta f, 0.5, 0.001
    end

    test "input tokens, and nil when uncapped" do
      s = state(max_input_tokens: 800_000) |> with_tokens(600_000)
      assert %{input_tokens: f} = BudgetPressure.fractions(s, 0)
      assert_in_delta f, 0.75, 0.001

      assert %{input_tokens: nil} = BudgetPressure.fractions(state([]) |> with_tokens(9_999), 0)
    end

    # Queue time is credited back, so a worker parked behind the GPU is not
    # burning its budget — same rule the deadline itself uses.
    test "wall clock, excluding time spent queued" do
      counter = ExAthena.Agents.Deadline.new_counter()
      assigns = %{agent_deadline_at: 1000, agent_deadline_from: 0, agent_wait_counters: [counter]}
      s = state(ctx: %{assigns: assigns})

      assert %{wall_clock: f} = BudgetPressure.fractions(s, 750)
      assert_in_delta f, 0.75, 0.001

      chain = %{agent_wait_counters: [counter]}
      ExAthena.Agents.Deadline.begin_wait(chain)
      ExAthena.Agents.Deadline.end_wait(chain, 500)

      assert %{wall_clock: f} = BudgetPressure.fractions(s, 750)
      assert_in_delta f, 0.25, 0.001
    end

    test "nil when the run has no deadline (a top-level run)" do
      assert %{wall_clock: nil} = BudgetPressure.fractions(state([]), 0)
    end
  end

  describe "note/2 — what the worker is told" do
    test "silent while every budget is comfortable" do
      assert BudgetPressure.note(state(iterations: 10), 0) == nil
    end

    # The case that mattered: 50 turns left on paper, but the clock is nearly up.
    test "fires on the wall clock even when iterations look fine" do
      counter = ExAthena.Agents.Deadline.new_counter()

      s =
        state(
          iterations: 30,
          ctx: %{
            assigns: %{
              agent_deadline_at: 1000,
              agent_deadline_from: 0,
              agent_wait_counters: [counter]
            }
          }
        )

      assert note = BudgetPressure.note(s, 930)
      assert note =~ "30 turns in"
      assert note =~ "reduce scope"
    end

    test "fires on the token budget too" do
      s = state(iterations: 5, max_input_tokens: 800_000) |> with_tokens(790_000)
      assert BudgetPressure.note(s, 0) =~ "reduce scope"
    end

    test "still fires on iterations alone, as it always did" do
      assert BudgetPressure.note(state(iterations: 45), 0) =~ "reduce scope"
    end

    # The point of the nudge: hand the leftovers back so the orchestrator can
    # re-delegate them as separate, smaller steps.
    test "names the todo progress and asks for the unfinished ones by name" do
      todos = [
        %{"content" => "add the dep", "status" => "completed"},
        %{"content" => "reimplement LlamaCpp", "status" => "in_progress"},
        %{"content" => "rewrite the tests", "status" => "pending"}
      ]

      s = state(iterations: 45, meta: %{todos: todos})
      note = BudgetPressure.note(s, 0)

      assert note =~ "1 of 3"
      assert note =~ "which todos you did NOT complete"
      assert note =~ "re-delegate"
    end

    test "a worker with no todo list still gets the scope-reduction push" do
      note = BudgetPressure.note(state(iterations: 45), 0)
      assert note =~ "reduce scope"
      refute note =~ " of 0 "
    end
  end
end
