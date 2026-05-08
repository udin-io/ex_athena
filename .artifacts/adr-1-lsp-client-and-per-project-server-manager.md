# ADR 1: ExAthena.Lsp client and per-project server manager

## Status

Proposed (sub-ticket 1 of 3 for parent issue #27).

## Context

ex_athena agents read code as bytes via `Read`/`Grep`/`Edit`. They have no
way to ask "where is this symbol defined?" or "what diagnostics does the
compiler emit for this file?" The Language Server Protocol (LSP) is the
standard mechanism — every modern IDE and every modern coding agent
(Cursor, Codex, Copilot, OpenCode) plumbs it.

The parent ticket decomposes into three sub-tickets:

1. JSON-RPC client + per-project server manager (this ADR)
2. `ExAthena.Tools.Lsp` exposing `definition`/`references`/`diagnostics`/`hover`
3. `:PostToolUse` hook that surfaces diagnostics after `Edit`/`Write`

This ADR covers the foundation only. The next two sub-tickets will
consume — but not modify — the surface defined here.

## Decision

### Layered design

Three pure-Elixir modules plus a small supervision subtree:

- `ExAthena.Lsp.Framing` (pure) — `parse/1` over `Content-Length`-prefixed
  LSP frames. Returns `{decoded_messages, leftover_buffer}` so the client
  can accumulate partial frames across `{port, {:data, _}}` messages.
- `ExAthena.Lsp.ServerRegistry` (pure) — extension → language atom;
  language → `%{binary, args}` spawn spec resolved via
  `System.find_executable/1`. App-env override: `{:ex_athena, :lsp_servers}`.
- `ExAthena.Lsp.Client` (`GenServer`) — wraps an stdio `Port`, runs the
  `initialize`/`initialized` handshake in `handle_continue/2`, multiplexes
  concurrent `request/4` calls via an `id => GenServer.from()` map,
  dispatches notifications, and runs the `shutdown`/`exit` handshake on
  `terminate/2`.
- `ExAthena.Lsp.Manager` (`GenServer`) — public façade. Lazily spawns one
  client per `(project_root, language)`, looking up via a `Registry`.
- `ExAthena.Lsp.Supervisor` (`Supervisor`, `:rest_for_one`) — owns the
  `Registry`, the `DynamicSupervisor` for clients, and the Manager.
  Mounted under `ExAthena.Supervisor` behind a `:enable_lsp` flag.

### Choice of `Registry` vs Manager-held map

The `Registry` is the source of truth for "is `(root, lang)` running?".
Clients register under `{:via, Registry, {ExAthena.Lsp.Registry, {root,
lang}}}`. This sidesteps a class of races where a client crashes and the
Manager's local map disagrees with reality. Manager keeps only a small
`%{monitor_ref => {root, lang}}` for telemetry on `:DOWN`.

### Choice of `DynamicSupervisor` for clients

Clients are restartable. `max_restarts: 3, max_seconds: 60` so a busted
binary doesn't thrash. Each client is supervised independently — one
project's broken `pyright` does not take down another project's working
`elixir-ls`.

### Concurrency model in Client

A single GenServer owns the Port. Multiple callers can `request/4`
concurrently because each `GenServer.call` blocks its own caller while the
GenServer dispatches replies asynchronously as JSON-RPC frames arrive.
This avoids the complexity of a separate reader process.

### Telemetry

- `[:ex_athena, :lsp, :spawn]` (discrete event) with metadata
  `%{language, root, binary, pid, phase ∈ {:started, :stopped, :crashed}}`.
- `[:ex_athena, :lsp, :request, :start | :stop | :exception]` via
  `ExAthena.Telemetry.span/3` with metadata `%{method, language, root}`.

This matches the existing `[:ex_athena, :tool, :start | :stop]` and
`[:ex_athena, :chat, :start | :stop]` shape, so OTel consumers wire it up
automatically.

### Missing-binary handling

If `System.find_executable/1` returns `nil`, `spawn_spec/1` returns
`{:error, :unsupported}` and the Manager surfaces `{:error, {:no_server,
lang}}` to callers. The Manager never crashes the supervision tree because
the user lacks `pyright`. Sibling 2 will translate this into actionable
tool-result text ("install pyright to use the lsp tool on Python files").

### Out of scope for this ADR

- The user-visible `lsp` tool — sibling 2.
- The `:PostToolUse` diagnostics-injection hook — sibling 3.
- Permission-mode integration (read-only signal under `:plan` mode) — lives
  with the tool in sibling 2, since the tool is the boundary.
- Workspace-wide symbol search, code actions, rename — parent v1 cuts.

## Consequences

**Positive:**

- A clean, restartable, observable LSP layer that siblings 2 and 3 can
  call without further infrastructure work.
- Pure-module split (`Framing`, `ServerRegistry`) makes the bulk of the
  test surface fast and deterministic.
- `Registry` + via-tuples eliminate a class of "manager state disagrees
  with reality" bugs.
- Existing telemetry conventions are preserved end-to-end.

**Negative / trade-offs:**

- A user without any LSP server installed sees `{:error, {:no_server, _}}`
  errors when sibling 2 lands. Mitigation: sibling 2's tool result will
  carry installation hints.
- Stderr from servers goes to the BEAM tty in v1 (we don't split it). If
  a shipped server proves chatty in practice we'll wrap it in a small `sh
  -c` redirect shim. Documented in the moduledoc.
- One Port per `(root, language)` — fine for the few-projects case, but
  long-running ex_athena processes could accumulate clients. Sibling 2 or
  a future ticket may add idle eviction; out of scope here.

**Neutral:**

- No new dependencies. `Jason`, `:telemetry`, `Registry`, and
  `DynamicSupervisor` are already in the project.
