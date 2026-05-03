defmodule ExAthena.StructuredOutput do
  @moduledoc """
  Strict structured-output helper. Requires provider `:structured_output` capability.

  Unlike `ExAthena.Structured`, which falls back to fenced-block extraction and
  retries, this module sends the `response_format` straight through to the
  provider and decodes the JSON exactly once. Use it with providers that
  natively enforce a JSON schema (e.g. Ollama via req_llm's OpenAI adapter).

  Returns `{:error, :no_structured_output}` when the provider (or a per-request
  `:capabilities` override) does not advertise `structured_output: true`.
  """

  alias ExAthena.{Config, Request, Response}

  @spec request(String.t(), String.t() | atom() | map(), keyword()) ::
          {:ok, map()} | {:error, :no_structured_output | :invalid_json | term()}
  def request(prompt, schema, opts \\ []) do
    {provider_mod, opts} = Config.pop_provider!(opts)
    caps = Map.merge(provider_mod.capabilities(), opts[:capabilities] || %{})

    if caps[:structured_output] do
      response_format = build_response_format(schema)
      request_opts = Keyword.put(opts, :response_format, response_format)
      req = Request.new(prompt, request_opts)
      provider_opts = Config.provider_opts(provider_mod, opts)

      case provider_mod.query(req, provider_opts) do
        {:ok, %Response{text: text}} -> decode(text)
        {:error, _} = err -> err
      end
    else
      {:error, :no_structured_output}
    end
  end

  defp build_response_format("json"), do: :json
  defp build_response_format(:json), do: :json

  defp build_response_format(schema) when is_map(schema) do
    %{type: "json_schema", json_schema: %{name: "response", schema: schema, strict: true}}
  end

  defp build_response_format(other) do
    raise ArgumentError, "unsupported schema: #{inspect(other)}"
  end

  defp decode(nil), do: {:error, :invalid_json}

  defp decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :invalid_json}
      {:error, _} -> {:error, :invalid_json}
    end
  end
end
