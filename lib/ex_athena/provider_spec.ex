defmodule ExAthena.ProviderSpec do
  @moduledoc """
  Represents a provider loaded from a JSON file in the providers config directory.

  ## JSON format

  ```json
  {
    "name": "openrouter",
    "adapter": "req_llm",
    "req_llm_provider_tag": "openrouter",
    "base_url": "https://openrouter.ai/api/v1",
    "api_key": "sk-or-...",
    "api_key_env": "OPENROUTER_API_KEY",
    "default_model": "openai/gpt-4o",
    "extra_headers": {
      "HTTP-Referer": "https://myapp.io",
      "X-Title": "MyApp"
    },
    "model_discovery": {
      "url": "https://openrouter.ai/api/v1/models",
      "path": "data.id",
      "ttl_seconds": 300
    },
    "metadata": {}
  }
  ```

  Required fields: `name`, `adapter`.
  Known adapters: `"req_llm"`, `"mock"`.

  ## Auth resolution

  `api_key` is used as-is. When `api_key` is absent and `api_key_env` is set,
  `Config.pop_provider!/1` resolves the key from that environment variable.

  ## Extra headers

  `extra_headers` is a string-to-string map of HTTP headers injected into every
  request through the ReqLLM adapter via `req_http_options`.

  ## Model discovery

  `model_discovery` enables `ExAthena.ModelDiscovery.list_models/1`.  Required
  sub-field: `url`. Optional: `path` (dot-delimited extraction path, default
  `"data.id"`), `headers` (map), `ttl_seconds` (default `300`).
  """

  @known_adapters %{
    "req_llm" => ExAthena.Providers.ReqLLM,
    "mock" => ExAthena.Providers.Mock
  }

  @type t :: %__MODULE__{
          name: String.t(),
          adapter: atom(),
          module: module(),
          req_llm_provider_tag: String.t() | nil,
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          api_key_env: String.t() | nil,
          default_model: String.t() | nil,
          extra_headers: %{String.t() => String.t()},
          model_discovery: map() | nil,
          metadata: map()
        }

  defstruct [
    :name,
    :adapter,
    :module,
    :req_llm_provider_tag,
    :base_url,
    :api_key,
    :api_key_env,
    :default_model,
    :model_discovery,
    extra_headers: %{},
    metadata: %{}
  ]

  @doc """
  Parse a decoded JSON map into a `ProviderSpec`.

  Returns `{:ok, spec}` on success or `{:error, reason}` when required fields
  are missing or the adapter is not recognized.
  """
  @spec from_json(map()) :: {:ok, t()} | {:error, String.t()}
  def from_json(json) when is_map(json) do
    with {:ok, name} <- fetch_required_string(json, "name"),
         {:ok, adapter_str} <- fetch_required_string(json, "adapter"),
         {:ok, adapter, module} <- resolve_adapter(adapter_str) do
      spec = %__MODULE__{
        name: name,
        adapter: adapter,
        module: module,
        req_llm_provider_tag: Map.get(json, "req_llm_provider_tag"),
        base_url: Map.get(json, "base_url"),
        api_key: Map.get(json, "api_key"),
        api_key_env: Map.get(json, "api_key_env"),
        default_model: Map.get(json, "default_model"),
        extra_headers: Map.get(json, "extra_headers", %{}),
        model_discovery: Map.get(json, "model_discovery"),
        metadata: Map.get(json, "metadata", %{})
      }

      {:ok, spec}
    end
  end

  @doc false
  @spec known_adapters() :: %{String.t() => module()}
  def known_adapters, do: @known_adapters

  defp fetch_required_string(json, key) do
    case Map.get(json, key) do
      nil -> {:error, "missing required field: #{key}"}
      "" -> {:error, "field #{inspect(key)} must not be empty"}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "field #{inspect(key)} must be a string"}
    end
  end

  defp resolve_adapter(adapter_str) do
    case Map.fetch(@known_adapters, adapter_str) do
      {:ok, module} ->
        {:ok, String.to_atom(adapter_str), module}

      :error ->
        known = Map.keys(@known_adapters) |> Enum.map(&inspect/1) |> Enum.join(", ")
        {:error, "unknown adapter: #{inspect(adapter_str)}. Known: #{known}"}
    end
  end
end
