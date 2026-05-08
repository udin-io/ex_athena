defmodule ExAthena.Mcp.SupervisorTest do
  use ExUnit.Case, async: false

  @moduletag :mcp_supervisor

  alias ExAthena.Mcp
  alias ExAthena.Mcp.Supervisor, as: McpSupervisor

  @fake_path Path.expand("../../support/bin/fake_mcp_server.exs", __DIR__)

  defp elixir_exe, do: System.find_executable("elixir") || raise("elixir not on PATH")

  defp one_server_config(name \\ "alpha") do
    %{
      name => %{
        type: :local,
        command: [elixir_exe(), @fake_path],
        enabled: true
      }
    }
  end

  defp two_server_config do
    %{
      "alpha" => %{type: :local, command: [elixir_exe(), @fake_path], enabled: true},
      "beta" => %{type: :local, command: [elixir_exe(), @fake_path], enabled: true}
    }
  end

  defp wait_all_ready(names, attempts \\ 60) do
    if attempts == 0, do: flunk("Servers #{inspect(names)} never all reached :ready")

    statuses =
      Mcp.list_servers()
      |> Enum.filter(fn s -> s.name in names end)
      |> Enum.map(& &1.status)

    if length(statuses) == length(names) and Enum.all?(statuses, &(&1 == :ready)) do
      :ok
    else
      Process.sleep(100)
      wait_all_ready(names, attempts - 1)
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:ex_athena, :mcp_servers)
    end)

    :ok
  end

  describe "start_link/1" do
    test "returns :ignore when no servers configured" do
      Application.put_env(:ex_athena, :mcp_servers, %{})
      assert :ignore = McpSupervisor.start_link([])
    end

    test "returns :ignore when config is nil" do
      Application.delete_env(:ex_athena, :mcp_servers)
      assert :ignore = McpSupervisor.start_link([])
    end

    test "starts with one server configured" do
      Application.put_env(:ex_athena, :mcp_servers, one_server_config())
      assert {:ok, _sup} = start_supervised(McpSupervisor)
    end

    test "disabled servers are not started" do
      config = %{
        "enabled_one" => %{type: :local, command: [elixir_exe(), @fake_path], enabled: true},
        "disabled_one" => %{type: :local, command: [elixir_exe(), @fake_path], enabled: false}
      }

      Application.put_env(:ex_athena, :mcp_servers, config)
      {:ok, _} = start_supervised(McpSupervisor)

      wait_all_ready(["enabled_one"])
      servers = Mcp.list_servers()
      names = Enum.map(servers, & &1.name) |> Enum.sort()
      # disabled server has no process, only enabled one is in registry
      assert "enabled_one" in names
      refute "disabled_one" in names
    end
  end

  describe "list_servers/0" do
    test "returns both servers when two are configured" do
      Application.put_env(:ex_athena, :mcp_servers, two_server_config())
      {:ok, _} = start_supervised(McpSupervisor)
      wait_all_ready(["alpha", "beta"])

      servers = Mcp.list_servers()
      assert length(servers) == 2
      names = Enum.map(servers, & &1.name) |> Enum.sort()
      assert names == ["alpha", "beta"]
    end

    test "each server has expected metadata fields" do
      Application.put_env(:ex_athena, :mcp_servers, one_server_config("my_server"))
      {:ok, _} = start_supervised(McpSupervisor)
      wait_all_ready(["my_server"])

      [server] = Mcp.list_servers()
      assert server.name == "my_server"
      assert server.status == :ready
      assert server.type == :local
      assert server.enabled == true
      assert is_integer(server.tool_count)
      assert server.tool_count > 0
      assert is_nil(server.error)
    end

    test "returns empty list when no servers running" do
      Application.put_env(:ex_athena, :mcp_servers, %{})
      # Supervisor returns :ignore, so no servers started
      assert [] = Mcp.list_servers()
    end
  end

  describe "list_tools/1 by name" do
    test "returns cached tools for a ready server" do
      Application.put_env(:ex_athena, :mcp_servers, one_server_config("tools_server"))
      {:ok, _} = start_supervised(McpSupervisor)
      wait_all_ready(["tools_server"])

      assert {:ok, tools} = Mcp.list_tools("tools_server")
      assert is_list(tools)
      assert length(tools) > 0
      assert hd(tools)["name"] == "echo"
    end

    test "returns {:error, :not_found} for unknown server name" do
      Application.put_env(:ex_athena, :mcp_servers, one_server_config("known"))
      {:ok, _} = start_supervised(McpSupervisor)

      assert {:error, :not_found} = Mcp.list_tools("does_not_exist")
    end
  end

  describe "restart on crash" do
    test "server restarts after its pid is killed and repopulates tools" do
      Application.put_env(:ex_athena, :mcp_servers, one_server_config("restart_test"))
      {:ok, _} = start_supervised(McpSupervisor)
      wait_all_ready(["restart_test"])

      original_pid = ExAthena.Mcp.Registry.whereis("restart_test")
      assert is_pid(original_pid)

      # Kill the server process
      Process.exit(original_pid, :kill)

      # Wait for it to restart and reach :ready under a new pid
      assert eventually(fn ->
               new_pid = ExAthena.Mcp.Registry.whereis("restart_test")

               not is_nil(new_pid) and new_pid != original_pid and
                 match?({:ok, %{status: :ready}}, ExAthena.Mcp.Server.info(new_pid))
             end)

      assert {:ok, tools} = Mcp.list_tools("restart_test")
      assert length(tools) > 0
    end
  end

  defp eventually(fun, attempts \\ 60) do
    if fun.() do
      true
    else
      if attempts == 0 do
        false
      else
        Process.sleep(100)
        eventually(fun, attempts - 1)
      end
    end
  end
end
