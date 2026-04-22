# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and ExAthena adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.2.0 — unreleased

Phase 2 of the agent-loop roadmap: ex_athena is now feature-complete for
multi-turn tool-using work. Drop-in replacement for the Claude Code SDK.

### Added — Agent loop

- `ExAthena.Loop` — multi-turn loop. Infer → parse tool calls → permissions →
  PreToolUse hooks → execute → PostToolUse hooks → replay → repeat. Bounded
  by `:max_iterations` (default 25). Auto-falls-back between native and
  text-tagged tool-call protocols via `ExAthena.ToolCalls.extract/2`.
- `ExAthena.Session` — GenServer owning multi-turn conversation state.
  Appends to message history on every turn, resumable, supervised.
- `ExAthena.run/2` + `ExAthena.extract_structured/2` on the facade.

### Added — Tool behaviour + builtins

- `ExAthena.Tool` behaviour (`name`, `description`, `schema`, `execute`).
- `ExAthena.ToolContext` — `:cwd`, `:phase`, `:session_id`, `:tool_call_id`,
  `:assigns`, plus `resolve_path/2` that rejects traversal + null bytes.
- `ExAthena.Tools` registry — resolves user tool lists and constructs the
  provider-facing + prompt-facing schemas.
- Ten builtin tools:
  - `Read` (with line numbering + offset/limit)
  - `Glob` (wildcard listing with max cap)
  - `Grep` (`rg` when available, pure-Elixir fallback)
  - `Write` (creates parent dirs)
  - `Edit` (strict exact-string replacement, ambiguity-rejecting)
  - `Bash` (port-based, configurable timeout, kills on timeout)
  - `WebFetch` (http/https only, 1 MB cap)
  - `TodoWrite` (validates statuses, optional notifier callback via `assigns`)
  - `PlanMode` (phase transition request — loop consumes the sentinel)
  - `SpawnAgent` (synchronous sub-loop, inherits ctx, filters meta-tools)

### Added — Permissions

- `ExAthena.Permissions` with three modes (`:plan`, `:default`,
  `:bypass_permissions`), `allowed_tools`/`disallowed_tools` lists, and a
  `can_use_tool` callback for interactive approval.
- `:plan` mode blocks mutation tools (`write`, `edit`, `bash`, `todo_write`)
  by default; read-only tools always permitted.

### Added — Hooks

- `ExAthena.Hooks` lifecycle matching Claude Code's shape: `PreToolUse`,
  `PostToolUse`, `Stop`, `Notification`, `PreCompact`, `SessionStart`,
  `SessionEnd`. Matcher groups (regex or string) select which tools fire.
  Hook crashes are caught and become `:halt` returns.

### Added — Structured extraction

- `ExAthena.Structured.extract/2` — one-shot JSON extraction with schema
  validation. Uses JSON mode when the provider supports it; falls back to a
  fenced `~~~json` block for providers that don't. `:validator` opt for
  custom validation.

### Test surface

- 95 tests (up from 43 in Phase 1). Coverage per tool, permission modes,
  hook lifecycle, loop end-to-end driven by the Mock provider, structured
  extraction both JSON-mode and fenced.

### Phase 3 roadmap (next PR)

Start migrating `udin_code` off direct `claude_code` calls. Route ticket
work (`SdkRunner`, `GenericRunner`, `Orchestrator`) through `ExAthena.Session`
so picking `:ollama` in the `ModelProvider` UI begins actually running tasks
on Ollama.

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
