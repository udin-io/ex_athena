# ADR: MCP Server Config Loading and Lifecycle Supervision

## Status

Proposed

## Context

`ExAthena.Mcp.Client` already implements the per-server MCP JSON-RPC client (stdio + HTTP transports, `initialize`, `tools/list`, `tools/call`). It does not, however, define how multiple MCP servers are configured, started, supervised, or queried at the library level. udin_code (which embeds ex_athena) needs to pass an OpenCode-shaped JSONC config and have ex_athena bring up one client per enabled server, perform the initialize + tools/list handshake, cache the discovered tools, and survive transient client crashes.

A later sub-ticket will surface MCP-discovered tools through `ExAthena.Tools` into the loop. This ADR is scoped to the config + lifecycle + read-only catalog APIs only.

## Decision

1. **Config schema** mirrors OpenCode's JSONC shape: a map keyed by server name, with each entry declaring `type` (`:local` | `:remote`), transport-specific fields (`command`/`environment` or `url`/`headers`), and an `enabled` flag. A new `ExAthena.Mcp.Config` module loads from `Application.get_env(:ex_athena, :mcp_servers, %{})`, validates with NimbleOptions per shape, accepts both string and atom keys, and emits `%ExAthena.Mcp.Config.Server{}` structs.

2. **Lifecycle layer** introduces three modules under `ExAthena.Mcp`:
   - `Registry` — a `Registry` (unique keys) for name→pid resolution.
   - `Server` — a GenServer per configured server. It links the underlying `Mcp.Client`, runs `initialize` + `tools/list` once at boot in a `:boot` `handle_info` (so `init/1` returns immediately), caches the tool list in state, and exposes `:list_tools` / `:info` calls.
   - `Supervisor` — `:one_for_one`, supervises the Registry plus one `Server` per `enabled: true` entry. Each `Server` is `restart: :transient` with `max_restarts: 3, max_seconds: 60`. Empty config → `:ignore`.

3. **Read APIs** are added to the existing `ExAthena.Mcp` facade:
   - `list_servers/0` — metadata for every configured server, including disabled ones.
   - `list_tools/1` (by **server name**) — returns cached tools, distinct arity from the existing client-pid `list_tools/2`, so no signature collision.

4. **Application wiring** appends `ExAthena.Mcp.Supervisor` to `ExAthena.Application` children, gated by `Application.get_env(:ex_athena, :enable_mcp, true)`. `config/test.exs` sets the gate to `false` to keep existing tests hermetic; per-test setups opt in.

5. **Out of scope** (covered by sub-ticket 3): wiring MCP-discovered tools into `ExAthena.Tools` / the loop, dynamic config reload, hot-add of servers at runtime.

## Consequences

**Positive**

- Reuses the existing `Mcp.Client` GenServer end-to-end; no duplication.
- Bounded `:transient` restarts let transient client crashes self-heal while a permanently misconfigured server becomes visible (`status: :degraded`) instead of crash-looping the supervisor.
- The facade's existing client-pid APIs remain available for callers that already have a pid (e.g., direct usage in tests), avoiding a breaking change.
- Mirroring OpenCode's shape means udin_code can map its JSONC config directly without bespoke translation.

**Negative / trade-offs**

- Tools are cached at boot only; a server that adds tools later won't reflect them until restarted (acceptable per spec — `tools/list_changed` notifications are out of scope).
- Caching in GenServer state rather than ETS means reads go through `GenServer.call`. This is fine at expected read volume (per-loop catalog reads); revisit only if the loop hot-paths it.
- Two `list_tools` arities on the facade (server name vs client pid) require care from readers; addressed by keeping them at distinct arities and documenting clearly.

**Neutral**

- Adds a `Registry` to the application — minimal cost, idiomatic for named per-name child processes.
