# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and ExAthena adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.4.6 — Weak-model reliability: raw-JSON tool calls, compact schemas, strict structured output

### Added — `ExAthena.ToolCalls.RawJson` (ADR 0001)

- Third tool-call extraction tier behind `Native` and `TextTagged`.
  Recognises bare and ` ```json ` -fenced JSON objects with a
  `name` / `arguments` shape using a balanced-brace scanner that tracks
  in-string state and backslash escapes. Wired into
  `ToolCalls.extract/2` as the final fallback so weak open-weight
  models (e.g. `qwen2.5-coder:14b` on Ollama) that emit tool calls as
  bare JSON in assistant prose are no longer silently dropped.
- A cheap pre-check requires both `"name"` and `"arguments"`
  substrings before the scanner runs, so non-tool prose is rejected in
  O(n) without engaging the brace walker.

### Added — per-request capability override (ADR 0001)

- `ExAthena.Loop.run/2` now accepts a `:capabilities` opt that is
  merged on top of `provider_mod.capabilities()` for the duration of
  the run. Lets callers flip `native_tool_calls: false` for a single
  request to force `Modes.ReAct` into fence-augmented prompting, with
  no provider-module fork required. The merge is shallow and
  forward-compatible: future capability flags slot in the same way.

### Added — compact tool-schema mode (ADR 0002)

- `ExAthena.ToolCalls.augment_system_prompt/3` (was `/2`) takes a new
  `compact: true` opt that emits one type-signature line per tool
  instead of dumping the full JSON schema, e.g.
  `- read_file(path: string, content?: string) — read a file`.
  Required vs optional marked with `?`; types compacted to
  `string|number|integer|boolean|array|object|null`; scalar arrays
  rendered as `T[]`; nested object structure collapsed past depth 2;
  description truncated to first sentence and capped near 80 chars.
- Default behaviour is byte-identical — `compact: true` is opt-in and
  the existing 2-arity call sites still work unchanged.
- New static capability `compact_tool_schemas: true` on
  `ExAthena.Providers.ReqLLM.capabilities/0` so downstream callers can
  gate per-model heuristics on it (e.g. AthenaRunner deciding to flip
  on `compact: true` only for known-weak Ollama model ids).

### Why (ADRs 0001 + 0002)

Weak Ollama models such as `qwen2.5-coder:14b` show measurable quality
degradation past ~4 KB of system prompt and don't reliably honour the
`~~~tool_call` fence when given a 5–10 KB schema dump from
`augment_system_prompt/2`. Together the two changes mean: (a) tool
calls those models *do* emit (often as bare JSON) are now caught by
`RawJson`, and (b) the prompt budget those models see drops by ~80%
on a 10-tool fixture, raising fence compliance. Strong hosted models
(Claude, GPT-4) are unaffected — they still receive tools structurally
via native `tool_calls`. Unblocks `udin-io/udin_code#1268`.

### Added — strict structured-output pass-through (ADR 0003)

- `ExAthena.Providers.ReqLLM.build_opts/2` now forwards
  `response_format` to req_llm, preferring `opts[:response_format]`
  over `request.response_format`. Accepts `:json`, `"json"`, and
  JSON-schema maps verbatim — req_llm normalises before hitting the
  Ollama / OpenAI / etc. backend.
- New `:structured_output` capability key on
  `ExAthena.Capabilities` typespec; `Providers.ReqLLM.capabilities/0`
  declares `structured_output: true`.
- New module `ExAthena.StructuredOutput` with `request/3`. Strict
  one-shot variant: requires the resolved provider (after merging the
  per-request `:capabilities` override from ADR 0001) to declare
  `:structured_output`. Returns `{:ok, decoded_map}` on success,
  `{:error, :no_structured_output}` when the capability is absent,
  `{:error, :invalid_json}` on decode failure, and passes provider
  errors through.
