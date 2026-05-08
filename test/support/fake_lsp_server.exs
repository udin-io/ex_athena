defmodule FakeLspServer do
  @moduledoc """
  Minimal LSP server script for testing ExAthena.Lsp.Client.

  Run as: elixir test/support/fake_lsp_server.exs

  No external dependencies required — uses only OTP stdlib.
  """

  # --- JSON encode (subset sufficient for LSP responses) ---

  def encode(nil), do: "null"
  def encode(true), do: "true"
  def encode(false), do: "false"
  def encode(:null), do: "null"
  def encode(n) when is_integer(n), do: Integer.to_string(n)
  def encode(f) when is_float(f), do: Float.to_string(f)

  def encode(s) when is_binary(s) do
    escaped =
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    ~s("#{escaped}")
  end

  def encode(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &encode/1) <> "]"
  end

  def encode(map) when is_map(map) do
    pairs =
      Enum.map_join(map, ",", fn {k, v} ->
        "#{encode(to_string(k))}:#{encode(v)}"
      end)

    "{#{pairs}}"
  end

  # --- JSON decode using OTP 27 :json ---
  # :json.decode maps JSON null → :null (not nil)

  def decode(bin), do: :json.decode(bin)

  # --- server loop ---
  # Uses Port.open({:fd, 0, 1}, ...) to communicate via raw file descriptors,
  # bypassing Erlang's IO system which is unreliable in port-subprocess context.

  def run do
    port = Port.open({:fd, 0, 1}, [:binary, :eof])
    loop(port, "")
  end

  defp loop(port, buffer) do
    receive do
      {^port, {:data, data}} ->
        process_buffer(port, buffer <> data)

      {^port, :eof} ->
        :ok

      _other ->
        loop(port, buffer)
    end
  end

  defp process_buffer(port, buffer) do
    case read_frame(buffer) do
      {:ok, body, rest} ->
        msg = decode(body)
        handle(msg, port)
        process_buffer(port, rest)

      {:need_more, buf} ->
        loop(port, buf)
    end
  end

  defp read_frame(buf) do
    case parse_header(buf) do
      {:ok, len, body_buf} when byte_size(body_buf) >= len ->
        <<body::binary-size(len), remaining::binary>> = body_buf
        {:ok, body, remaining}

      _ ->
        {:need_more, buf}
    end
  end

  defp parse_header(buf) do
    with {cl_start, _} <- :binary.match(buf, "Content-Length:"),
         rest <- binary_part(buf, cl_start, byte_size(buf) - cl_start),
         {eol_pos, eol_len} <- find_eol(rest),
         # "Content-Length:" is 15 chars; skip it and trim for the digits
         digits_part <- rest |> binary_part(15, eol_pos - 15) |> String.trim(),
         {len, ""} <- Integer.parse(digits_part),
         after_first <- binary_part(rest, eol_pos + eol_len, byte_size(rest) - eol_pos - eol_len),
         {:ok, body_offset} <- skip_to_body(after_first) do
      body_buf = binary_part(after_first, body_offset, byte_size(after_first) - body_offset)
      {:ok, len, body_buf}
    else
      _ -> :error
    end
  end

  defp find_eol(buf) do
    case :binary.match(buf, "\r\n") do
      {pos, 2} ->
        {pos, 2}

      :nomatch ->
        case :binary.match(buf, "\n") do
          {pos, 1} -> {pos, 1}
          :nomatch -> nil
        end
    end
  end

  defp skip_to_body(buf) do
    cond do
      String.starts_with?(buf, "\r\n") ->
        {:ok, 2}

      String.starts_with?(buf, "\n") ->
        {:ok, 1}

      true ->
        case :binary.match(buf, "\r\n\r\n") do
          {pos, 4} ->
            {:ok, pos + 4}

          :nomatch ->
            case :binary.match(buf, "\n\n") do
              {pos, 2} -> {:ok, pos + 2}
              :nomatch -> :error
            end
        end
    end
  end

  # --- message handlers ---

  defp handle(%{"method" => "initialize", "id" => id}, port) do
    reply(port, id, %{"capabilities" => %{}})
  end

  defp handle(%{"method" => "shutdown", "id" => id}, port) do
    reply(port, id, nil)
  end

  defp handle(%{"method" => "exit"}, _port) do
    System.halt(0)
  end

  defp handle(%{"method" => "textDocument/echo", "id" => id, "params" => params}, port) do
    reply(port, id, params)
  end

  defp handle(%{"method" => "notif/trigger"}, port) do
    notify(port, "textDocument/publishDiagnostics", %{
      "uri" => "file:///test/foo.ex",
      "diagnostics" => [
        %{
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 3}
          },
          "severity" => 1,
          "message" => "undefined function foo/0"
        }
      ]
    })
  end

  defp handle(%{"method" => _method, "id" => id}, port) do
    error_reply(port, id, -32601, "MethodNotFound")
  end

  defp handle(_notification, _port), do: :ok

  # --- wire helpers ---

  defp reply(port, id, result) do
    send_msg(port, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp error_reply(port, id, code, message) do
    send_msg(port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp notify(port, method, params) do
    send_msg(port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  defp send_msg(port, msg) do
    json = encode(msg)
    frame = "Content-Length: #{byte_size(json)}\r\n\r\n#{json}"
    Port.command(port, frame)
  end
end

FakeLspServer.run()
