# Providers

ExAthena ships four built-in providers plus a `:mock` for tests. Consumers
can also pass any module that implements `ExAthena.Provider` directly.

## Ollama (`:ollama`)

Local Ollama via `/api/chat`. Native OpenAI-style `tool_calls` on modern
models (`llama3.1`, `qwen2.5-coder`, `mistral-nemo`, `llama3.2`, `phi-3.5`).
Streaming via newline-delimited JSON chunks.

```elixir
config :ex_athena, :ollama,
  base_url: "http://localhost:11434",
  model: "llama3.1"
```

Per-call override:

```elixir
ExAthena.query("…", provider: :ollama, model: "qwen2.5-coder")
```

### Capabilities

| Feature | Status |
|---|---|
| Native tool calls | ✅ (model-dependent) |
| Streaming | ✅ |
| JSON mode | ✅ via `format: "json"` |
| Resume | ❌ (use `ExAthena.Session` in Phase 2) |

## OpenAI-compatible (`:openai_compatible` / `:openai` / `:llamacpp`)

`/v1/chat/completions`. Covers every endpoint that speaks OpenAI chat
completions: OpenAI proper, OpenRouter, LM Studio, vLLM, Groq, Together AI,
DeepInfra, Fireworks, llama.cpp's server mode. Streaming via SSE.

```elixir
config :ex_athena, :openai_compatible,
  base_url: "https://api.openai.com/v1",
  api_key: System.get_env("OPENAI_API_KEY"),
  model: "gpt-4o-mini"
```

### Swap endpoint per-call

```elixir
ExAthena.query("…",
  provider: :openai_compatible,
  base_url: "https://openrouter.ai/api/v1",
  api_key: System.get_env("OPENROUTER_API_KEY"),
  model: "anthropic/claude-opus-4.1")
```

### Capabilities

| Feature | Status |
|---|---|
| Native tool calls | ✅ |
| Streaming | ✅ SSE |
| JSON mode | ✅ via `response_format: %{type: "json_object"}` |
| Resume | ❌ |

## Claude (`:claude`)

Wraps the `claude_code` SDK. Preserves every feature the SDK provides
natively — hooks, `can_use_tool` callbacks, MCP servers, session resume,
prompt cache reuse — by passing them through via `:provider_opts`.

```elixir
config :ex_athena, :claude,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: "claude-opus-4-5"
```

The `claude_code` dep is declared `optional: true` on `ex_athena`; if you
use this provider, add it to your own deps:

```elixir
{:claude_code, "~> 0.36"}
```

### Capabilities

| Feature | Status |
|---|---|
| Native tool calls | ✅ `tool_use` blocks |
| Streaming | Phase 2 (via `ExAthena.Session`) |
| JSON mode | ❌ (use structured output in Phase 2) |
| Resume | ✅ via the SDK's session resume |

## Gemini (`:gemini`)

Google Gemini via the Google AI Studio API. Backed by `req_llm`'s Google
adapter — supports native tool calls (via v1beta, the default) and streaming
via SSE.

```elixir
config :ex_athena, :gemini,
  api_key: System.get_env("GOOGLE_API_KEY"),
  model: "gemini-2.5-flash"
```

Per-call override:

```elixir
ExAthena.query("…", provider: :gemini, model: "gemini-2.5-pro")
```

For the full walkthrough — API key setup, model table, tool-calling caveats,
and rate-limit notes — see the **[Gemini setup guide](gemini.md)**.

## Mock (`:mock`)

Unit-test double. Scripted responses either via canned text or a responder
function, plus optional per-call event lists for streaming tests.

```elixir
ExAthena.query("ping", provider: :mock, mock: [text: "pong"])

# Dynamic:
responder = fn request -> %ExAthena.Response{text: "echo: " <> hd(request.messages).content} end
ExAthena.query("hi", provider: :mock, mock: [responder: responder])

# Streaming:
events = [
  %ExAthena.Streaming.Event{type: :text_delta, data: "Hello"},
  %ExAthena.Streaming.Event{type: :text_delta, data: " world"},
  %ExAthena.Streaming.Event{type: :stop, data: :stop}
]
ExAthena.stream("hi", fn _ -> :ok end,
  provider: :mock,
  mock: [text: "Hello world"],
  mock_events: events)
```

## Custom providers

Implement the `ExAthena.Provider` behaviour:

```elixir
defmodule MyApp.MyProvider do
  @behaviour ExAthena.Provider

  @impl true
  def capabilities, do: %{native_tool_calls: false, streaming: false}

  @impl true
  def query(%ExAthena.Request{} = req, _opts) do
    # … make your call, return {:ok, %ExAthena.Response{}}
  end
end

ExAthena.query("hi", provider: MyApp.MyProvider)
```

Capabilities are used by the agent loop (Phase 2) to pick the right
tool-call protocol. Declare what you actually support — if you lie, the
loop will fall back automatically.
