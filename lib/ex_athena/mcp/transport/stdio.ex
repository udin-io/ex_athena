defmodule ExAthena.Mcp.Transport.Stdio do
  @moduledoc false

  @behaviour ExAthena.Mcp.Transport

  use GenServer

  # 1 MB — enough for any realistic MCP message
  @max_line_bytes 1_048_576

  @impl ExAthena.Mcp.Transport
  def start_link(opts, owner) do
    # Use start/3 (not start_link) so an init failure does not send an EXIT
    # signal to the caller; the Client links manually after successful start.
    GenServer.start(__MODULE__, {opts, owner})
  end

  @impl ExAthena.Mcp.Transport
  def send_message(pid, json) do
    GenServer.cast(pid, {:send, json})
  end

  @impl ExAthena.Mcp.Transport
  def close(pid) do
    GenServer.cast(pid, :close)
  end

  @impl GenServer
  def init({opts, owner}) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env_map = Keyword.get(opts, :env, %{})

    executable = System.find_executable(command) || command

    port_env =
      Enum.map(env_map, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    try do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          {:line, @max_line_bytes},
          args: args,
          env: port_env
        ])

      {:ok, %{port: port, owner: owner, buf: ""}}
    rescue
      e -> {:stop, {:port_error, Exception.message(e)}}
    end
  end

  @impl GenServer
  def handle_cast({:send, json}, %{port: port} = state) do
    try do
      Port.command(port, json <> "\n")
    rescue
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_cast(:close, %{port: port} = state) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    {:stop, :normal, state}
  end

  @impl GenServer
  # Complete line
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    full = state.buf <> line
    send(state.owner, {:mcp_message, full})
    {:noreply, %{state | buf: ""}}
  end

  # Partial line — accumulate
  def handle_info({port, {:data, {:noeol, partial}}}, %{port: port} = state) do
    {:noreply, %{state | buf: state.buf <> partial}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    send(state.owner, {:transport_down, {:exit, code}})
    {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{port: port} = state) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    send(state.owner, {:transport_down, :closed})
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
