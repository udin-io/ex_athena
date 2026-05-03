# ADR 1: Compact tool-schema mode for weak open-weight models

## Status

Accepted

## Context

When `native_tool_calls: false` is in effect (typically forced for weak open-weight models per ex_athena#12), `ExAthena.ToolCalls.augment_system_prompt/2` injects the full JSON schema of every available tool into the system prompt. For a typical 10-tool runner this is 5–10 KB.

Weak local models such as `qwen2.5-coder:14b` show measurable quality degradation past ~4 KB of system prompt: confused tool selection, and more cases where the model serializes JSON as prose instead of using the prescribed `~~~tool_call` fence. Strong hosted models (Claude, GPT-4) are unaffected because they receive tools structurally via native `tool_calls` rather than depending on the prompt schema dump.

## Decision

Add an opt-in compact format selected by `augment_system_prompt(prompt, tools, compact: true)`. The compact format emits one type-signature line per tool:

```
- read_file(path: string, content?: string) — read a file
```

Rules:
- Required vs. optional marked with `?`.
- Type compaction: `string|number|integer|boolean|array|object|null`. Scalar-item arrays render as `T[]`.
- Nested object structure collapsed past depth 2.
- Description truncated to first sentence, capped near 80 chars.
- Tools without params render `tool_name() — desc`.

The `~~~tool_call` invocation contract — what the response parser actually depends on — is preserved unchanged. This is purely a schema-presentation change.

Providers advertise support via a static `compact_tool_schemas: true` capability flag on `ExAthena.Providers.ReqLLM.capabilities/0`. Downstream callers gate on this flag plus per-model heuristics to decide whether to pass `compact: true`.

The existing `augment_system_prompt/2` signature widens to `/3` with `opts \\ []`, preserving all current 2-arity call sites.

## Consequences

**Positive**
- Weak Ollama models become noticeably more reliable when forced into text-tagged mode.
- Default behavior is byte-identical — no risk to existing callers or strong models.
- Provider-agnostic implementation; one formatter serves every backend.
- Acceptance threshold (≤ 80% byte size on a 10-tool fixture) is enforced by tests, so regressions are caught automatically.

**Negative**
- Compact format loses schema fidelity (enums, regex patterns, deep nesting). Acceptable because weak models couldn't reliably honor those constraints anyway.
- Two formatter paths to maintain in `ExAthena.ToolCalls`.

**Neutral**
- Capability is static `true` regardless of underlying model. Per-model decisions (AthenaRunner gating on Ollama model id) live downstream — provider-level capabilities cannot enumerate every model.
