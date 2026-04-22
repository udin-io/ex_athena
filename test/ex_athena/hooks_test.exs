defmodule ExAthena.HooksTest do
  use ExUnit.Case, async: true

  alias ExAthena.Hooks

  test "PreToolUse matcher fires on matching tools only" do
    parent = self()
    fn_fires = fn _input, _id -> send(parent, :fired) end

    hooks = %{PreToolUse: [%{matcher: "write|edit", hooks: [fn_fires]}]}

    assert :ok = Hooks.run_pre_tool_use(hooks, "write", %{}, "c1")
    assert_receive :fired

    refute_receive _any, 10
    assert :ok = Hooks.run_pre_tool_use(hooks, "read", %{}, "c2")
    refute_receive _any, 10
  end

  test "PreToolUse deny short-circuits" do
    fn_deny = fn _input, _id -> {:deny, permission_decision_reason: "no"} end
    fn_fires = fn _input, _id -> flunk("should not fire after deny") end

    hooks = %{PreToolUse: [%{matcher: nil, hooks: [fn_deny, fn_fires]}]}

    assert {:deny, _} = Hooks.run_pre_tool_use(hooks, "write", %{}, "c1")
  end

  test "PostToolUse halt is honoured, deny is not" do
    fn_deny = fn _input, _id -> {:deny, permission_decision_reason: "ignored"} end
    fn_halt = fn _input, _id -> {:halt, :budget_exceeded} end

    assert :ok = Hooks.run_post_tool_use(%{PostToolUse: [%{hooks: [fn_deny]}]}, "bash", %{}, "c1")

    assert {:halt, :budget_exceeded} =
             Hooks.run_post_tool_use(%{PostToolUse: [%{hooks: [fn_halt]}]}, "bash", %{}, "c1")
  end

  test "lifecycle hooks (Stop, SessionStart) fire without matchers" do
    parent = self()
    stop_hook = fn _payload, _id -> send(parent, :stopped) end

    Hooks.run_lifecycle(%{Stop: [stop_hook]}, :Stop, %{reason: :normal})
    assert_receive :stopped
  end

  test "hook crashes are caught and become halts" do
    crasher = fn _input, _id -> raise "boom" end

    assert {:halt, {:hook_crashed, _msg}} =
             Hooks.run_pre_tool_use(%{PreToolUse: [%{hooks: [crasher]}]}, "read", %{}, "c1")
  end
end
