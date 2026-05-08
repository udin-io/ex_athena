defmodule ExAthena.Mcp.Supervisor do
  @moduledoc """
  Supervises one `ExAthena.Mcp.Server` per enabled MCP server config entry,
  plus the `ExAthena.Mcp.Registry`.

  Started by `ExAthena.Application` when `config :ex_athena, enable_mcp: true`
  (the default). Returns `:ignore` when no servers are configured.

  Each `Server` child uses `:transient` restart with `max_restarts: 3` per
  60-second window, so persistent failures surface via `list_servers/0`
  without crash-looping the supervisor.
  """

  use Supervisor

  alias ExAthena.Mcp.Config
  alias ExAthena.Mcp.Registry, as: McpRegistry
  alias ExAthena.Mcp.Server, as: McpServer

  @doc "Start the supervisor. Returns `:ignore` when no servers are configured."
  def start_link(opts \\ []) do
    case Config.load() do
      {:ok, []} ->
        :ignore

      {:ok, servers} ->
        Supervisor.start_link(__MODULE__, servers, Keyword.put_new(opts, :name, __MODULE__))

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl Supervisor
  def init(servers) do
    enabled = Enum.filter(servers, & &1.enabled)

    server_specs =
      Enum.map(enabled, fn cfg ->
        %{
          id: {McpServer, cfg.name},
          start: {McpServer, :start_link, [cfg]},
          restart: :transient
        }
      end)

    children = [McpRegistry | server_specs]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
  end
end
