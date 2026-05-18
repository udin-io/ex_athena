# ADR 1: Structured Tool Denial via `ExAthena.Permissions.Denial`

**Status:** Accepted

## Context

`Permissions.check/3` returns `{:deny, raw_tuple}` where the tuple is one of `{:disallowed, name}`, `{:not_in_allowlist, name}`, `{:mutation_in_plan_mode, name}`, `:denied_by_callback`, or `{:unexpected_callback_result, other}`. The `ReAct` mode formats this as `"permission denied: #{inspect(reason)}"` in the tool result, and `fire_permission_denied` in `parallel.ex` passes the raw term into the `:PermissionDenied` hook payload.

Consumers (e.g. `udin_code`) want to react programmatically to denial causes:
- Phase-gated denial → inject a phase-aware whitelist hint into the next system message
- Budget denial → switch to a cheaper model
- Sandbox violation → suggest a different working directory

Grepping the reason string is brittle and inverts the dependency. Consumers should receive a typed struct they can pattern-match on.

## Decision

1. **Introduce `ExAthena.Permissions.Denial`** as a nested module in `lib/ex_athena/permissions.ex`. The struct has three fields:
   - `reason :: String.t()` — human-readable message (backwards-compat; `String.Chars` impl returns this)
   - `code :: :phase_gated | :budget_exceeded | :user_denied | :sandbox_violation | :unknown` — machine-readable cause code
   - `metadata :: map()` — structured context (e.g. `%{phase: :plan, allowed_tools: [...], requested_tool: "bash"}`)

2. **Update all `{:deny, ...}` returns in `Permissions.check/3`** to return `{:deny, %Denial{}}`. Mapping:
   - `{:disallowed, name}` → `code: :user_denied`, metadata includes `requested_tool`
   - `{:not_in_allowlist, name}` → `code: :user_denied`, metadata includes `requested_tool` and `allowed_tools`
   - `{:mutation_in_plan_mode, name}` → `code: :phase_gated`, metadata includes `phase: :plan`, `allowed_tools`, `requested_tool`
   - Callback `:deny` → `code: :user_denied`
   - Callback `{:deny, reason}` passthrough → `code: :user_denied`, raw reason in metadata
   - Unexpected callback return → `code: :unknown`

3. **Add `:ToolDenied` to the hooks event catalog** in `lib/ex_athena/hooks.ex`. This follows the existing PascalCase naming convention for hook events.

4. **Emit `:ToolDenied`** from `fire_permission_denied` in `lib/ex_athena/loop/parallel.ex` when the denial reason is a `%Denial{}` struct. The existing `:PermissionDenied` event continues to fire for backwards compatibility. Raw hook denials (from `PreToolUse`) fire `:PermissionDenied` only.

5. **Update `react.ex`** to pattern-match on `%Permissions.Denial{reason: reason_str}` first, using `reason_str` directly as the tool result content. Raw (hook-based) denials fall through to the existing `inspect/1` path.

6. **`String.Chars` implementation** on `Denial` returns `denial.reason`, so existing callers using `to_string/1` continue to work without changes.

## Consequences

**Positive:**
- Consumers can subscribe to `:ToolDenied` and receive a typed struct for programmatic handling
- `denial.code` enables switching on cause without string-parsing
- `denial.metadata.allowed_tools` enables injecting whitelist hints
- Tool result content is a clean sentence, not an `inspect`-formatted tuple
- Backwards compat: `to_string(denial)` == `denial.reason` for string-based callers

**Negative / Trade-offs:**
- `:PermissionDenied` hook payload `reason` field now holds a `%Denial{}` struct instead of a raw tuple — existing hook subscribers that pattern-matched on `{:disallowed, name}` etc. will need updating. This is intentional (those callers were the brittle ones).
- `normalize/1` in `Permissions` now wraps callback pass-through `{:deny, reason}` terms inside `%Denial{}`, which slightly changes the shape for `can_use_tool` callbacks that return custom denial reasons. The original term is preserved in `metadata.raw`.
