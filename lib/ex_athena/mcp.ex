defmodule ExAthena.Mcp do
  @moduledoc """
  Facade for MCP (Model Context Protocol) server management.

  ## Read APIs (high-level — requires Supervisor running)

    * `list_servers/0` — metadata for every running MCP server.
    * `list_tools/1` — cached tools for a server by name.

  ## Low-level APIs (client-pid based)

    * `list_tools/2` — list tools from a running `Client` pid.
    * `call_tool/4` — invoke a named tool on a running `Client` pid.
  """

  alias ExAthena.Mcp.Client
  alias ExAthena.Mcp.Registry, as: McpRegistry
  alias ExAthena.Mcp.Server, as: McpServer
  alias ExAthena.Tool.Spec

  # ── High-level registry-based APIs ───────────────────────────────

  @doc """
  Return metadata for every registered MCP server.

  Each entry is a map with keys `:name`, `:status`, `:type`, `:enabled`,
  `:tool_count`, `:error`.
  """
  @spec list_servers() :: [map()]
  def list_servers do
    McpRegistry.list()
    |> Enum.map(fn {_name, pid} ->
      case McpServer.info(pid) do
        {:ok, info} -> info
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Return cached tools for the server registered under `name`.

  Returns `{:ok, [tool_map]}` or `{:error, :not_found | %ExAthena.Error{}}`.
  """
  @spec list_tools(String.t()) :: {:ok, [map()]} | {:error, :not_found | term()}
  def list_tools(name) when is_binary(name) do
    case McpRegistry.whereis(name) do
      nil -> {:error, :not_found}
      pid -> McpServer.list_tools(pid)
    end
  end

  @doc """
  Return `[Tool.Spec.t()]` for all ready, enabled MCP servers.

  `filter` controls which servers contribute specs:
    * `:all` — all ready+enabled servers
    * `[server_name]` — only the named servers

  When the MCP supervisor is not running, returns `[]` without raising.
  """
  @spec tool_specs(:all | [String.t()]) :: [Spec.t()]
  def tool_specs(filter \\ :all) do
    list_servers()
    |> Enum.filter(fn info ->
      info.status == :ready and info.enabled and server_allowed?(info.name, filter)
    end)
    |> Enum.flat_map(fn info ->
      case list_tools(info.name) do
        {:ok, tools} -> Enum.map(tools, &Spec.from_mcp(&1, info.name))
        _ -> []
      end
    end)
  end

  defp server_allowed?(_name, :all), do: true
  defp server_allowed?(name, list) when is_list(list), do: name in list

  # ── Low-level client-pid APIs ─────────────────────────────────────

  @doc """
  List tools from a running `Client` process directly.

  Lower-level than `list_tools/1` — callers that hold a pid use this.
  """
  @spec list_tools(pid(), non_neg_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(client, timeout) when is_pid(client) and is_integer(timeout) do
    Client.list_tools(client, timeout)
  end

  @doc """
  Call a named tool on a `Client` process directly.
  """
  @spec call_tool(pid(), String.t(), map(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def call_tool(client, name, input, timeout \\ 30_000) when is_pid(client) do
    Client.call_tool(client, name, input, timeout)
  end
end
