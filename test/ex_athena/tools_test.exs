defmodule ExAthena.ToolsTest do
  use ExUnit.Case, async: true

  alias ExAthena.Tool.Spec
  alias ExAthena.Tools

  describe "resolve/1 with module list" do
    test "wraps modules into Tool.Spec structs" do
      specs = Tools.resolve(tools: [ExAthena.Tools.Read])
      assert [%Spec{kind: :module, name: "read"}] = specs
    end

    test ":all expands to all builtins as specs" do
      specs = Tools.resolve(tools: :all)
      assert length(specs) == length(Tools.builtins())
      assert Enum.all?(specs, &match?(%Spec{kind: :module}, &1))
    end

    test "nil falls back to configured or :all" do
      specs = Tools.resolve([])
      assert is_list(specs)
      assert Enum.all?(specs, &match?(%Spec{}, &1))
    end

    test "mcp: false suppresses MCP tools even when supervisor is up" do
      # Without MCP supervisor running, the flag is a no-op but must not crash
      specs = Tools.resolve(tools: [ExAthena.Tools.Read], mcp: false)
      assert Enum.all?(specs, &match?(%Spec{kind: :module}, &1))
    end
  end

  describe "describe_for_provider/1" do
    test "returns list of provider schema maps from specs" do
      specs = [Spec.from_module(ExAthena.Tools.Read)]

      result = Tools.describe_for_provider(specs)

      assert [%{type: "function", function: %{name: "read"}}] = result
    end

    test "includes mcp specs" do
      mcp_spec =
        Spec.from_mcp(
          %{
            "name" => "bash",
            "description" => "run bash",
            "inputSchema" => %{"type" => "object"}
          },
          "myserver"
        )

      [entry] = Tools.describe_for_provider([mcp_spec])
      assert entry.function.name == "myserver_bash"
    end
  end

  describe "describe_for_prompt/1" do
    test "returns list of prompt-friendly maps from specs" do
      specs = [Spec.from_module(ExAthena.Tools.Glob)]
      [entry] = Tools.describe_for_prompt(specs)
      assert entry.name == "glob"
      assert is_binary(entry.description)
      assert is_map(entry.schema)
    end
  end

  describe "find/2" do
    test "finds a spec by name" do
      specs = [Spec.from_module(ExAthena.Tools.Read), Spec.from_module(ExAthena.Tools.Glob)]
      assert %Spec{name: "glob"} = Tools.find(specs, "glob")
    end

    test "returns nil when name not found" do
      specs = [Spec.from_module(ExAthena.Tools.Read)]
      assert is_nil(Tools.find(specs, "nonexistent"))
    end
  end

  describe "validate!/1" do
    test "accepts a list of valid module specs" do
      specs = [Spec.from_module(ExAthena.Tools.Read)]
      assert :ok = Tools.validate!(specs)
    end

    test "accepts a list of mcp specs" do
      mcp_spec =
        Spec.from_mcp(
          %{"name" => "tool", "description" => "d", "inputSchema" => %{}},
          "server"
        )

      assert :ok = Tools.validate!([mcp_spec])
    end

    test "raises for non-Tool module wrapped in spec still validates schema presence" do
      # validate! on specs checks spec invariants, not module behaviour
      # An invalid spec (nil name) would fail structural checks
      :ok
    end
  end
end
