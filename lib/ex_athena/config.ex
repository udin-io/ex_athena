defmodule ExAthena.Config do
  @moduledoc """
  Resolves the provider and per-call options for an ExAthena request.

  Resolution order (per key):

    1. `opts[:key]` — per-call override always wins.
    2. `Application.get_env(:ex_athena, provider)[:key]` — provider-specific config.
    3. `Application.get_env(:ex_athena, :key)` — top-level library config.
    4. Provider default (if the provider declares one).

  Matches the `stripity_stripe` / `ex_aws` pattern: per-call overrides win,
  application config is the default, no global mutable state.

  ## Known providers

  | Atom | Module |
  |---|---|
  | `:ollama` | `ExAthena.Providers.Ollama` |
  | `:openai_compatible` | `ExAthena.Providers.OpenAICompatible` |
  | `:openai` | `ExAthena.Providers.OpenAICompatible` |
  | `:llamacpp` | `ExAthena.Providers.OpenAICompatible` |
  | `:claude` | `ExAthena.Providers.Claude` |
  | `:mock` | `ExAthena.Providers.Mock` |

  You may also pass any module that implements `ExAthena.Provider` directly.
  """

  @builtin_providers %{
    ollama: ExAthena.Providers.ReqLLM,
    openai: ExAthena.Providers.ReqLLM,
    openai_compatible: ExAthena.Providers.ReqLLM,
    llamacpp: ExAthena.Providers.ReqLLM,
    claude: ExAthena.Providers.ReqLLM,
    anthropic: ExAthena.Providers.ReqLLM,
    mock: ExAthena.Providers.Mock,
    req_llm: ExAthena.Providers.ReqLLM
  }

  # Map the ExAthena provider atom → the `req_llm` provider tag that belongs
  # in the `"tag:model-id"` spec. When an ExAthena caller says `:ollama`, the
  # ReqLLM adapter turns a raw `model: "llama3.1"` into `"ollama:llama3.1"`.
  @req_llm_provider_tag %{
    ollama: "ollama",
    openai: "openai",
    openai_compatible: "openai",
    llamacpp: "llamacpp",
    claude: "anthropic",
    anthropic: "anthropic"
  }

  @doc """
  Pop `:provider` from opts and return `{provider_module, remaining_opts}`.

  Raises `ArgumentError` if no provider is set in opts or in application env.
  """
  @spec pop_provider!(keyword()) :: {module(), keyword()}
  def pop_provider!(opts) do
    {provider, rest} = Keyword.pop(opts, :provider)

    provider =
      provider || Application.get_env(:ex_athena, :default_provider) ||
        raise ArgumentError,
              "no :provider passed and no :default_provider configured. " <>
                "Pass [provider: :ollama, ...] or set " <>
                "`config :ex_athena, default_provider: :ollama`."

    rest =
      case req_llm_provider_tag(provider) do
        nil -> rest
        tag -> Keyword.put_new(rest, :req_llm_provider_tag, tag)
      end

    {provider_module(provider), rest}
  end

  @doc """
  Translate an ExAthena provider atom into the `req_llm` provider tag used in
  `"tag:model-id"` specs. Returns `nil` when the atom doesn't map to req_llm
  (e.g. `:mock`, or a user-supplied module).
  """
  @spec req_llm_provider_tag(atom() | module()) :: String.t() | nil
  def req_llm_provider_tag(atom) when is_atom(atom),
    do: Map.get(@req_llm_provider_tag, atom)

  def req_llm_provider_tag(_), do: nil

  @doc "Resolve a provider atom (or module) to its implementing module."
  @spec provider_module(atom() | module()) :: module()
  def provider_module(mod) when is_atom(mod) do
    case Map.fetch(@builtin_providers, mod) do
      {:ok, module} ->
        module

      :error ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :capabilities, 0) do
          mod
        else
          raise ArgumentError,
                "unknown provider: #{inspect(mod)}. Known: " <>
                  inspect(Map.keys(@builtin_providers)) <>
                  ", or pass a module implementing ExAthena.Provider."
        end
    end
  end

  @doc false
  @spec builtin_providers() :: %{atom() => module()}
  def builtin_providers, do: @builtin_providers

  @doc """
  Look up a single configuration value for `provider_module` with the tiered
  resolution order. `opts` wins, then provider-specific config, then top-level
  config, then the supplied default.

  The provider atom is derived from the module name: `Providers.Ollama` → `:ollama`.
  """
  @spec get(module(), atom(), keyword(), term()) :: term()
  def get(provider_module, key, opts, default \\ nil) do
    Keyword.get(opts, key) ||
      get_provider_env(provider_module, key) ||
      Application.get_env(:ex_athena, key) ||
      default
  end

  @doc """
  Build the keyword list passed to a provider's `query/2` / `stream/3` callback.

  Flattens per-call overrides + application env for this provider into one
  keyword list. Providers use `Keyword.get/3` on the result.
  """
  @spec provider_opts(module(), keyword()) :: keyword()
  def provider_opts(provider_module, opts) do
    app_env = provider_app_env(provider_module)

    app_env
    |> Keyword.merge(opts)
    |> Keyword.delete(:provider)
  end

  defp provider_app_env(provider_module) do
    provider_module
    |> provider_atoms()
    |> Enum.flat_map(fn atom ->
      Application.get_env(:ex_athena, atom, [])
    end)
  end

  # A module may correspond to multiple atoms (OpenAICompatible covers
  # :openai, :openai_compatible, :llamacpp). We accumulate config from all
  # of them so users can write `config :ex_athena, :openai, api_key: "..."`.
  defp provider_atoms(provider_module) do
    @builtin_providers
    |> Enum.filter(fn {_atom, mod} -> mod == provider_module end)
    |> Enum.map(&elem(&1, 0))
  end

  defp get_provider_env(provider_module, key) do
    provider_module
    |> provider_atoms()
    |> Enum.find_value(fn atom ->
      :ex_athena
      |> Application.get_env(atom, [])
      |> Keyword.get(key)
    end)
  end
end
