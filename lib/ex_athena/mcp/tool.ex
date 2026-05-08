defmodule ExAthena.Mcp.Tool do
  @moduledoc """
  Executor for MCP-backed tool specs.

  Called by `ExAthena.Tool.Spec.execute/3` for specs with `kind: :mcp`.
  Looks up the server pid in the registry, calls `tools/call` via the
  `Client`, and maps the result to the loop's `{:ok, content} | {:error, reason}`
  shape.
  """

  alias ExAthena.Mcp.Registry, as: McpRegistry
  alias ExAthena.Mcp.Server, as: McpServer
  alias ExAthena.Tool.Spec

  @doc """
  Execute an MCP-backed tool.

  Returns:
    * `{:ok, content}` — `content` is the raw `[%{"type" => ..., "text" => ...}]`
      list; the loop stringifies it for the tool-result message.
    * `{:error, content}` — server returned `is_error: true`.
    * `{:error, {:mcp_server_not_running, server_name}}` — the server is not
      registered or its pid is gone.
    * `{:error, error}` — `Client.call_tool/4` returned an error.
  """
  @spec execute(Spec.t(), map(), term()) ::
          {:ok, term()} | {:error, term()}
  def execute(%Spec{kind: :mcp, mcp_server: server, mcp_tool_name: tool_name}, args, _ctx) do
    case McpRegistry.whereis(server) do
      nil ->
        {:error, {:mcp_server_not_running, server}}

      pid ->
        try do
          with {:ok, %{"content" => content, "isError" => false}} <-
                 McpServer.call_tool(pid, tool_name, args, 30_000) do
            {:ok, content}
          else
            {:ok, %{"content" => content, "isError" => true}} -> {:error, content}
            {:ok, result} -> {:ok, result}
            {:error, _} = err -> err
          end
        catch
          :exit, _ -> {:error, {:mcp_server_not_running, server}}
        end
    end
  end
end
