# ADR 1: RawJson tool-call fallback and per-request capability override

## Status

Accepted

## Context

Weak open-weight models routed through ReqLLM/Ollama (e.g. `qwen2.5-coder:14b`) emit tool calls as bare JSON in assistant text rather than as a structured `tool_calls` array. ExAthena's current extraction pipeline has two parsers — `Native` and `TextTagged` — and an auto-fallback that triggers only on a `~~~tool_call` fence substring. Bare JSON is silently dropped and ReAct ends with `:stop` without firing any tool.

Separately, `ExAthena.Providers.ReqLLM` statically declares `native_tool_calls: true` for every model it fronts, so `ReAct.effective_system_prompt/1` never augments the prompt with fence instructions. There is no per-request way to flip this for a known-weak model, so callers cannot opt those models into fenced prompting without forking the provider module.

Together these gaps mean tool calls from weak Ollama models are dropped end-to-end, blocking downstream consumer udin-io/udin_code#1268.

## Decision

1. Introduce a third parser, `ExAthena.ToolCalls.RawJson`, that recognizes bare and ```json-fenced JSON objects with a `name`/`arguments` shape, using balanced-brace scanning (in-string state + backslash escapes). Wire it into `ToolCalls.extract/2` as a third fallback tier behind `Native` and `TextTagged`.
2. Add a per-request capability override in `ExAthena.Loop`: `Map.merge(provider_mod.capabilities(), opts[:capabilities] || %{})`. Callers can pass `capabilities: %{native_tool_calls: false}` to flip ReAct into fence-augmented prompting per request, without changing the provider module.

Neither change alters the parser contract (`{:ok, [ToolCall.t()]}`), introduces a new provider, or modifies caller-visible defaults.

## Consequences

**Positive**

- Tool calls from weak models like `qwen2.5-coder:14b` are no longer silently dropped.
- Downstream consumers can opt known-weak models into fenced prompting without forking provider modules.
- Default behavior is unchanged; the new fallback is conservative and best-effort.
- Unblocks udin-io/udin_code#1268.

**Negative / risks**

- A third extraction tier slightly increases parser pipeline surface area.
- The balanced-brace scanner is hand-rolled; pathological input could in principle slow extraction. Mitigated by a cheap pre-check requiring both `"name"` and `"arguments"` substrings before scanning.
- `:capabilities` becomes a public per-request opt; future capability flags must be designed to remain back-compatible under merge.
