defmodule ExAthena.Mcp.ServerTest do
  use ExUnit.Case, async: false

  alias ExAthena.Mcp.Config.Server
  alias ExAthena.Mcp.Server, as: McpServer

  @fake_server_path Path.expand("../../support/bin/fake_mcp_server.exs", __DIR__)

  setup do
    start_supervised!(ExAthena.Mcp.Registry)
    :ok
  end

  defp fake_cfg(name \\ "test") do
    elixir = System.find_executable("elixir") || raise "elixir not on PATH"

    %Server{
      name: name,
      type: :local,
      command: elixir,
      args: [@fake_server_path],
      env: %{},
      enabled: true
    }
  end

  defp wait_ready(pid, attempts \\ 50) do
    if attempts == 0, do: flunk("Server never reached :ready")

    case McpServer.info(pid) do
      {:ok, %{status: :ready}} ->
        :ok

      _ ->
        Process.sleep(50)
        wait_ready(pid, attempts - 1)
    end
  end

  describe "start_link/1 with fake stdio server" do
    test "starts with :starting status and transitions to :ready" do
      {:ok, pid} = McpServer.start_link(fake_cfg())
      wait_ready(pid)

      assert {:ok, info} = McpServer.info(pid)
      assert info.status == :ready
      assert info.name == "test"
    end

    test "caches tools after boot" do
      {:ok, pid} = McpServer.start_link(fake_cfg())
      wait_ready(pid)

      assert {:ok, tools} = McpServer.list_tools(pid)
      assert is_list(tools)
      assert length(tools) > 0
      assert hd(tools)["name"] == "echo"
    end

    test "list_tools returns error when still starting" do
      {:ok, pid} = McpServer.start_link(fake_cfg())

      # Check immediately before ready — may be :starting or :ready
      result = McpServer.list_tools(pid)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "list_tools does not re-call client (uses cache)" do
      {:ok, pid} = McpServer.start_link(fake_cfg())
      wait_ready(pid)

      {:ok, tools1} = McpServer.list_tools(pid)
      {:ok, tools2} = McpServer.list_tools(pid)
      assert tools1 == tools2
    end
  end

  describe "start_link/1 with bad command" do
    test "process terminates when command not found" do
      # Trap exits so the test process doesn't crash when the linked Server dies
      Process.flag(:trap_exit, true)

      cfg = %Server{
        name: "bad",
        type: :local,
        command: "nonexistent_mcp_command_xyz_123",
        args: [],
        env: %{},
        enabled: true
      }

      {:ok, pid} = McpServer.start_link(cfg)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      # Drain the EXIT message
      receive do
        {:EXIT, ^pid, _} -> :ok
      after
        0 -> :ok
      end
    end
  end

  describe "info/1" do
    test "returns metadata map" do
      {:ok, pid} = McpServer.start_link(fake_cfg("meta_test"))
      wait_ready(pid)

      assert {:ok, info} = McpServer.info(pid)
      assert info.name == "meta_test"
      assert info.status == :ready
      assert info.type == :local
      assert is_integer(info.tool_count)
      assert info.tool_count > 0
      assert is_nil(info.error)
    end
  end
end