- The existing `ExAthena.Structured.extract/2` retry/repair flavour is
  unchanged. The two helpers coexist by design — `Structured.extract/2`
  for best-effort retry-with-validation, `StructuredOutput.request/3`
  for the strict provider-enforced contract.

### Why (ADR 0003)

Downstream `udin_code` flows that need schema-conforming JSON (scope
decisions, ExitPlanMode-style phase-end signals) currently rely on
brittle text extraction because weaker open-weight models don't emit
structured `tool_calls`. Now those flows can request provider-enforced
JSON when the resolved provider supports it, and get a loud
`:no_structured_output` error otherwise — never a silent text-parse
fallback.

## v0.4.5 — Stream heartbeat + time-to-first-token (TTFT)

### Added

- `ExAthena.Providers.ReqLLM.consume_stream/3` now emits a heartbeat
  log every 10 s while no chunk has arrived yet, and a one-time
  TTFT line on the first content/tool_call chunk:
  - `[ExAthena.ReqLLM] ⋯ waiting on stream (Ns elapsed)` (info,
    repeats every 10 s during the prompt-processing phase, stops
    automatically once chunks start flowing).
  - `[ExAthena.ReqLLM] ←first_chunk after Yms (TTFT)` (info, fires
    exactly once per stream).

### Why

Local Ollama / llama.cpp on a 14 B+ model regularly spends 30–120 s
processing the prompt before emitting the first chunk. Until 0.4.5
nothing surfaced on the wire during that wait — callers had no way
to distinguish "slow but alive" from "stalled and silent". The
heartbeat closes that gap with a single info-level line every 10 s,
and the TTFT log captures the latency once tokens start flowing so
operators can compare cold vs. warm runs. The heartbeat process
exits as soon as the reduce returns (success or crash) via
`try/after`, and self-checks `Process.alive?(parent)` before
emitting in case the calling process was killed mid-stream.

## v0.4.4 — Adapter-boundary message logging (Claude Code-style)

### Added

- `ExAthena.Providers.ReqLLM` now emits structured Logger messages at
  the adapter boundary, mirroring the Claude Code SDK's `[SDK]` log
  style for parity with consumers that already grep for that prefix:
  - `[ExAthena.ReqLLM] →query|→stream model=… msgs=N tools=K base_url=… backend=…`
    (info level, one line per request).
  - `[ExAthena.ReqLLM] →query system_prompt=…\n  msg[i] role: <preview>`
    (debug level, full message body previews with whitespace collapsed
    and capped at 200B/message).
  - `[ExAthena.ReqLLM] ←text_delta NB: <preview>` per streamed chunk
    (debug level).
  - `[ExAthena.ReqLLM] ←tool_call name=… args=…` per tool call
    (debug level).
  - `[ExAthena.ReqLLM] ←meta finish_reason=…` and `←usage …`
    (debug level).
  - `[ExAthena.ReqLLM] ←done finish_reason=… text_chars=N tool_calls=K usage=…`
    on completion (info level).
  - `[ExAthena.ReqLLM] ←error …` when req_llm returns an error
    (warning level).
- All debug-level lines wrap their message construction in
  `Logger.debug(fn -> … end)` so log assembly is skipped at higher
  log levels — zero overhead in production.

### Why

Until 0.4.4 the adapter forwarded request/response data to req_llm
without leaving any breadcrumb in the host application's log. When a
streaming run stalled or the LLM returned unexpected content, callers
had no way to see what was sent or what came back without attaching a
telemetry handler. The new lines give the same kind of visibility
ClaudeCode's SDK provides, so debugging Ollama/OpenAI/llama.cpp flows
is a `tail -f phoenix_output.log | grep '\[ExAthena.ReqLLM\]'` away.

## v0.4.3 — Convert tools to %ReqLLM.Tool{} structs at the adapter boundary

### Fixed

