defmodule ExAthena.Mcp.LoopIntegrationTest do
  use ExUnit.Case, async: false

  alias ExAthena.{Loop, Mcp, Response, Tools}
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Mcp.Supervisor, as: McpSupervisor
  alias ExAthena.Tool.Spec

  @fake_path Path.expand("../../support/bin/fake_mcp_server.exs", __DIR__)

  defp elixir_exe, do: System.find_executable("elixir") || raise("elixir not on PATH")

  defp fake_server_config do
    %{"fake" => %{type: :local, command: [elixir_exe(), @fake_path], enabled: true}}
  end

  defp wait_all_ready(names, attempts \\ 60) do
    if attempts == 0, do: flunk("Servers #{inspect(names)} never reached :ready")

    statuses =
      Mcp.list_servers() |> Enum.filter(fn s -> s.name in names end) |> Enum.map(& &1.status)

    if length(statuses) == length(names) and Enum.all?(statuses, &(&1 == :ready)) do
      :ok
    else
      Process.sleep(100)
      wait_all_ready(names, attempts - 1)
    end
  end

  defp script(responses) do
    counter = :counters.new(1, [:atomics])

    fn _request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      Enum.at(responses, n - 1) || List.last(responses)
    end
  end

  setup do
    Application.put_env(:ex_athena, :mcp_servers, fake_server_config())
    {:ok, _sup} = start_supervised(McpSupervisor)
    wait_all_ready(["fake"])
    on_exit(fn -> Application.delete_env(:ex_athena, :mcp_servers) end)
    dir = Path.join(System.tmp_dir!(), "mcp_loop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "catalog registration" do
    test "fake_echo appears in Tools.resolve/1 alongside built-ins" do
      specs = Tools.resolve(tools: [ExAthena.Tools.Read])
      names = Enum.map(specs, & &1.name)
      assert "read" in names
      assert "fake_echo" in names
    end

    test "fake_echo spec has :mcp kind and correct fields" do
      specs = Tools.resolve(tools: [])
      echo = Enum.find(specs, &(&1.name == "fake_echo"))
      assert %Spec{kind: :mcp, mcp_server: "fake", mcp_tool_name: "echo"} = echo
    end

    test "fake_echo appears in describe_for_provider/1 output" do
      specs = Tools.resolve(tools: [])
      names = Tools.describe_for_provider(specs) |> Enum.map(fn t -> t.function.name end)
      assert "fake_echo" in names
    end

    test "mcp: false excludes MCP tools" do
      specs = Tools.resolve(tools: [ExAthena.Tools.Read], mcp: false)
      names = Enum.map(specs, & &1.name)
      assert "read" in names
      refute "fake_echo" in names
    end

    test "mcp: [server_name] includes only tools from listed servers" do
      specs = Tools.resolve(tools: [], mcp: ["fake"])
      assert Enum.any?(specs, &(&1.name == "fake_echo"))
      excluded = Tools.resolve(tools: [], mcp: ["other"])
      refute Enum.any?(excluded, &(&1.name == "fake_echo"))
    end
  end

  describe "happy path" do
    test "loop executes MCP tool and result appears in messages", %{dir: dir} do
      responses = [
        %Response{
          text: "",
          tool_calls: [
            %ToolCall{id: "c1", name: "fake_echo", arguments: %{"message" => "hello_mcp"}}
          ],
          finish_reason: :tool_calls,
          provider: :mock
        },
        %Response{
          text: "MCP tool succeeded",
          tool_calls: [],
          finish_reason: :stop,
          provider: :mock
        }
      ]

      assert {:ok, result} =
               Loop.run("use mcp tool",
                 provider: :mock,
                 mock: [responder: script(responses)],
                 cwd: dir,
                 tools: [],
                 memory: false,
                 skills: false
               )

      assert result.text == "MCP tool succeeded"
      tool_msg = Enum.find(result.messages, &match?(%{role: :tool}, &1))
      assert tool_msg != nil
      # is_error is nil for success (Messages.tool_result default)
      assert [%{is_error: nil, content: content}] = tool_msg.tool_results
      assert content =~ "hello_mcp"
    end
  end

  describe "permission deny" do
    test "disallowed MCP tool gets is_error: true and fires PermissionDenied hook", %{dir: dir} do
      responses = [
        %Response{
          text: "",
          tool_calls: [%ToolCall{id: "c1", name: "fake_echo", arguments: %{"message" => "x"}}],
          finish_reason: :tool_calls,
          provider: :mock
        },
        %Response{text: "denied", tool_calls: [], finish_reason: :stop, provider: :mock}
      ]

      test_pid = self()
      # Hooks are called as fun.(input_map, tool_use_id) — arity 2
      hooks = %{
        PermissionDenied: [
          fn payload, _id -> send(test_pid, {:permission_denied, payload.tool_name}) end
        ]
      }

      assert {:ok, result} =
               Loop.run("go",
                 provider: :mock,
                 mock: [responder: script(responses)],
                 cwd: dir,
                 tools: [],
                 disallowed_tools: ["fake_echo"],
                 hooks: hooks,
                 memory: false,
                 skills: false
               )

      tool_msg = Enum.find(result.messages, &match?(%{role: :tool}, &1))
      assert [%{is_error: true, content: content}] = tool_msg.tool_results
      assert content =~ "disallowed"
      assert_receive {:permission_denied, "fake_echo"}
    end
  end

  describe "hook firing" do
    test "PreToolUse and PostToolUse fire with namespaced name", %{dir: dir} do
      responses = [
        %Response{
          text: "",
          tool_calls: [%ToolCall{id: "c1", name: "fake_echo", arguments: %{"message" => "hi"}}],
          finish_reason: :tool_calls,
          provider: :mock
        },
        %Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
      ]

      test_pid = self()
      # Hooks are called as fun.(input_map, tool_use_id) — arity 2
      # PreToolUse input_map contains :tool_name key
      # PostToolUse input_map contains :tool_name key
      hooks = %{
        PreToolUse: [fn input, _id -> send(test_pid, {:pre_tool_use, input.tool_name}) end],
        PostToolUse: [fn input, _id -> send(test_pid, {:post_tool_use, input.tool_name}) end]
      }

      assert {:ok, _result} =
               Loop.run("go",
                 provider: :mock,
                 mock: [responder: script(responses)],
                 cwd: dir,
                 tools: [],
                 hooks: hooks,
                 memory: false,
                 skills: false
               )

      assert_receive {:pre_tool_use, "fake_echo"}
      assert_receive {:post_tool_use, "fake_echo"}
    end
  end

  describe "server not running" do
    test "tool result is error when server has stopped", %{dir: dir} do
      stop_supervised!(McpSupervisor)
      Process.sleep(100)

      ghost_spec =
        Spec.from_mcp(%{"name" => "echo", "description" => "d", "inputSchema" => %{}}, "fake")

      responses = [
        %Response{
          text: "",
          tool_calls: [%ToolCall{id: "c1", name: "fake_echo", arguments: %{"message" => "x"}}],
          finish_reason: :tool_calls,
          provider: :mock
        },
        %Response{text: "handled", tool_calls: [], finish_reason: :stop, provider: :mock}
      ]

      assert {:ok, result} =
               Loop.run("go",
                 provider: :mock,
                 mock: [responder: script(responses)],
                 cwd: dir,
                 tools: [ghost_spec],
                 mcp: false,
                 memory: false,
                 skills: false
               )

      tool_msg = Enum.find(result.messages, &match?(%{role: :tool}, &1))
      assert [%{is_error: true}] = tool_msg.tool_results
    end
  end
end
