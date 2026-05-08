defmodule ExAthena.Mcp.Server do
  @moduledoc """
  Per-MCP-server GenServer. Owns one `Client` and the cached tool catalog.

  Lifecycle:
    1. `init/1` registers in the Registry and sends itself `:boot`.
    2. `handle_info(:boot, ...)` starts the `Client`, runs `tools/list`, caches tools.
    3. Status transitions: `:starting` → `:ready` (success) or `:degraded` (failure).

  Linked to its `Client`: if the Client crashes, this process also crashes so the
  Supervisor can restart both.
  """

  use GenServer
  require Logger

  alias ExAthena.Mcp.Client
  alias ExAthena.Mcp.Config
  alias ExAthena.Mcp.Registry, as: McpRegistry

  defstruct [:name, :cfg, :client, :status, :tools, :error, :started_at]

  # ── Public API ────────────────────────────────────────────────────

  @doc "Start and link a server process registered under `cfg.name`."
  @spec start_link(Config.Server.t()) :: GenServer.on_start()
  def start_link(%Config.Server{} = cfg) do
    GenServer.start_link(__MODULE__, cfg, name: McpRegistry.via(cfg.name))
  end

  @doc "Return cached tools. `{:ok, [tool_map]}` when ready, `{:error, reason}` otherwise."
  @spec list_tools(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(server) do
    GenServer.call(server, :list_tools)
  end

  @doc "Return metadata map for `list_servers/0`."
  @spec info(GenServer.server()) :: {:ok, map()}
  def info(server) do
    GenServer.call(server, :info)
  end

  @doc "Forward a tool call to the underlying client. Returns `{:ok, result_map}` or `{:error, reason}`."
  @spec call_tool(GenServer.server(), String.t(), map(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def call_tool(server, tool_name, args, timeout \\ 30_000) do
    case GenServer.call(server, :get_client) do
      {:ok, client_pid} ->
        Client.call_tool(client_pid, tool_name, args, timeout)

      {:error, _} = err ->
        err
    end
  end

  @doc "Return `{:ok, client_pid}` when ready, `{:error, reason}` otherwise."
  @spec get_client(GenServer.server()) :: {:ok, pid()} | {:error, term()}
  def get_client(server) do
    GenServer.call(server, :get_client)
  end

  # ── GenServer callbacks ───────────────────────────────────────────

  @impl GenServer
  def init(%Config.Server{} = cfg) do
    state = %__MODULE__{
      name: cfg.name,
      cfg: cfg,
      client: nil,
      status: :starting,
      tools: [],
      error: nil,
      started_at: System.system_time(:second)
    }

    send(self(), :boot)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:boot, state) do
    client_opts = Config.to_client_opts(state.cfg) ++ [auto_initialize?: true]

    case Client.start_link(client_opts) do
      {:ok, client_pid} ->
        case Client.list_tools(client_pid) do
          {:ok, tools} ->
            {:noreply, %{state | client: client_pid, status: :ready, tools: tools}}

          {:error, error} ->
            Logger.warning("MCP server '#{state.name}' tools/list failed: #{inspect(error)}")
            {:noreply, %{state | client: client_pid, status: :degraded, error: error}}
        end

      {:error, reason} ->
        Logger.warning("MCP server '#{state.name}' client start failed: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, %{state | status: :degraded, error: reason}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:list_tools, _from, %{status: :ready} = state) do
    {:reply, {:ok, state.tools}, state}
  end

  def handle_call(:list_tools, _from, state) do
    error =
      state.error ||
        ExAthena.Error.new(:server_error, "Server '#{state.name}' is #{state.status}")

    {:reply, {:error, error}, state}
  end

  def handle_call(:get_client, _from, %{status: :ready, client: client} = state)
      when is_pid(client) do
    {:reply, {:ok, client}, state}
  end

  def handle_call(:get_client, _from, state) do
    error =
      state.error ||
        ExAthena.Error.new(:server_error, "Server '#{state.name}' is #{state.status}")

    {:reply, {:error, error}, state}
  end

  def handle_call(:info, _from, state) do
    info = %{
      name: state.name,
      status: state.status,
      type: state.cfg.type,
      enabled: state.cfg.enabled,
      tool_count: length(state.tools),
      error: state.error
    }

    {:reply, {:ok, info}, state}
  end
end
