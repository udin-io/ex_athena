defmodule ExAthena.BudgetTest do
  use ExUnit.Case, async: true

  alias ExAthena.Budget

  test "new/0 starts at zero usage and captures monotonic timestamp" do
    b = Budget.new()
    assert b.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
    assert b.cost_usd == nil
    assert is_integer(b.started_at)
  end

  test "add/3 accumulates usage and cost" do
    b =
      Budget.new()
      |> Budget.add(%{input_tokens: 10, output_tokens: 5, total_tokens: 15}, 0.001)
      |> Budget.add(%{input_tokens: 7, output_tokens: 3, total_tokens: 10}, 0.0005)

    assert b.usage == %{input_tokens: 17, output_tokens: 8, total_tokens: 25}
    assert_in_delta b.cost_usd, 0.0015, 1.0e-9
  end

  test "add/3 tolerates missing keys" do
    b =
      Budget.new()
      |> Budget.add(%{input_tokens: 10}, nil)

    assert b.usage.input_tokens == 10
    assert b.usage.output_tokens == 0
    assert b.cost_usd == nil
  end

  test "add/3 accepts string-keyed usage maps" do
    b =
      Budget.new()
      |> Budget.add(%{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}, nil)

    assert b.usage == %{input_tokens: 4, output_tokens: 2, total_tokens: 6}
  end

  test "add/3 preserves and accumulates reasoning_tokens when the provider reports them" do
    b =
      Budget.new()
      |> Budget.add(%{input_tokens: 10, output_tokens: 100, reasoning_tokens: 90}, nil)
      |> Budget.add(%{input_tokens: 7, output_tokens: 50, reasoning_tokens: 40}, nil)

    assert b.usage.reasoning_tokens == 130
    assert b.usage.output_tokens == 150
  end

  test "add/3 accepts string-keyed reasoning_tokens" do
    b = Budget.new() |> Budget.add(%{"reasoning_tokens" => 25}, nil)
    assert b.usage.reasoning_tokens == 25
  end

  test "add/3 keeps accumulated reasoning_tokens when a later turn omits them" do
    b =
      Budget.new()
      |> Budget.add(%{output_tokens: 10, reasoning_tokens: 5}, nil)
      |> Budget.add(%{output_tokens: 3}, nil)

    assert b.usage.reasoning_tokens == 5
  end

  test "usage has no reasoning_tokens key when no provider ever reported them" do
    b = Budget.new() |> Budget.add(%{input_tokens: 1, output_tokens: 2, total_tokens: 3}, nil)
    refute Map.has_key?(b.usage, :reasoning_tokens)
  end

  test "exceeded?/2 returns false when cap is nil or cost not set" do
    b = Budget.new()
    refute Budget.exceeded?(b, nil)
    refute Budget.exceeded?(b, 0.01)
  end

  test "exceeded?/2 returns true once cost meets or exceeds cap" do
    b = Budget.new() |> Budget.add(%{}, 0.02)
    assert Budget.exceeded?(b, 0.02)
    assert Budget.exceeded?(b, 0.01)
    refute Budget.exceeded?(b, 0.03)
  end

  test "duration_ms/1 returns elapsed milliseconds since new/0" do
    b = Budget.new()
    Process.sleep(10)
    assert Budget.duration_ms(b) >= 10
  end
end
