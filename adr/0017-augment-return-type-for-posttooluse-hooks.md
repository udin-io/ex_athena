# ADR 1: `{:augment, text}` return type for PostToolUse hooks

**Status:** Accepted

## Context

The parent ticket calls for an implicit-diagnostic signal: after an `Edit`/`Write`, the model should automatically see compiler diagnostics for the modified file in the next turn, without having to call the LSP tool explicitly. Sub-tickets 1 and 2 shipped the LSP plumbing and an explicit tool. This sub-ticket needs a way for a built-in `PostToolUse` hook to push diagnostic text into the `tool` message that the LLM will read on the next turn.

Three options were considered:

1. **Append a separate synthetic message** (e.g. a system or assistant message immediately after the tool result). Adds a second message per edit, breaks the 1:1 mapping between tool call and tool result, and complicates conversation rendering.
2. **Bypass the hook system entirely** with a dedicated post-edit step in React mode. Conflicts with the parent plan's framing as "a `:PostToolUse` matcher", and prevents users from implementing similar augmentations themselves.
3. **Extend the hook system to allow result augmentation.** Generic; one mechanism serves both the built-in implicit-diagnostics feature and any future user hook that wants to add context to a tool result. Backward-compatible — adding a new return type doesn't change semantics for hooks that currently return `:ok` or `{:halt, _}`.

## Decision

1. Extend `ExAthena.Hooks.run_post_tool_use/4` to accept a new return value `{:augment, String.t()}` from hook callbacks. Multiple augmenting hooks accumulate by joining with `"\n"` in registration order. `{:halt, _}` still short-circuits. `:deny` is still ignored. `:ok` and unrecognised returns map to no-op.
2. Update `ExAthena.Modes.ReAct.after_post_hook/3` to apply the augment by rewriting `result.content` (`result.content <> "\n\n" <> extra`). `is_error`, `tool_call_id`, and `ui_payload` pass through unchanged so telemetry, error tracking, and host UI rendering aren't disturbed.
3. Extend the PostToolUse payload to `%{result: result, arguments: call.arguments, cwd: state.ctx.cwd, tool_name: call.name}`. Adding keys only — backward-compatible with existing hooks that pattern-match on `result`.
4. Implement the implicit-diagnostics hook as `ExAthena.Lsp.ImplicitDiagnostics.post_tool_use_hook/2` and register it by default in `Loop.start` via `ImplicitDiagnostics.maybe_merge/1`, gated on `:lsp_implicit_diagnostics_enabled`. Prepend (not append) so user-supplied PostToolUse hooks observe the un-augmented `result`.

## Consequences

**Positive:**
- Single message per tool call — no extra synthetic messages cluttering the conversation.
- The augment mechanism is reusable: user hooks can attach context (e.g. lint output, build status) to any tool result.
- LSP diagnostics flow through the same telemetry, error path, and UI hooks as any other tool result.
- Backward-compatible: existing PostToolUse hooks returning `:ok | {:halt, _}` keep working unchanged.

**Negative:**
- The `Hooks` return-type contract grows by one variant; documentation in `guides/hooks_reference.md` will need a short addition.
- A misbehaving augment hook can bloat tool result content; partially mitigated by the severity filter and by `safe_call/3` capturing exceptions.
- The `cwd` and `arguments` fields in the PostToolUse payload are technically a contract change — hooks that pattern-match exhaustively on the payload map could regress (none in the tree do).
