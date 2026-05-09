# ADR: `ExAthena.Tools.Lsp` action dispatch and read-only classification

## Status

Proposed

## Context

Sub-ticket 1 of the LSP feature shipped the JSON-RPC client and per-`{root, language}` manager. We now need to expose four LSP capabilities to the model — `definition`, `references`, `hover`, and `diagnostics`. Several design questions surface:

1. **Tool granularity.** One tool with an `action` argument, or four separate tools (`lsp_definition`, `lsp_references`, …)?
2. **Permission classification.** LSP queries are read-only on the LSP wire (no `workspace/applyEdit`), but the tool does perform side effects: it can spawn an LSP server process and send `textDocument/didOpen` notifications. Should it be allowed in `:plan` mode?
3. **`textDocument/didOpen` strategy.** Track open files in the Client GenServer (state) and only `didOpen` once, or re-`didOpen` on every tool call?
4. **Diagnostics protocol.** Push (`publishDiagnostics`, LSP 3.0+) or pull (`textDocument/diagnostic`, LSP 3.17)?

## Decision

1. **One tool, four actions.** `ExAthena.Tools.Lsp` dispatches on `args["action"] ∈ {definition, references, hover, diagnostics}`. Mirrors `ExAthena.Tools.PlanMode`'s `enter`/`exit` pattern and OpenCode's `lsp` tool. Avoids polluting the registry and the system prompt with four near-identical schema entries.

2. **Read-only.** `parallel_safe?/0` returns `true`; `"lsp"` is appended to `ExAthena.Permissions.@readonly_tools`. Spawning an LSP server is a process-level side effect, but no source files are touched and no shell is invoked. The closest analog already in the readonly set is `web_fetch`, which opens an HTTP connection — also a side effect, also classified read-only. Allowing under `:plan` is required for the tool to be useful at exploration time, which is the primary value proposition.

3. **`didOpen` per call.** The tool reads the file from disk and sends `textDocument/didOpen` before every position-based request. Servers in the default matrix (elixir-ls, pyright, gopls, rust-analyzer, typescript-language-server) all tolerate re-open by overwriting the buffer. This is exactly the desired semantics after an `Edit`/`Write`. The alternative — tracking open files in Client state with `didChange` + version increments — is more wire-efficient but adds significant Client complexity and stateful test surface; defer to v2 if telemetry shows the extra writes matter.

4. **Push diagnostics, polled.** `diagnostics` action sends `didOpen`, then polls `Client.diagnostics/2` (which reads the cached push notifications from `textDocument/publishDiagnostics`) every 50 ms for up to 1500 ms. Returns whatever the server has published, including the empty list. Pull-mode (LSP 3.17 `textDocument/diagnostic`) is deferred — the entire default-server matrix supports push, and adding pull as a fallback is a future optimization, not a v1 requirement.

## Consequences

**Positive**

- Single registry entry, single compact-schema line — minimal model-prompt footprint.
- Allowed under `:plan` mode without callback consultation, so exploratory agent loops can use it freely.
- No Client API extensions needed; ST1 stays untouched.
- `didOpen` re-send naturally absorbs file edits between calls — the server always sees fresh contents.

**Negative**

- Re-sending full file contents on every call is wasteful for large files. Acceptable for v1; revisit if telemetry shows `didOpen` payload bytes dominate request latency.
- 1500 ms diagnostics poll is a fixed budget; very slow servers (rust-analyzer warming up on a large workspace) may return empty when they shouldn't. Mitigation: ST3's `:PostToolUse` hook will own its own retry strategy and can extend the budget.
- Push-only diagnostics means some future LSP servers that only support pull will return empty for the diagnostics action. Documented in the tool's moduledoc.
- Action dispatch in a single tool means a typo in `action` returns `{:error, :invalid_action}` instead of "unknown tool" — slightly less ergonomic for the model. Mitigated by the `enum` in `schema/0` (native-tool-call providers will reject invalid values pre-execute).