- `ExAthena.Providers.ReqLLM.build_opts/2` now converts the modes' tool
  list (OpenAI-format maps from `Tools.describe_for_provider/1`) into
  `%ReqLLM.Tool{}` structs before forwarding to req_llm. Without this,
  req_llm 1.10's openai adapter raised
  `no function clause matching in ReqLLM.Tool.to_schema/2` while building
  the streaming request — `to_schema/2` only matches `%ReqLLM.Tool{}`.
  The conversion sets a stub callback because ex_athena executes tools
  server-side via the loop, not via req_llm's client-side dispatch.
  Already-formed `%ReqLLM.Tool{}` structs and string-keyed maps are
  passed through unchanged for forward compatibility.

## v0.4.2 — Ollama tagged model spec follow-up

### Fixed

- `ExAthena.Providers.ReqLLM.resolve_model/2` no longer skips the
  provider-tag prefix when the model id contains a colon. Ollama model
  ids legitimately use `:` as the version separator
  (`qwen2.5-coder:14b`, `qwen3-coder:30b`), so the previous "model
  contains `:` ⇒ already tagged" heuristic shipped bare names like
  `"qwen2.5-coder:14b"` to req_llm, which then split on the first
  colon and tried to validate `"qwen2.5-coder"` as a provider name —
  failing the `^[a-z0-9_-]+$` regex (rejects `.`) with
  `{:error, :bad_provider}`. Now always prepends the tag unless the
  model already starts with `"<tag>:"` (caller passed a fully-formed
  spec).

## v0.4.1 — Ollama via OpenAI-compatible adapter

### Fixed

- `provider: :ollama` now talks to local Ollama through `req_llm`'s OpenAI
  adapter instead of looking up an `:ollama` provider in `llm_db`'s
  catalog. `llm_db` 2026.4.x removed first-class local-Ollama support
  (it only catalogues `:ollama_cloud` now), so `"ollama:<model>"` model
  specs were rejected with `{:error, :unknown_provider}` from
  `LLMDB.Spec`. The fix routes `:ollama` (and `:llamacpp`) through the
  `"openai:<model>"` tag and threads
  `openai_compatible_backend: :ollama` so `req_llm` 1.10's openai
  adapter tolerates the missing API key on unauthenticated local
  deployments. Mirrors the recipe in `req_llm/guides/ollama.md`.
- `base_url` for Ollama now auto-appends `/v1` when callers pass the
  bare host (`http://localhost:11434`) — req_llm's openai adapter
  expects the prefix to already include `/v1`.
- A placeholder `api_key` (`"ollama"`) is substituted when the
  `:ollama` backend marker is set and no key was supplied — Ollama
  ignores the Authorization header but `req_llm`'s HTTP layer still
  emits one, so a non-nil value is required.

### Internal

- `ExAthena.Config.@req_llm_provider_tag[:ollama]` now resolves to
  `"openai"` (was `"ollama"`).
- New `@local_openai_compatible_backends` map drives
  `openai_compatible_backend` injection in `Config.pop_provider!/1`.
- `ExAthena.Providers.ReqLLM.build_opts/2` reads the backend marker,
  normalises base_url, and falls back to the placeholder api_key.

## v0.4.0 — operational harness (memory, skills, hooks, modes, agents, storage)

