defmodule ExAthena.Mcp.Client do
  @moduledoc """
  JSON-RPC 2.0 MCP client GenServer.

  Manages a single MCP server connection over either:
  - `:stdio` transport — spawns a child process and communicates via stdin/stdout
  - `:http` transport — POSTs JSON-RPC messages to an HTTP endpoint

  ## Options

    * `:command` — executable name (required for stdio)
    * `:args` — argument list (default `[]`, stdio only)
    * `:env` — environment map (default `%{}`, stdio only)
    * `:url` — HTTP endpoint URL (required for HTTP)
    * `:headers` — HTTP headers map (default `%{}`, HTTP only)
    * `:request_timeout_ms` — per-request timeout in ms (default 30_000)
    * `:auto_initialize?` — run initialize handshake in `init/1` (default `true`)
  """

  use GenServer
  require Logger

  alias ExAthena.Error
  alias ExAthena.Mcp.Protocol

  @default_timeout 30_000

  # ── Public API ────────────────────────────────────────────────────

  @doc "Start the client. Links the calling process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "List tools exposed by the MCP server. Returns `{:ok, [tool_map]}` or `{:error, reason}`."
  @spec list_tools(GenServer.server(), non_neg_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(client, timeout \\ @default_timeout) do
    case GenServer.call(client, {:list_tools, timeout}, timeout + 1_000) do
      {:ok, %{"tools" => tools}} when is_list(tools) -> {:ok, tools}
      {:ok, result} -> {:ok, Map.get(result, "tools", [])}
      {:error, _} = err -> err
    end
  end

  @doc "Call a tool by name with `input` map. Returns `{:ok, result_map}` or `{:error, reason}`."
  @spec call_tool(GenServer.server(), String.t(), map(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def call_tool(client, name, input, timeout \\ @default_timeout) do
    GenServer.call(client, {:call_tool, name, input, timeout}, timeout + 1_000)
  end

  @doc "Run the initialize handshake. Only needed when `auto_initialize?: false`."
  @spec initialize(GenServer.server(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def initialize(client, timeout \\ @default_timeout) do
    GenServer.call(client, {:initialize, timeout}, timeout + 1_000)
  end

  # ── GenServer callbacks ───────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    transport_mod = transport_module(opts)
    timeout = Keyword.get(opts, :request_timeout_ms, @default_timeout)

    case transport_mod.start_link(opts, self()) do
      {:ok, transport} ->
        Process.link(transport)
        state = new_state(transport, transport_mod, timeout)

        if Keyword.get(opts, :auto_initialize?, true) do
          do_initialize_sync(state)
        else
          {:ok, state}
        end

      {:error, reason} ->
        {:stop,
         {:shutdown, Error.new(:transport, "Failed to start transport: #{inspect(reason)}")}}
    end
  end

  @impl GenServer
  def handle_call({:list_tools, timeout}, from, state) do
    id = state.next_id
    request = Protocol.encode_request("tools/list", %{}, id)
    state.transport_mod.send_message(state.transport, request)
    timer = Process.send_after(self(), {:request_timeout, id}, timeout)
    {:noreply, put_pending(state, id, from, timer)}
  end

  def handle_call({:call_tool, name, input, timeout}, from, state) do
    id = state.next_id
    params = %{"name" => name, "arguments" => input}
    request = Protocol.encode_request("tools/call", params, id)
    state.transport_mod.send_message(state.transport, request)
    timer = Process.send_after(self(), {:request_timeout, id}, timeout)
    {:noreply, put_pending(state, id, from, timer)}
  end

  def handle_call({:initialize, timeout}, from, state) do
    id = state.next_id
    request = Protocol.encode_request("initialize", Protocol.initialize_params(), id)
    state.transport_mod.send_message(state.transport, request)
    timer = Process.send_after(self(), {:request_timeout, id}, timeout)
    {:noreply, put_pending(state, id, from, timer, :initialize)}
  end

  @impl GenServer
  def handle_info({:mcp_message, line}, state) do
    case Protocol.decode(line) do
      {:ok, %{"id" => id} = response} when is_integer(id) ->
        handle_response(id, response, state)

      _ ->
        # Notification or malformed message — ignore
        {:noreply, state}
    end
  end

  def handle_info({:transport_down, reason}, state) do
    error = Error.new(:transport, "Transport connection lost: #{inspect(reason)}")

    Enum.each(state.pending, fn {_id, {from, timer, _type}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, error})
    end)

    {:stop, {:shutdown, error}, %{state | pending: %{}}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {{from, _timer, _type}, remaining} ->
        error = Error.new(:timeout, "MCP request #{id} timed out")
        GenServer.reply(from, {:error, error})
        {:noreply, %{state | pending: remaining}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state[:transport] do
      state.transport_mod.close(state.transport)
    end

    :ok
  end

  # ── Private ───────────────────────────────────────────────────────

  defp new_state(transport, transport_mod, timeout) do
    %{
      transport: transport,
      transport_mod: transport_mod,
      pending: %{},
      next_id: 1,
      server_info: nil,
      request_timeout_ms: timeout
    }
  end

  defp transport_module(opts) do
    cond do
      Keyword.has_key?(opts, :url) -> ExAthena.Mcp.Transport.Http
      Keyword.has_key?(opts, :command) -> ExAthena.Mcp.Transport.Stdio
      true -> raise ArgumentError, "Client opts must include :command (stdio) or :url (http)"
    end
  end

  # Synchronous initialize performed during init/1 via bare receive.
  defp do_initialize_sync(state) do
    id = state.next_id
    request = Protocol.encode_request("initialize", Protocol.initialize_params(), id)
    state.transport_mod.send_message(state.transport, request)
    timeout = state.request_timeout_ms

    receive do
      {:mcp_message, line} ->
        case Protocol.decode(line) do
          {:ok, %{"id" => ^id} = response} ->
            case Protocol.extract_result(response) do
              {:ok, server_info} ->
                notif = Protocol.encode_notification("notifications/initialized", %{})
                state.transport_mod.send_message(state.transport, notif)
                {:ok, %{state | server_info: server_info, next_id: id + 1}}

              {:error, error} ->
                {:stop, {:shutdown, error}}
            end

          _ ->
            {:stop, {:shutdown, Error.new(:transport, "Unexpected response during initialize")}}
        end

      {:transport_down, reason} ->
        {:stop,
         {:shutdown,
          Error.new(:transport, "Transport died during initialize: #{inspect(reason)}")}}
    after
      timeout ->
        {:stop, {:shutdown, Error.new(:timeout, "MCP initialize timed out after #{timeout}ms")}}
    end
  end

  defp put_pending(state, id, from, timer, type \\ :request) do
    pending = Map.put(state.pending, id, {from, timer, type})
    %{state | pending: pending, next_id: id + 1}
  end

  defp handle_response(id, response, state) do
    case Map.pop(state.pending, id) do
      {{from, timer, :initialize}, remaining} ->
        Process.cancel_timer(timer)

        reply =
          case Protocol.extract_result(response) do
            {:ok, server_info} ->
              notif = Protocol.encode_notification("notifications/initialized", %{})
              state.transport_mod.send_message(state.transport, notif)
              new_state = %{state | pending: remaining, server_info: server_info}
              GenServer.reply(from, :ok)
              {:noreply, new_state}

            {:error, error} ->
              GenServer.reply(from, {:error, error})
              {:noreply, %{state | pending: remaining}}
          end

        reply

      {{from, timer, _type}, remaining} ->
        Process.cancel_timer(timer)
        result = Protocol.extract_result(response)
        GenServer.reply(from, result)
        {:noreply, %{state | pending: remaining}}

      {nil, _} ->
        {:noreply, state}
    end
  end
end
