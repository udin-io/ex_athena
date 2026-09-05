defmodule ExAthena.BudgetInputCapTest do
  @moduledoc """
  A worker's only spend rail was wall clock, and 30 minutes fits a great deal
  of context. Live, one implementer burned 1,992,051 input tokens over 38
  iterations and completed none of its eight sub-steps; its replacement burned
  another 920,357 and hit the same wall. Across 41 workers that DID finish,
  the most any of them ever used was 701,896.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Budget

  defp budget(input) do
    Budget.add(Budget.new(), %{input_tokens: input, output_tokens: 0}, nil)
  end

  describe "input_exceeded?/2" do
    test "nil cap never trips — a run without one is unbounded, as before" do
      refute Budget.input_exceeded?(budget(5_000_000), nil)
    end

    test "trips once cumulative input passes the cap" do
      refute Budget.input_exceeded?(budget(799_999), 800_000)
      assert Budget.input_exceeded?(budget(800_000), 800_000)
      assert Budget.input_exceeded?(budget(1_992_051), 800_000)
    end

    # 0 is how the settings modal spells "off" — every field there is an
    # integer, so the top-level default is 0 rather than nil.
    test "zero disables the cap" do
      refute Budget.input_exceeded?(budget(5_000_000), 0)
    end

    test "a fresh budget is under any cap" do
      refute Budget.input_exceeded?(Budget.new(), 1)
    end

    # The cap is on INPUT, not total: input is what grows with the context and
    # what ran away (1.99M in against 20.8k out on the worker above).
    test "output tokens do not count toward it" do
      b = Budget.add(Budget.new(), %{input_tokens: 10, output_tokens: 5_000_000}, nil)
      refute Budget.input_exceeded?(b, 1_000)
    end
  end
end
