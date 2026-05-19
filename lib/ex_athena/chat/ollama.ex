defmodule ExAthena.Chat.Ollama do
  @moduledoc """
  Talks to a local Ollama daemon's native HTTP API for chat-time helpers.

  Right now: one function, `list_models/1`, which hits `GET /api/tags` and
  returns the installed model names sorted alphabetically. The tags endpoint
  lives on the bare host (not under `/v1`), so we strip the OpenAI prefix
  ExAthena adds internally.
  """

  @default_base_url "http://localhost:11434"
  @timeout_ms 2_000

  @spec list_models(keyword()) ::
          {:ok, [String.t()]}
          | {:error, :ollama_unreachable | :unexpected_response | {:http, integer()}}
  def list_models(opts \\ []) do
    base = opts |> Keyword.get(:base_url, configured_base_url()) |> strip_openai_suffix()
    url = base <> "/api/tags"

    case Req.get(url, receive_timeout: @timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode_models(body)
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, %Req.TransportError{}} -> {:error, :ollama_unreachable}
      {:error, %Mint.TransportError{}} -> {:error, :ollama_unreachable}
      {:error, _} -> {:error, :ollama_unreachable}
    end
  end

  defp decode_models(%{"models" => list}) when is_list(list) do
    names =
      list
      |> Enum.map(&Map.get(&1, "name"))
      |> Enum.filter(&is_binary/1)
      |> Enum.sort()

    {:ok, names}
  end

  defp decode_models(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode_models(decoded)
      {:error, _} -> {:error, :unexpected_response}
    end
  end

  defp decode_models(_), do: {:error, :unexpected_response}

  defp configured_base_url do
    :ex_athena
    |> Application.get_env(:ollama, [])
    |> Keyword.get(:base_url, @default_base_url)
  end

  defp strip_openai_suffix(url) when is_binary(url) do
    url
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1", "")
  end
end
