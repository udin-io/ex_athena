defmodule ExAthena.Mcp.Transport.Http do
  @moduledoc false

  @behaviour ExAthena.Mcp.Transport

  use GenServer

  @impl ExAthena.Mcp.Transport
  def start_link(opts, owner) do
    # Use start/3 so init failures do not send EXIT signals to caller.
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
    {:ok,
     %{
       url: Keyword.fetch!(opts, :url),
       headers: Keyword.get(opts, :headers, %{}),
       request_timeout_ms: Keyword.get(opts, :request_timeout_ms, 30_000),
       session_id: nil,
       owner: owner
     }}
  end

  @impl GenServer
  def handle_cast({:send, json}, state) do
    base_headers =
      [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", ExAthena.Mcp.Protocol.protocol_version()}
      ] ++ Enum.map(state.headers, fn {k, v} -> {k, v} end)

    headers =
      if state.session_id do
        [{"mcp-session-id", state.session_id} | base_headers]
      else
        base_headers
      end

    case Req.post(state.url,
           body: json,
           headers: headers,
           receive_timeout: state.request_timeout_ms,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: body, headers: resp_headers}} ->
        session_id = extract_session_id(resp_headers, state.session_id)
        content_type = get_header(resp_headers, "content-type", "application/json")
        messages = parse_body(body, content_type)
        Enum.each(messages, &send(state.owner, {:mcp_message, &1}))
        {:noreply, %{state | session_id: session_id}}

      {:ok, %{status: status}} ->
        err = ExAthena.Error.new(:server_error, "HTTP #{status}")
        send(state.owner, {:transport_down, err})
        {:stop, :normal, state}

      {:error, reason} ->
        send(state.owner, {:transport_down, reason})
        {:stop, :normal, state}
    end
  end

  def handle_cast(:close, state), do: {:stop, :normal, state}

  defp extract_session_id(headers, default) do
    case List.keyfind(headers, "mcp-session-id", 0) do
      {_, id} -> id
      nil -> default
    end
  end

  defp get_header(headers, name, default) do
    case List.keyfind(headers, name, 0) do
      {_, v} -> v
      nil -> default
    end
  end

  defp parse_body(body, content_type) when is_binary(body) do
    if String.contains?(content_type, "text/event-stream") do
      body
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&String.slice(&1, 6..-1//1))
      |> Enum.reject(&(&1 == ""))
    else
      [body]
    end
  end

  defp parse_body(body, _content_type) when is_map(body) or is_list(body) do
    [Jason.encode!(body)]
  end
end
