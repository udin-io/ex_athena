defmodule ExAthena.ResultTest do
  use ExUnit.Case, async: true

  alias ExAthena.Result

  test "success?/1 reflects the finish_reason subtype" do
    assert Result.success?(%Result{finish_reason: :stop})
    refute Result.success?(%Result{finish_reason: :error_max_turns})
  end

  test "error?/1 is the inverse of success?" do
    refute Result.error?(%Result{finish_reason: :stop})
    assert Result.error?(%Result{finish_reason: :error_halted})
    assert Result.error?(%Result{finish_reason: :error_during_execution})
  end

  test "category/1 delegates to Terminations" do
    assert Result.category(%Result{finish_reason: :stop}) == :success
    assert Result.category(%Result{finish_reason: :error_max_turns}) == :capacity
    assert Result.category(%Result{finish_reason: :error_during_execution}) == :retryable
    assert Result.category(%Result{finish_reason: :error_halted}) == :fatal
  end

  test "default struct has sane zero values" do
    assert %Result{
             text: nil,
             messages: [],
             finish_reason: :stop,
             iterations: 0,
             tool_calls_made: 0,
             usage: nil,
             cost_usd: nil
           } = %Result{}
  end
end