The "1.6% reasoning, 98.4% harness" upgrade. Where v0.3 perfected the
loop kernel, v0.4 builds the *operational harness* the [Claude Code paper](https://arxiv.org/abs/2604.14228)
calls out as the bulk of a production agent's value: file-based memory
+ skills, a five-stage compaction pipeline with reactive recovery, a
14-event hook surface with `{:inject, msg}` / `{:transform, prompt}`
returns, two new permission modes, structured tool results, custom
agent definitions with optional git-worktree isolation, and append-only
session storage with file-checkpointing + `/rewind`.

Landed as seven tightly-scoped commits (PR0 → PR5) — each one keeps the
existing test suite passing and adds focused new tests on top.

### PR0 — Foundation

#### Added

- `:session_id` and `:parent_session_id` plumbed through `Loop.State`,
  `Loop.run/2` opts, the resulting `ToolContext`, and the `SessionStart`
  hook payload. The `Session` GenServer auto-generates a stable id at
  start_link, reuses it on every turn, and refuses to let per-call
  `extra_opts` redirect mid-conversation. PR4 + PR5 read these.
- `:error_prompt_too_long` finish-reason in `Loop.Terminations` with
  category `:capacity`. Modes signal context-window-exceeded uniformly;
  PR2's reactive compaction switches on this.
- Doctest in `Permissions.check/4` documenting and locking the
  deny-first ordering (`:disallowed_tools` survives `:bypass_permissions`,
  `:allowed_tools` survives a permissive callback).

### PR1 — Memory + Skills (file-based context)

#### Added — `ExAthena.Memory`

- Loads `AGENTS.md` (preferred) / `CLAUDE.md` from a 3-level hierarchy:
  user (`~/.config/ex_athena/`) → project (`<cwd>/`) → local override
  (`<cwd>/AGENTS.local.md`).
- Each file becomes a single user-role message tagged `name: "memory"`
  placed at the front of the conversation. The Claude Code paper notes
  Claude Code uses user-context (not system) for probabilistic
  compliance — we copy the pattern.
- `AGENTS.md` wins over `CLAUDE.md` at the same level (matches opencode).

#### Added — `ExAthena.Skills`

- Claude Code-style progressive disclosure. `SKILL.md` files have YAML
  frontmatter (`name`, `description`, `disable-model-invocation`,
  `allowed-tools`) plus a markdown body. The frontmatter is auto-injected
  into the system prompt as a `## Available Skills` catalog (~50 tokens
  per skill); bodies stay on disk until needed.
- Two activation paths: a `[skill: name]` sentinel the model writes in
  its response, or the new `:preload_skills` opt for hosts that know
  up-front what's needed.
- Loaded from `~/.config/ex_athena/skills/<name>/SKILL.md` and
  `<cwd>/.exathena/skills/<name>/SKILL.md`. Project overrides user.

#### Added — `Loop.run/2` options

- `:memory` — `:auto` (default), `false`, or explicit message list.
- `:skills` — `:auto` (default), `false`, or explicit map.
- `:preload_skills` — list of skill names to activate up-front.

#### Changed

- `Compactors.Summary` extends its effective pinned-prefix by
  `meta[:memory_count] + meta[:preloaded_skill_count]` so memory + pre-loaded
  skills survive every compaction cycle.

### PR2 — Five-layer compaction pipeline + reactive recovery

#### Added — pipeline architecture

- `ExAthena.Compactor.Pipeline` — the new default compactor. Walks a
  configurable list of `Compactor.Stage` modules cheapest-first, short-
  circuiting once the conversation falls below target. Each stage runs
  inside its own `[:ex_athena, :compaction, <:stage_name>, :start | :stop]`
  telemetry span.
- `ExAthena.Compactor.Stage` behaviour with `compact_stage/2` + `name/0`
  callbacks. Existing `Compactors.Summary` keeps its legacy
  `Compactor.compact/2` callback AND now implements `Stage` via a thin
  adapter — fully backward-compatible for direct callers.

#### Added — five built-in stages

1. **`Compactors.BudgetReduction`** — replaces oversized tool-result
   bodies (>16k chars by default) with a `[truncated; ref=<id>]` pointer.
   Full payload moves to `state.meta[:tool_result_archive]`. Pure-Elixir.
2. **`Compactors.Snip`** — drops stale tool-result bodies older than
   `:snip_age_iterations` whose paired assistant turn already happened,
   replacing each with a `<snipped: stale tool-result for call …>` marker.
3. **`Compactors.Microcompact`** — collapses runs of 3+ adjacent
   tool-result messages into a single elided summary tagged
   `name: "microcompact"`. Pure-Elixir.
4. **`Compactors.ContextCollapse`** — non-destructive view-time
   projection. Detects superseded reads (file later edited) and
   consecutive duplicate tool calls; writes the projection to
   `state.meta[:compact_view]` for the next request to consume. The
   authoritative `state.messages` is never mutated, so resume / replay
   / rewind (PR5) stay correct.
5. **`Compactors.Summary`** — existing LLM summary stage, refactored.

#### Added — reactive recovery

- When a mode returns `{:error, :error_prompt_too_long}` (PR0
  finish-reason), the loop runs the pipeline with `force: true`
  unconditionally and retries the same iteration once. Gated by
  `:reactive_compact` opt (default `true`).

#### Configuration

- `:compaction_pipeline` — host-overridable stage list. Default is
  `[BudgetReduction, Snip, Microcompact, ContextCollapse, Summary]`.

### PR3a — Hooks expansion + permission modes

#### Added — hook events (14 total)

- `Hooks.events/0` exposes the catalog: `SessionStart`, `SessionEnd`,
  `UserPromptSubmit`, `ChatParams`, `Stop`, `StopFailure`, `PreToolUse`,
  `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`,
  `PermissionDenied`, `SubagentStart`, `SubagentStop`, `PreCompact`,
  `PreCompactStage`, `PostCompact`, `Notification`.
- New return values for hook callbacks:
  - `{:inject, message_or_messages}` — append context to the conversation.
    opencode's `experimental.chat.system.transform` pattern.
  - `{:transform, prompt}` — only meaningful from `UserPromptSubmit`;
    rewrites the user prompt before it enters the loop.
- `run_lifecycle_with_outputs/3` returns `%{halt:, injects:, transform:}`
  for callers that need the richer outputs. `run_lifecycle/3` keeps its
  `:ok | {:halt, _}` shape.

#### Newly fired events

- `Stop` / `StopFailure` / `SessionEnd` from `to_result/2`.
- `UserPromptSubmit` from `build_initial_state/2`.
- `ChatParams` from `Modes.ReAct.iterate/1`, just before each provider call.
- `PostToolUseFailure` when a tool returns `{:error, _}`.
- `PermissionDenied` whenever the gate decides `{:deny, _}`.
- `SubagentStart` / `SubagentStop` from `Tools.SpawnAgent`.
- `PreCompactStage` / `PostCompact` from the compaction pipeline.

#### Added — permission modes

- `:accept_edits` — auto-allow Read/Glob/Grep/WebFetch + Edit/Write/TodoWrite
  + plan_mode/spawn_agent. Bash + custom tools still consult `can_use_tool`.
- `:trusted` — skip the `can_use_tool` callback for every tool. Still
  respects the denylist by default; pass `respect_denylist: false` to
  disable that. The `:auto` name is reserved for the future ML safety
  classifier.

`:bypass_permissions` continues to respect the denylist (deny-first
invariant from PR0's doctest is preserved).

### PR3b — Tool-result split (LLM content + UI payload) ⚠️ Breaking

Tools may now return a 3-tuple `{:ok, llm, ui}` in addition to the
existing `{:ok, text}`. The `llm` is the LLM-facing string the model
sees on the next iteration; `ui` is a `%{kind:, payload:}` map hosts
(TUIs, Phoenix LiveView frontends) can render as rich content
(diffs, file previews, process output, match lists) without parsing
the text. This is the Pi-style split adapted to Elixir's pattern-match
idiom.

#### Added

- `Messages.ToolResult` grows `ui_payload :: %{kind:, payload:} | nil`.
- `Loop.Events` adds `{:tool_ui, %{tool_call_id:, kind:, payload:}}`.
- New event emitted after `:tool_result` for any tool result carrying a payload.

#### Built-in payload shapes

- `Read` → `:file` { path, content, line_range }
- `Edit` → `:diff` { path, before, after, replacements }
- `Bash` → `:process` { command, exit_code, stdout, duration_ms }
- `Glob` → `:matches` { pattern, count, items }
- `Grep` → `:matches` { pattern, count, items }
- `WebFetch` → `:webpage` { url, status, truncated? }
- `Write`, `TodoWrite`, `PlanMode` — text-only, unchanged.
- `SpawnAgent` (PR4) → `:subagent` { iterations, cost_usd, isolation, … }

#### Breaking change — direct tool callers

The 6 builtins listed above (`Read`, `Edit`, `Bash`, `Glob`, `Grep`,
`WebFetch`) now return `{:ok, text, ui}` 3-tuples instead of the
`{:ok, text}` 2-tuple. Callers using these tools through the loop are
unaffected — `Result.text` still surfaces the LLM-facing string. Code
that calls these tools' `execute/2` directly needs to update its
pattern matches. The `{:ok, text}` 2-tuple remains a fully supported
return shape for custom and third-party tools.

### PR4 — Subagents v2 (Agents.md + worktrees + sidechains)

#### Added — `ExAthena.Agents`

- File-based agent definitions in markdown + YAML frontmatter, loaded
  from a 3-level hierarchy (builtin → user → project). Frontmatter
  fields: `name`, `description`, `model`, `provider`, `tools`,
  `permissions`, `mode`, `isolation`. Body becomes a system-prompt
  addendum.
- Builtin definitions shipped in `priv/agents/`:
  - `general` — full-tool default (matches the prior SpawnAgent behaviour).
  - `explore` — read-only fast investigation.
  - `plan` — analysis only with writes restricted to `.exathena/plans/`.
- `Agents.apply_to_opts/2` merges definition fields into spawn opts.

#### Added — worktree isolation

- `ExAthena.Agents.Worktree.resolve/3` runs three safety checks before
  creating a git worktree (git on PATH, cwd inside repo, clean tree).
  If any check fails, the subagent transparently falls back to
  `:in_process`.
- Worktrees live under `~/.cache/ex_athena/worktrees/<sess>/<name>-<n>`,
  branched from `HEAD`. After the subagent finishes:
  - Changes left → worktree is kept; path + branch surface in the spawn
    result's `ui_payload` for review/merge.
  - Clean → `git worktree remove --force` cleans up.
- `ExAthena.Agents.WorktreeSweeper` is a one-shot at boot under the
  application supervisor that runs `git worktree prune` and removes
  cache entries older than 7 days.
- All internal git invocations bypass the parent's permission gate via
  `System.cmd/3` directly — otherwise a parent in `:plan` mode could
  never spawn a worktree-isolated subagent.

#### Added — sidechain transcripts

- `ExAthena.Agents.Sidechain.write/1` persists each subagent's full
  transcript to `<cwd>/.exathena/sessions/<parent_session_id>/sidechains/<subagent_id>.jsonl`.
  Parent only sees the subagent's final `text`; the full conversation
  lives here.

#### `SpawnAgent` updates

- New `agent: "<name>"` arg resolves a named definition and applies its
  fields to the sub-loop opts.
- `SubagentStart` payload now includes `:agent` and `:isolation`.
- `SubagentStop` payload includes the finalized isolation state.
- Spawn returns the `{:ok, llm, ui}` 3-tuple from PR3b with a
  `:subagent` UI payload carrying iterations / tool_calls_made /
  cost_usd / duration_ms / isolation.

### PR5 — Append-only session storage + checkpointing + rewind

#### Added — `ExAthena.Sessions.Store`

- Behaviour for append-only event storage with `append/2`, `read/1`,
  `list/0`, `tail/2`. Each event carries an ISO 8601 timestamp + uuid.
- `Sessions.Stores.InMemory` — ETS-backed default. The application
  supervisor keeps a single named GenServer alive so the table is shared
  across the BEAM.
- `Sessions.Stores.Jsonl` — ETS-buffered, periodic flush (default 250ms).
  Hot-path appends never block on I/O. Files at
  `<root>/<session_id>.jsonl`. Synchronous `flush/1` for tests + clean
  shutdown.

#### Session integration

- `Session.start_link/1` accepts `:store` opt: `:in_memory` (default),
  `:jsonl`, or a custom module.
- On every `send_message/2`: emits `:user_message`, then walks
  `result.messages` after the loop and emits `:assistant_message` /
  `:tool_result` for new entries.
- `Session.resume/2` reads events back, filters to user/assistant
  messages, and returns the reconstructed message list. Permissions
  deliberately don't survive resume (Claude Code's pattern: trust is
  re-established per session).

#### Added — `ExAthena.Checkpoint`

- File-history backups before each `Tools.Edit` / `Tools.Write` at
  `<cwd>/.exathena/file-history/<session_id>/<sha>/<version>.bin`.
  SHA-256 of the absolute path; versions are 0-indexed and idempotent.
  Tombstones (`<v>.tombstone`) mark "this file didn't exist at
  checkpoint time".
- `Checkpoint.rewind/3` modes:
  - `:code_and_history` — restore each file to its version-0 snapshot
    AND truncate the JSONL session log to the chosen `to_uuid`.
  - `:history_only` — only truncate the JSONL.
- `ExAthena.Checkpoint.Sweeper` — startup task that GCs file-history
  directories older than 30 days.

### Distribution

- `mix.exs` `:files` now includes `priv/` so the builtin agent
  definitions ship with the package on Hex.

### Tests

- 248 tests + 2 doctests, 0 failures (was 147 + 0 in v0.3.1).
- Backward-compatible by design: existing v0.3 tests untouched, except
  for the 6 builtin tools whose return shape changed (PR3b — tightened
  to `{:ok, text, ui}`).

## v0.3.1 — per-token streaming in the ReAct mode

### Added

- `Modes.ReAct` now dispatches to `provider_mod.stream/3` (instead of
  `query/2`) whenever the caller registered an `on_event` callback on
  `Loop.run/2`. Every `%Streaming.Event{type: :text_delta, data: ...}`
  produced by the provider is forwarded to `on_event` in real time, so
  consumers (e.g. a LiveView chat UI) get character-level deltas again
  without having to drive streaming themselves.
- When no `on_event` is set the behaviour is unchanged — the mode uses
  the cheaper one-shot `query/2` path.
- When the provider module does not implement `stream/3` (it is an
  optional callback) the mode transparently falls back to `query/2`.

### Changed

- Docstring on `Modes.ReAct` now reflects the stream/query dispatch.

## v0.3.0 — PR 4 (observability) landed; Phase 4 closed

### PR 4 — Observability

#### Added — OpenTelemetry GenAI semconv telemetry

- `ExAthena.Telemetry` — emits `:telemetry`-library events shaped to the
  OpenTelemetry GenAI semantic conventions. Consumers bridge to OTel
  via `opentelemetry_telemetry` (no direct OTel dep). Events:
  - `[:ex_athena, :loop, :start | :stop | :exception]`
  - `[:ex_athena, :chat, :start | :stop]`
  - `[:ex_athena, :tool, :start | :stop]`
  - `[:ex_athena, :compaction, :stop]`
  - `[:ex_athena, :subagent, :spawn | :stop]`
  - `[:ex_athena, :structured_retry]`
- GenAI semconv metadata keys: `gen_ai_operation_name`,
  `gen_ai_provider_name`, `gen_ai_request_model`, `gen_ai_agent_id`,
  `gen_ai_conversation_id`, `gen_ai_tool_name`, `gen_ai_tool_call_id`,
  `gen_ai_usage_input_tokens`, `gen_ai_usage_output_tokens`,
  `gen_ai_response_finish_reasons`.
- New `:conversation_id` / `:agent_id` opts on `Loop.run/2` — threaded
  into every emitted event's metadata so OTel traces can stitch across
  turns.
- `Telemetry.span/3` helper wraps arbitrary work in a start/stop pair
  with duration measurement + exception re-raising.

#### Released

- Version bump `0.3.0-dev` → `0.3.0`. Ready for Hex publish.

## v0.3.0-dev — PR 3 landed

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
