defmodule ExAthena.Loop.BudgetCapTest do
  @moduledoc """
  Verifies `:max_budget_usd` trips `:error_max_budget_usd` with full
  accounting, and that cost flows from provider metadata into the Result.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}

  setup do
    dir = Path.join(System.tmp_dir!(), "budget_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "trips :error_max_budget_usd when cumulative cost exceeds cap", %{dir: dir} do
    # Each iteration reports $0.01 cost. With cap $0.015, after 2 iterations
    # cumulative = $0.02 > cap → run terminates at the iteration boundary.
    expensive_response = %Response{
      text: "",
      tool_calls: [
        %ExAthena.Messages.ToolCall{id: "c", name: "glob", arguments: %{"pattern" => "*"}}
      ],
      finish_reason: :tool_calls,
      provider: :mock,
      usage: %{input_tokens: 100, output_tokens: 50, total_tokens: 150, total_cost: 0.01}
    }

    assert {:ok, %Result{finish_reason: :error_max_budget_usd} = r} =
             Loop.run("spin",
               provider: :mock,
               mock: [responder: fn _ -> expensive_response end],
               cwd: dir,
               tools: [ExAthena.Tools.Glob],
               max_iterations: 10,
               max_budget_usd: 0.015
             )

    assert Result.category(r) == :capacity
    assert is_number(r.cost_usd) and r.cost_usd >= 0.015
  end

  test "accumulates cost in the Result when provider reports total_cost", %{dir: dir} do
    response = %Response{
      text: "done",
      tool_calls: [],
      finish_reason: :stop,
      provider: :mock,
      usage: %{input_tokens: 100, output_tokens: 50, total_tokens: 150, total_cost: 0.05}
    }

    assert {:ok, %Result{cost_usd: cost, usage: usage}} =
             Loop.run("hi",
               provider: :mock,
               mock: [responder: fn _ -> response end],
               cwd: dir,
               tools: []
             )

    assert_in_delta cost, 0.05, 1.0e-9
    assert usage.input_tokens == 100
    assert usage.output_tokens == 50
  end

  test "cost_usd stays nil when provider doesn't report it", %{dir: dir} do
    response = %Response{
      text: "done",
      tool_calls: [],
      finish_reason: :stop,
      provider: :mock,
      usage: %{input_tokens: 100, output_tokens: 50, total_tokens: 150}
    }

    assert {:ok, %Result{cost_usd: nil, usage: %{input_tokens: 100}}} =
             Loop.run("hi",
               provider: :mock,
               mock: [responder: fn _ -> response end],
               cwd: dir,
               tools: []
             )
  end
end
