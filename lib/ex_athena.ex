defmodule ExAthena do
  @moduledoc """
  Provider-agnostic agent loop for Elixir.

  ExAthena runs against Ollama, OpenAI-compatible endpoints (OpenAI, OpenRouter,
  LM Studio, vLLM, and friends), llama.cpp, Google Gemini, or the Anthropic
  Claude API — with the same tools, hooks, permissions, and streaming semantics
  across every provider.

  ## Phase 1 surface (this release)

  Pure inference — `query/3` and `stream/3`. No tool execution, no agent loop
  yet (those ship in Phase 2 alongside `ExAthena.Tool`, `ExAthena.Loop`, and
  `ExAthena.Session`).

      ExAthena.query("Tell me a joke", provider: :ollama, model: "llama3.1")
      #=> {:ok, %ExAthena.Response{text: "…", …}}

  ## Configuring a default provider

      # config/config.exs
      config :ex_athena,
        default_provider: :ollama

      config :ex_athena, :ollama,
        base_url: "http://localhost:11434",
        model: "llama3.1"

      config :ex_athena, :openai_compatible,
        base_url: "https://api.openai.com/v1",
        api_key: System.get_env("OPENAI_API_KEY"),
        model: "gpt-4o-mini"

      config :ex_athena, :claude,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        model: "claude-opus-4-5"

      config :ex_athena, :gemini,
        api_key: System.get_env("GEMINI_API_KEY"),
        model: "gemini-2.5-flash"

  Per-call overrides always win:

      ExAthena.query("…", provider: :claude, model: "claude-sonnet-4-6")

  ## Providers

  * `ExAthena.Providers.ReqLLM` — multi-backend via `req_llm`. Covers `:gemini`
    (Google Gemini), `:openai`, `:claude`/`:anthropic`, `:ollama`, and `:llamacpp`.
  * `ExAthena.Providers.Mock` — test double with scripted responses.

  Consumers can also pass a custom module that implements `ExAthena.Provider`.
  """

  alias ExAthena.{Config, Request, Response}

  @doc """
  One-shot inference. Returns the final `Response` struct with the full text.

  ## Options

    * `:provider` — provider atom (`:ollama`, `:openai_compatible`, `:claude`,
      `:gemini`, `:mock`) or a module that implements `ExAthena.Provider`. Defaults to
      `Application.get_env(:ex_athena, :default_provider)`.
    * `:model` — model name string. Defaults to the provider's configured model.
    * `:system_prompt` — optional system prompt string.
    * `:messages` — list of canonical messages; `prompt` is prepended as a user
      message if given.
    * `:max_tokens`, `:temperature`, `:top_p`, `:stop` — optional sampling knobs.
    * `:timeout_ms` — request timeout (default 60_000).
    * `:provider_opts` — escape hatch keyword list passed through to the
      underlying provider.
    * `:images` — list of image maps to attach to the trailing user message.
      Each entry is `%{data: binary(), media_type: String.t()}` for inline
      images or `%{url: String.t()}` for remote image URLs. Merged into the
      user message created from `prompt`, or the last user message in
      `:messages` when no prompt is given.
  """
  @spec query(String.t() | nil, keyword()) :: {:ok, Response.t()} | {:error, term()}
  def query(prompt \\ nil, opts \\ []) do
    {provider_mod, opts} = Config.pop_provider!(opts)
    request = Request.new(prompt, opts)
    provider_mod.query(request, Config.provider_opts(provider_mod, opts))
  end

  @doc """
  Streaming inference. Calls `callback` with each `ExAthena.Streaming.Event` as
  tokens arrive, and returns the final `Response` when the stream completes.

  `callback` receives one argument — an `%ExAthena.Streaming.Event{}` struct —
  and its return value is ignored. Callbacks must not block the caller; if you
  need to do expensive work per-delta, hand off to a `Task`.

  Options are the same as `query/2`, including `:images`.
  """
  @spec stream(String.t() | nil, function(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def stream(prompt \\ nil, callback, opts \\ []) when is_function(callback, 1) do
    {provider_mod, opts} = Config.pop_provider!(opts)
    request = Request.new(prompt, opts)
    provider_mod.stream(request, callback, Config.provider_opts(provider_mod, opts))
  end

  @doc """
  Run a multi-turn agent loop: infer → tool call → execute → replay → repeat.

  See `ExAthena.Loop.run/2` for the full option list.
  """
  @spec run(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate run(prompt, opts \\ []), to: ExAthena.Loop

  @doc """
  One-shot structured extraction. Returns a validated JSON map.

  See `ExAthena.Structured.extract/2` for the full option list.
  """
  @spec extract_structured(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate extract_structured(prompt, opts), to: ExAthena.Structured, as: :extract

  @doc """
  Returns the capabilities map for a provider.

      ExAthena.capabilities(:mock)
      #=> %{streaming: true, native_tool_calls: true, …}
  """
  @spec capabilities(atom() | module()) :: map()
  def capabilities(provider) do
    provider
    |> Config.provider_module()
    |> apply(:capabilities, [])
  end

  @doc """
  Returns `true` if the library forwards multimodal content parts
  (image / image_url / file) to the underlying provider.

  Callers can use this to decide whether to build `ExAthena.Messages.ContentPart`
  image or file parts, rather than falling back to text-only prompts.

  See `ExAthena.Messages.ContentPart`.
  """
  @spec supports_multimodal?() :: true
  def supports_multimodal?, do: true
end
