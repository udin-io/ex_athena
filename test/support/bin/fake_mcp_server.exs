# Minimal stdio MCP server for testing. Requires Elixir >= 1.18 (stdlib JSON).
# Responds to initialize, notifications/initialized, tools/list, tools/call(echo).

defmodule FakeMcpServer do
  @tools [
    %{
      "name" => "echo",
      "description" => "Echoes the message back",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"message" => %{"type" => "string"}},
        "required" => ["message"]
      }
    }
  ]

  def run do
    loop()
  end

  defp loop do
    case IO.gets("") do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line when is_binary(line) ->
        line |> String.trim() |> dispatch_if_nonempty()
        loop()
    end
  end

  defp dispatch_if_nonempty(""), do: :ok

  defp dispatch_if_nonempty(line) do
    case JSON.decode(line) do
      {:ok, msg} -> dispatch(msg)
      {:error, _} -> :ok
    end
  end

  defp dispatch(%{"method" => "initialize", "id" => id}) do
    reply(id, %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "fake-mcp", "version" => "0.1.0"}
    })
  end

  defp dispatch(%{"method" => "notifications/initialized"}), do: :ok

  defp dispatch(%{"method" => "tools/list", "id" => id}) do
    reply(id, %{"tools" => @tools})
  end

  defp dispatch(%{
         "method" => "tools/call",
         "id" => id,
         "params" => %{"name" => "echo", "arguments" => %{"message" => msg}}
       }) do
    reply(id, %{"content" => [%{"type" => "text", "text" => msg}], "isError" => false})
  end

  defp dispatch(%{"id" => id}) do
    error_reply(id, -32_601, "Method not found")
  end

  defp dispatch(_), do: :ok

  defp reply(id, result) do
    IO.puts(JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
  end

  defp error_reply(id, code, message) do
    IO.puts(
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => code, "message" => message}
      })
    )
  end
end

FakeMcpServer.run()
