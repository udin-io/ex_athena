# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and ExAthena adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.3.0-dev — in progress (PR 3 landed)

### PR 3 — Reliability + intelligence

No additional breaking changes. New capabilities layer on top of PR 2.

#### Added — context compaction

- `ExAthena.Compactor` — behaviour for context-window reduction. Called
  by the kernel before each iteration when the token estimate crosses
  `:compact_at` (default 60% of the provider's `max_tokens`). Preserves
  a pinned prefix (system prompt + rules) and a live suffix (recent
  turns) while substituting the middle with a summary.
- `ExAthena.Compactors.Summary` — default implementation. Uses the
  session's own provider to generate a terse summary and replaces the
  dropped messages with a single assistant message tagged
  `name: "compactor_summary"`. Cost counts against the run's budget.
- New options: `:compact_at` (default 0.6), `:pinned_prefix_count`
  (default 1), `:live_suffix_count` (default 6), `:compactor` (override
  module).
- New events: `{:compaction, metadata}` fires after a successful
  compaction with before/after token counts and dropped count.
- New termination: `:error_compaction_failed` when compaction errors.
- New hook: `:PreCompact` fires with `%{estimate: …}` before each
  compaction attempt.

#### Added — budget accounting from provider metadata

- `extract_cost/1` in `ExAthena.Modes.ReAct` pulls `:total_cost` (or
  `:input_cost + :output_cost`) from provider usage metadata and folds
  it into the run's Budget. req_llm's `models.dev`-backed cost data
  flows straight through.
- `ExAthena.Result.cost_usd` is populated when the provider reports
  cost; `nil` otherwise.
- `:max_budget_usd` (introduced as a knob in PR 2) now genuinely trips
  `:error_max_budget_usd` when cumulative cost crosses the cap.

#### Added — structured-output repair loop (instructor-style)

- `ExAthena.Structured.extract/2` now retries on validation failure by
  appending the failed response + a user message carrying the validation
  error and re-prompting. Default `:max_retries: 2`.
- After retries exhaust, returns
  `{:error, {:error_max_structured_output_retries, last_validation_error}}`.
- New events: `{:structured_retry, %{attempt:, error:}}` fires on each
  retry.

#### Added — Plan-and-Solve mode

- `ExAthena.Modes.PlanAndSolve` — two-phase mode. First iteration is
  **planning-only** (no tools, plain-text plan following a structured
  prompt). Subsequent iterations delegate to `ReAct`.
- Rationale: smaller / local models produce better tool-calling
  behaviour when they articulate a plan first.

#### Added — Reflexion mode

- `ExAthena.Modes.Reflexion` — after each ReAct iteration, injects a
  short self-critique pass and adds it to the conversation history.
  Capped at 3 reflections (per research — beyond that,
  degeneration-of-thought kicks in).
- Triples per-loop cost; best reserved for correctness-sensitive tasks.

#### Added — subagent supervision upgrade

- `ExAthena.Tools.SpawnAgent` now runs sub-loops under
  `Task.Supervisor.async_nolink` (supervisor name `ExAthena.Tasks`,
  registered by `ExAthena.Application`). Sub-agent crashes no longer
  propagate to the parent; timeouts are enforceable.
- New events: `{:subagent_spawn, %{id:, prompt:}}` and
  `{:subagent_result, %{id:, text:}}` fire around sub-loop execution.
- New optional arg: `timeout_ms` (default 300_000).
- New error subtypes from SpawnAgent: `{:sub_agent_crashed, reason}`,
  `{:sub_agent_timeout, ms}`.

### Tests

- **140 total** (up from 126 in PR 2). 14 new cover compaction
  (threshold detection, middle-replacement, error surfacing), budget
  caps (cost-based termination, `cost_usd` accumulation, nil fallback),
  structured repair loop (retry success, retry exhaustion, retry
  events), Plan-and-Solve (planning turn assertion, execution-phase
  tool use), and Reflexion (reflection cap, history injection).

### PR 2 — Kernel rewrite (**breaking changes**)

**The return type of `ExAthena.Loop.run/2` is now `{:ok, %Result{}}`
instead of the v0.2 `{:ok, map()}`.** Consumers pattern-matching on the
old map shape must update.

#### Added — pluggable Mode behaviour

- `ExAthena.Loop.Mode` — behaviour with `init/1` + `iterate/1`. Drives
  the turn-by-turn control flow. Kernel handles caps, budget, hooks,
  counters, events, and Result construction.
- `ExAthena.Modes.ReAct` — default mode. ReAct cycle (reason → act →
  observe) with parallel tool execution, mistake counter, and typed
  terminations.
- `ExAthena.Modes.PlanAndSolve` + `ExAthena.Modes.Reflexion` — stubs
  returning `:not_implemented`. Full implementations land in PR 3.
- `ExAthena.Loop.Mode.resolve/1` translates atom shortcuts (`:react`,
  `:plan_and_solve`, `:reflexion`) to modules.

#### Added — reliability knobs

- `:max_consecutive_mistakes` (default 3) — trips
  `:error_consecutive_mistakes` after N consecutive tool errors. A
  successful tool call resets the counter. Prevents runaway loops
  (Cline pattern).
- `:max_budget_usd` — trips `:error_max_budget_usd` when the budget
  accumulator crosses the cap. PR 3 wires cost computation from provider
  metadata.
- `:tool_timeout_ms` (default 60_000) — per-call timeout for parallel
  execution.
- `:max_concurrency` (default 4) — `Task.async_stream` concurrency cap.

#### Added — parallel tool execution

- `ExAthena.Loop.Parallel` — classifies a single iteration's tool calls
  into parallel-safe (read-only) and serial (mutating) groups. Runs
  mutating calls first in order, then parallel-safe calls concurrently
  via `Task.async_stream/3`. Result order always matches input call
  order so the model sees aligned results.
- `ExAthena.Tool.parallel_safe?/0` — optional behaviour callback.
  Defaults to `false`.
- Read-only builtins (`Read`, `Glob`, `Grep`, `WebFetch`) declare
  `parallel_safe?: true`. Mutating builtins default to `false`.

#### Changed — event shape (**breaking change**)

v0.2's `%ExAthena.Streaming.Event{type:, data:, index:}` struct is
replaced by flat pattern-matchable tuples modelled on `ash_ai`'s
`ToolLoop.stream/2`:

    {:content, text}
    {:tool_call, ToolCall.t()}
    {:tool_result, ToolResult.t()}
    {:iteration, integer()}
    {:usage, usage_map}
    {:error, term()}
    {:done, Result.t()}

Consumers subscribing via `:on_event` need to update their handlers.
OTel span emission in PR 4 consumes the same tuples.

#### Changed — error handling

Tool errors use the `is_error: true` tool-result convention (Cline
pattern). The model sees its mistake and self-corrects; the mistake
counter advances; a streak hits the cap.

Unknown tools + parse failures flow as error tool-results rather than
halting the run. Hook-driven halts produce `:error_halted`. Provider
errors produce `:error_during_execution`.

#### Tests

126 total (up from 116 in PR 1). 10 new cover Result shape, termination
subtypes, max_iterations → `:error_max_turns`, mistake counter + reset,
parallel tool ordering, flat event tuples, Mode resolve/1.

### PR 1 — Foundation (already landed, unchanged)
PR 1 lays the foundation: canonical types, typed terminations, budget
accounting, and a single req_llm-backed provider adapter that replaces the
three hand-written provider modules.

### Added — Result, Terminations, Budget

- `ExAthena.Result` — canonical run outcome struct. Every run (success or
  error) returns a `%Result{}` carrying final text, message history,
  finish_reason, iterations, tool_calls_made, aggregated usage, cost in
  USD, duration, model, provider, and telemetry metadata. Replaces the
  loose map v0.2 returned.
- `ExAthena.Loop.Terminations` — typed finish_reason subtypes inspired by
  the Claude Agent SDK. Each run ends with exactly one of:
  `:stop`, `:error_max_turns`, `:error_max_budget_usd`,
  `:error_during_execution`, `:error_max_structured_output_retries`,
  `:error_consecutive_mistakes`, `:error_halted`, `:error_compaction_failed`.
  `Terminations.category/1` classifies each as `:success | :retryable |
  :capacity | :fatal` for retry-decision logic.
- `ExAthena.Budget` — usage + cost accumulator. Aggregates token usage
  across iterations, computes cost from provider metadata (req_llm +
  models.dev), and supports `:max_budget_usd` caps.

### Added — req_llm provider adapter

- `ExAthena.Providers.ReqLLM` — single adapter that delegates to
  `req_llm`'s 18+ providers (OpenAI, Anthropic, Ollama, OpenRouter, Groq,
  Together, DeepInfra, Vercel, LM Studio, vLLM, llama.cpp, Mistral, Gemini,
  Cohere, Bedrock, …). Model names resolve through the `models.dev`
  registry for cost + context-window metadata.
