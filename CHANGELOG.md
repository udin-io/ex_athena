# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and ExAthena adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.1.0 — unreleased

Initial public release. Phase 1 of the agent-loop roadmap: pure inference
across any provider, with the canonical message/request/response shapes and
tool-call parsing infrastructure in place for Phase 2's agent loop.

### Added — Core API

- `ExAthena.query/2` — one-shot inference.
- `ExAthena.stream/3` — streaming inference with per-event callback.
- `ExAthena.capabilities/1` — static provider-capability lookup.
- `ExAthena.Config` — tiered resolver (per-call → provider env → top-level
  env → default).
- `ExAthena.Error` — canonical error struct with `:kind` atoms
  (`:unauthorized`, `:not_found`, `:rate_limited`, `:timeout`,
  `:context_length_exceeded`, `:bad_request`, `:server_error`, `:transport`,
  `:capability`, `:unknown`).

### Added — Canonical shapes

- `ExAthena.Request` — normalised inference request consumed by every provider.
- `ExAthena.Response` — normalised response with `:text`, `:tool_calls`,
  `:finish_reason`, `:usage`, `:model`, `:provider`, `:raw`.
- `ExAthena.Messages.Message` / `.ToolCall` / `.ToolResult` — conversation
  primitives. `Messages.from_map/1` tolerates both atom and string keys for
  easy interop with provider JSON.
- `ExAthena.Streaming.Event` — canonical streaming events
  (`:start`, `:text_delta`, `:tool_call_start`, `:tool_call_delta`,
  `:tool_call_end`, `:usage`, `:stop`, `:error`).

### Added — Provider contract

- `ExAthena.Provider` behaviour with `query/2`, `stream/3` (optional),
  `capabilities/0`.
- `ExAthena.Capabilities` type declaring features a provider supports.

### Added — Providers

- `ExAthena.Providers.Ollama` — local Ollama via `/api/chat` (native tool-calls
  on supported models, SSE-style newline-delimited streaming).
- `ExAthena.Providers.OpenAICompatible` — `/v1/chat/completions` for OpenAI,
  OpenRouter, LM Studio, vLLM, llama.cpp server, Together, Groq, etc. SSE
  streaming.
- `ExAthena.Providers.Claude` — wraps the `claude_code` SDK. `claude_code`
  is declared optional so consumers that don't use Claude aren't forced to
  install it. (Streaming via this provider lands in Phase 2 with sessions.)
- `ExAthena.Providers.Mock` — in-memory test double with scripted responses
  and event lists.

### Added — Tool-call parsing

- `ExAthena.ToolCalls.Native` — parses OpenAI-style `tool_calls` and Claude
  `tool_use` blocks. Tolerant of atom/string keys and JSON-string arguments.
- `ExAthena.ToolCalls.TextTagged` — parses `~~~tool_call` fenced blocks out
  of assistant prose for models without native tool-call support.
- `ExAthena.ToolCalls.extract/2` — dispatch-and-fallback between the two
  protocols based on provider capabilities.
- `ExAthena.ToolCalls.augment_system_prompt/2` — appends text-tagged
  instructions to a system prompt for non-native-capable providers.

### Added — Igniter installer

- `mix ex_athena.install` — writes sensible `config :ex_athena` defaults,
  idempotent. Picks Ollama as the default provider. Requires the `igniter`
  dep (declared optional).

### Phase 2 roadmap

Still to land: `ExAthena.Tool` behaviour + builtins (Read, Glob, Grep, Write,
Edit, Bash, WebFetch, TodoWrite, PlanMode, SpawnAgent), `ExAthena.Loop`
(multi-turn agent loop), `ExAthena.Session` GenServer, `ExAthena.Hooks`
(PreToolUse/PostToolUse/Stop lifecycle), `ExAthena.Permissions`
(`:plan` / `:default` / `:bypass` + `can_use_tool` callback), and
`ExAthena.extract_structured/3` (JSON-schema-validated output).

### Phase 3+ roadmap

Migrate `udin_code` off the `claude_code` direct dep: route every call through
`ExAthena.*`, delete `UdinCode.Claude.GenericRunner`, make picking `:ollama`
in the ModelProvider UI actually run the whole task lifecycle on Ollama.
