defmodule ExAthena.Mcp.Protocol do
  @moduledoc false

  alias ExAthena.Error

  @json_rpc_version "2.0"
  @protocol_version "2025-06-18"

  @doc false
  def protocol_version, do: @protocol_version

  @doc "Encode a JSON-RPC request to a newline-terminated string."
  @spec encode_request(String.t(), map(), integer()) :: String.t()
  def encode_request(method, params, id) do
    Jason.encode!(%{
      "jsonrpc" => @json_rpc_version,
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  @doc "Encode a JSON-RPC notification (no id)."
  @spec encode_notification(String.t(), map()) :: String.t()
  def encode_notification(method, params) do
    Jason.encode!(%{
      "jsonrpc" => @json_rpc_version,
      "method" => method,
      "params" => params
    })
  end

  @doc "Decode a JSON string into a map."
  @spec decode(String.t()) :: {:ok, map()} | {:error, term()}
  def decode(json), do: Jason.decode(json)

  @doc """
  Extract `{:ok, result}` or `{:error, %ExAthena.Error{}}` from a decoded
  JSON-RPC response map.
  """
  @spec extract_result(map()) :: {:ok, term()} | {:error, Error.t()}
  def extract_result(%{"result" => result}), do: {:ok, result}

  def extract_result(%{"error" => %{"code" => code, "message" => message}}) do
    {:error, Error.new(error_kind(code), message, raw: %{code: code})}
  end

  def extract_result(_), do: {:error, Error.new(:unknown, "Malformed JSON-RPC response")}

  @doc "Params map for the MCP initialize request."
  @spec initialize_params() :: map()
  def initialize_params do
    %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "ex_athena", "version" => "0.1.0"}
    }
  end

  # JSON-RPC error code → ExAthena.Error kind
  defp error_kind(-32_700), do: :bad_request
  defp error_kind(-32_600), do: :bad_request
  defp error_kind(-32_601), do: :not_found
  defp error_kind(-32_602), do: :bad_request
  defp error_kind(-32_603), do: :server_error
  defp error_kind(code) when code in -32_099..-32_000, do: :server_error
  defp error_kind(_), do: :unknown
end
