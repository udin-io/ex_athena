# ExAthena

[![Hex.pm](https://img.shields.io/hexpm/v/ex_athena.svg)](https://hex.pm/packages/ex_athena)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ex_athena)
[![License](https://img.shields.io/badge/license-Apache--2.0-green.svg)](LICENSE)

Provider-agnostic agent loop for Elixir. Drop-in replacement for the Claude
Code SDK that runs on **Ollama**, **OpenAI-compatible endpoints**
(OpenAI, OpenRouter, LM Studio, vLLM, Groq, Together, llama.cpp server…),
or **Anthropic Claude** itself — with the same tools, hooks, permissions,
and streaming semantics across every provider.

> **Status:** Phase 1 ships pure inference — `query/3` and `stream/3` across
> every supported provider, plus the canonical message/request/response
> shapes and both tool-call protocols. The agent loop, tool execution, and
> `ExAthena.Session` land in Phase 2.

## Why

If you're using `claude_code` today and want to switch to a local Ollama
model — or route per-task to OpenAI-compatible endpoints, or try Groq
behind the same Elixir code — you don't want to rewrite every orchestrator.
ExAthena is that abstraction layer. Pick a provider, run the same call,
get back the same shape.

## Install

The one-liner (Igniter auto-installs + writes sensible config):

```bash
mix igniter.install ex_athena
```

Or manually — add to `mix.exs`:

```elixir
def deps do
  [
    {:ex_athena, "~> 0.1"},
    # optional — only needed for the Claude provider:
    {:claude_code, "~> 0.36"}
  ]
end
```

…then run `mix ex_athena.install` once to wire up defaults, or configure
manually (see [Configuration](#configuration)).

## Quick start

```elixir
# config/config.exs
config :ex_athena, default_provider: :ollama
config :ex_athena, :ollama, base_url: "http://localhost:11434", model: "llama3.1"

# anywhere
{:ok, response} = ExAthena.query("Tell me a joke")
IO.puts(response.text)

# streaming
ExAthena.stream("Explain quantum computing", fn event ->
  case event.type do
    :text_delta -> IO.write(event.data)
    :stop -> IO.puts("\n[done]")
    _ -> :ok
  end
end)
```

Swap the provider by changing one option:

```elixir
ExAthena.query("hi", provider: :openai_compatible, model: "gpt-4o-mini")
ExAthena.query("hi", provider: :claude, model: "claude-opus-4-5")
ExAthena.query("hi", provider: :ollama, model: "qwen2.5-coder")
```

## Providers

| Provider | Module | Notes |
|---|---|---|
| `:ollama` | `ExAthena.Providers.Ollama` | Local Ollama, `/api/chat`. Native tool-calls on modern models. |
| `:openai_compatible` | `ExAthena.Providers.OpenAICompatible` | `/v1/chat/completions` — covers OpenAI, OpenRouter, LM Studio, vLLM, Groq, Together, llama.cpp server mode, etc. |
| `:openai` | `ExAthena.Providers.OpenAICompatible` | Alias. |
| `:llamacpp` | `ExAthena.Providers.OpenAICompatible` | Alias. |
| `:claude` | `ExAthena.Providers.Claude` | Wraps the `claude_code` SDK. Preserves hooks, MCP, session resume. |
| `:mock` | `ExAthena.Providers.Mock` | In-memory test double. |

Pass a custom module that implements `ExAthena.Provider` directly if you
have an endpoint that doesn't fit the above.

## Configuration

```elixir
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
```

Resolution is **tiered** — per-call opts always beat app env:

```elixir
ExAthena.query("…",
  provider: :openai_compatible,          # overrides default_provider
  base_url: "https://openrouter.ai/api/v1",  # overrides :openai_compatible, base_url
  api_key: System.get_env("OPENROUTER_API_KEY"),
  model: "anthropic/claude-opus-4.1")
```

## Tool calls

`ExAthena.ToolCalls` handles both protocols and auto-falls-back between them:

- **Native** — OpenAI `tool_calls` arrays and Anthropic `tool_use` blocks.
  Parsed into canonical `ExAthena.Messages.ToolCall` structs.
- **TextTagged** — `~~~tool_call {json}` fenced blocks embedded in assistant
  prose, for models without native support.

The agent loop (Phase 2) will pick the protocol based on the provider's
declared capabilities, and fall back when the model gets it wrong.

## Guides

- [Getting started](guides/getting_started.md)
- [Providers](guides/providers.md)
- [Tool calls](guides/tool_calls.md)

## License

Apache 2.0 — see [LICENSE](LICENSE).
