# ADR 1: Unified `ExAthena.Tool.Spec` for built-in and MCP tools

## Status

Proposed

## Context

Before this change, the loop's tool catalog is `[module()]` — every tool must be a module implementing the `ExAthena.Tool` behaviour with 0-arity callbacks `name/0`, `description/0`, `schema/0`. `Tools.find/2` resolves by `mod.name() == name` and the React-mode dispatcher in `lib/ex_athena/modes/react.ex` calls `mod.execute(args, ctx)`.

MCP tools are dynamic *data*, discovered at runtime from `Mcp.list_servers/0` + `Mcp.list_tools/1` as `%{name, description, input_schema}` maps backed by a server pid. They cannot be expressed as modules without runtime metaprogramming, and even then the 0-arity callbacks make per-instance identity awkward (every MCP tool would need a synthetic module).

We need a representation that supports both (a) compile-time module tools and (b) data-driven MCP tools, without forking the dispatch path or duplicating each catalog helper (`describe_for_provider/1`, `describe_for_prompt/1`, `find/2`, `validate!/1`).

## Decision

Introduce a single canonical struct, `%ExAthena.Tool.Spec{}`, with fields:

```
name            :: String.t()                # namespaced for MCP: "<server>_<tool>"
description     :: String.t()
schema          :: map()
parallel_safe?  :: boolean()
kind            :: :module | :mcp
module          :: module() | nil
mcp_server      :: String.t() | nil
mcp_tool_name   :: String.t() | nil          # original (un-namespaced) MCP tool name
```

Constructors:

- `Tool.Spec.from_module/1` lifts the four behaviour callbacks into the struct.
- `Tool.Spec.from_mcp/2` builds an MCP spec, prefixing the name and retaining the original.

Dispatcher:

- `Tool.Spec.execute(spec, args, ctx)` routes `:module` -> `mod.execute/2` and `:mcp` -> `ExAthena.Mcp.Tool.execute/3`.

`ExAthena.Tools.resolve/1` becomes the single seam that converts the user's `[module()]` list into specs and appends MCP-derived specs from `ExAthena.Mcp.tool_specs/1` when the supervisor is running. All other call sites — `Tools.find/2`, `describe_for_provider/1`, `describe_for_prompt/1`, `Parallel.classify/2`, the React-mode dispatcher — are migrated to consume specs.

MCP tool names are namespaced `<server>_<tool>` at spec-construction time, so the existing `Permissions` exact-string matching, the existing `Hooks` payload (which already keys on `call.name`), and the provider wire format all work without further changes.

## Consequences

### Positive

- One dispatch path covers both kinds; future tool sources (e.g. WASM plugins, OpenAPI imports) only need a new `Tool.Spec.from_*` constructor and an executor module.
- Permissions and hooks gain MCP support for free — no special-casing for `mcp__` prefixes anywhere in the codebase.
- The public `tools:` option on `Loop.run/2` is unchanged; consumers who don't use MCP see no difference.
- Schema validation, telemetry, and parallel-safety classification are uniform across kinds.

### Negative

- Internal API churn: every caller of `Tools.find/2` and `Tools.describe_for_provider/1` switches from `module()` to `Tool.Spec.t()`. Mechanical, but spans `loop.ex`, `react.ex`, `parallel.ex`, and their tests.
- A spec is heavier than a bare module reference (struct allocation per resolve), but the catalog is small (typically <= 30 entries).
- Tool name collisions across MCP servers are still possible if two servers expose the same suffix — namespacing only protects against built-in vs MCP collisions, not server vs server. Acceptable for v1; documentable.

### Alternatives considered

- *Generate a module per MCP tool at runtime via `Module.create/3`*: works, but pollutes the module table, complicates hot-reload, and doesn't compose with `parallel_safe?/0`-style 0-arity callbacks for per-instance state.
- *Keep two parallel lists (`tool_modules` + `mcp_tools`) and dispatch via cond*: doubles every catalog helper and every dispatch site; no win over a unified spec.
