defmodule ExAthena.Mcp.Tool do
  @moduledoc """
  Executor for MCP-backed tool specs.

  Called by `ExAthena.Tool.Spec.execute/3` for specs with `kind: :mcp`.
  Looks up the server pid in the registry, calls `tools/call` via the
  `Client`, and maps the result to the loop's `{:ok, content} | {:error, reason}`
  shape.
  """

  alias ExAthena.Mcp.Client
  alias ExAthena.Mcp.Registry, as: McpRegistry
  alias ExAthena.Mcp.Server, as: McpServer
  alias ExAthena.Tool.Spec
  alias ExAthena.ToolContext

  @default_timeout_ms 30_000

  @doc """
  Execute an MCP-backed tool.

  Honors the loop's `tool_timeout_ms` when carried in `ctx.assigns[:tool_timeout_ms]`,
  falling back to 30s otherwise. Calls the underlying `Client` directly (via a
  pid resolved through the `Server`) so the per-server `Server` GenServer is not
  blocked for the duration of the tool call.

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
  def execute(%Spec{kind: :mcp, mcp_server: server, mcp_tool_name: tool_name}, args, ctx) do
    timeout = resolve_timeout(ctx)

    case McpRegistry.whereis(server) do
      nil ->
        {:error, {:mcp_server_not_running, server}}

      server_pid ->
        try do
          case McpServer.get_client(server_pid) do
            {:ok, client_pid} ->
              call_client(client_pid, tool_name, args, timeout)

            {:error, _} = err ->
              err
          end
        catch
          :exit, _ -> {:error, {:mcp_server_not_running, server}}
        end
    end
  end

  defp call_client(client_pid, tool_name, args, timeout) do
    try do
      with {:ok, %{"content" => content, "isError" => false}} <-
             Client.call_tool(client_pid, tool_name, args, timeout) do
        {:ok, content}
      else
        {:ok, %{"content" => content, "isError" => true}} -> {:error, content}
        {:ok, result} -> {:ok, result}
        {:error, _} = err -> err
      end
    catch
      :exit, reason -> {:error, {:mcp_client_unavailable, reason}}
    end
  end

  defp resolve_timeout(%ToolContext{assigns: %{tool_timeout_ms: ms}})
       when is_integer(ms) and ms > 0,
       do: ms

  defp resolve_timeout(_), do: @default_timeout_ms
end
