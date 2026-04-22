defmodule ExAthena.PermissionsTest do
  use ExUnit.Case, async: true

  alias ExAthena.Messages.ToolCall
  alias ExAthena.{Permissions, ToolContext}

  defp ctx(phase \\ :default) do
    ToolContext.new(cwd: "/tmp", phase: phase)
  end

  defp call(name, args \\ %{}) do
    %ToolCall{id: "c1", name: name, arguments: args}
  end

  test "disallowed_tools wins over everything" do
    assert {:deny, {:disallowed, "bash"}} =
             Permissions.check(call("bash"), ctx(:bypass_permissions),
               disallowed_tools: ["bash"]
             )
  end

  test "allowed_tools when set denies anything not in it" do
    assert {:deny, {:not_in_allowlist, "bash"}} =
             Permissions.check(call("bash"), ctx(), allowed_tools: ["read"])

    assert :allow = Permissions.check(call("read"), ctx(), allowed_tools: ["read"])
  end

  test "plan phase blocks mutation tools" do
    assert {:deny, {:mutation_in_plan_mode, "write"}} =
             Permissions.check(call("write"), ctx(:plan), %{})

    assert {:deny, {:mutation_in_plan_mode, "edit"}} =
             Permissions.check(call("edit"), ctx(:plan), %{})

    assert :allow = Permissions.check(call("read"), ctx(:plan), %{})
    assert :allow = Permissions.check(call("glob"), ctx(:plan), %{})
  end

  test "bypass_permissions allows everything" do
    assert :allow = Permissions.check(call("bash"), ctx(:bypass_permissions), %{})
    assert :allow = Permissions.check(call("write"), ctx(:bypass_permissions), %{})
  end

  test "can_use_tool callback can deny with reason" do
    deny = fn _name, _args, _ctx -> {:deny, :user_declined} end

    assert {:deny, :user_declined} =
             Permissions.check(call("bash"), ctx(), %{can_use_tool: deny})
  end

  test "can_use_tool callback can allow" do
    allow = fn _name, _args, _ctx -> :allow end

    assert :allow = Permissions.check(call("bash"), ctx(), %{can_use_tool: allow})
  end
end