- `ExAthena.Config.pop_provider!/1` now threads a `req_llm_provider_tag`
  key through opts so bare `model: "llama3.1"` + `provider: :ollama`
  auto-expands to the full `"ollama:llama3.1"` spec req_llm expects.
- `Config.req_llm_provider_tag/1` — translate an ExAthena provider atom
  into the req_llm `"tag:model-id"` prefix.

### Removed — hand-written provider modules

- `ExAthena.Providers.Ollama`
- `ExAthena.Providers.OpenAICompatible`
- `ExAthena.Providers.Claude`
  All three were direct HTTP clients (Ollama + OpenAICompatible) or SDK
  wrappers (Claude). req_llm does this work across more providers and
  maintains the catalogs. The provider atoms `:ollama`, `:openai`,
  `:openai_compatible`, `:llamacpp`, `:claude`, `:anthropic` continue to
  work — they now all resolve to `ExAthena.Providers.ReqLLM`.

### Added — dep

- `{:req_llm, "~> 1.10"}`.

### Breaking change — none yet (visible)

Consumer-visible API unchanged in this PR. Every existing call
(`ExAthena.query/2`, `ExAthena.stream/3`, `ExAthena.Loop.run/2`,
`ExAthena.Session.start_link/1`) works identically. The provider-module
change is internal.

Breaking API changes land in PR 2 (Kernel) alongside the new Mode
behaviour and the new stream event shape.

### Tests

- 116 tests passing (up from 91 baseline). 25 new covering Terminations,
  Result, Budget, and the req_llm adapter routing.

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
`ExAthena.extract_structured/2` (JSON-schema-validated output).

### Phase 3+ roadmap

Migrate `udin_code` off the `claude_code` direct dep: route every call through
`ExAthena.*`, delete `UdinCode.Claude.GenericRunner`, make picking `:ollama`
in the ModelProvider UI actually run the whole task lifecycle on Ollama.
