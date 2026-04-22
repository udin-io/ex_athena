defmodule ExAthena.Modes.PlanAndSolve do
  @moduledoc """
  Plan-and-Solve mode (PR 3).

  Two-phase operation: a planning turn writes a plan, then executor turns
  follow the plan. Full implementation lands in PR 3. For now this module
  exists so `ExAthena.Loop.Mode.resolve(:plan_and_solve)` returns a valid
  module.

  Falls back to `ExAthena.Modes.ReAct` if invoked.
  """

  @behaviour ExAthena.Loop.Mode

  @impl true
  def init(_state), do: {:error, :plan_and_solve_not_implemented_until_pr3}

  @impl true
  def iterate(_state), do: {:error, :plan_and_solve_not_implemented_until_pr3}
end
