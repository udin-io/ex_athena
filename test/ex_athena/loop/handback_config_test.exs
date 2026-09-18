defmodule ExAthena.Loop.HandbackConfigTest do
  @moduledoc """
  The handback stage reserves the end of a worker's clock for its report, so
  where it fires is a per-model judgement: a model that spends four minutes on
  a turn needs the stage earlier than one that spends thirty seconds. It
  resolves through `ExAthena.Tuning`, which is what puts it in the gear modal.

  Serial, because it writes the `:loop` application env.
  """
  use ExUnit.Case, async: false

  alias ExAthena.Agents.Deadline
  alias ExAthena.Loop.BudgetPressure

  setup do
    on_exit(fn -> Application.delete_env(:ex_athena, :loop) end)
    :ok
  end

  defp at(spent) do
    counter = Deadline.new_counter()

    state = %{
      iterations: 5,
      max_iterations: 50,
      max_input_tokens: 0,
      budget: ExAthena.Budget.new(),
      meta: %{},
      ctx: %{
        assigns: %{
          agent_deadline_at: 1000,
          agent_deadline_from: 0,
          agent_wait_counters: [counter]
        }
      }
    }

    {state, spent}
  end

  test "the default reserves the last sixth of the budget for the report" do
    {s, now} = at(700)
    refute BudgetPressure.handback?(s, now)

    {s, now} = at(850)
    assert BudgetPressure.handback?(s, now)
  end

  test "config moves the stage" do
    {s, now} = at(700)
    refute BudgetPressure.handback?(s, now)

    Application.put_env(:ex_athena, :loop, handback_at_percent: 60)
    assert BudgetPressure.handback?(s, now)
  end

  test "a stage set past the deadline never fires" do
    Application.put_env(:ex_athena, :loop, handback_at_percent: 101)

    {s, now} = at(999)
    refute BudgetPressure.handback?(s, now)
  end
end
