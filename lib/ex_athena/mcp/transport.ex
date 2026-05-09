defmodule ExAthena.Mcp.Transport do
  @moduledoc false

  @doc """
  Start a transport process. `owner` receives:
    - `{:mcp_message, json_string}` for each complete JSON-RPC message
    - `{:transport_down, reason}` when the transport terminates
  """
  @callback start_link(opts :: keyword(), owner :: pid()) :: {:ok, pid()} | {:error, term()}

  @doc "Send a JSON string to the remote end."
  @callback send_message(pid :: pid(), json :: String.t()) :: :ok

  @doc "Close the transport."
  @callback close(pid :: pid()) :: :ok
end
