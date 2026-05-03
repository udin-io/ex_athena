# ADR 1: Strict structured-output pass-through for req_llm/Ollama

## Status

Accepted

## Context

Ollama's OpenAI-compatible chat endpoint accepts a `response_format` (or native `format`) parameter that forces schema-conforming JSON. Downstream `udin_code` consumers — scope decisions and ExitPlanMode-style phase-end signals — currently rely on brittle text extraction because weaker open-weight models do not reliably emit structured `tool_calls`.

`ExAthena.Request` already has a `:response_format` field, but `ExAthena.Providers.ReqLLM` does not forward it. There is also an existing `ExAthena.Structured.extract/2` helper that performs retry/repair with fenced-block fallback — useful for providers without structured output, but not the strict one-shot contract this ticket needs.

ADR 1 (existing) introduced a per-request `:capabilities` override in `ExAthena.Loop`. We want the new helper to honour the same override.

## Decision

1. Forward `response_format` through `ExAthena.Providers.ReqLLM.build_opts/2`, preferring `opts[:response_format]` over `request.response_format`. Pass `:json`, `"json"`, and JSON-schema maps verbatim — req_llm normalises.
2. Declare a new capability key `:structured_output` and set `structured_output: true` on `ExAthena.Providers.ReqLLM.capabilities/0`. Add the key to the `ExAthena.Capabilities` typespec.
3. Introduce `ExAthena.StructuredOutput` with a single function `request(prompt, schema, opts)`. It is strict: it requires the resolved provider to declare `:structured_output` (after merging the per-request `:capabilities` override). Returns `{:ok, decoded_map}` on success, `{:error, :no_structured_output}` when the capability is absent, `{:error, :invalid_json}` on decode failure, and passes provider errors through.
4. Do not modify `ExAthena.Structured`. The two helpers coexist: `Structured.extract/2` is the retry/repair flavour; `StructuredOutput.request/3` is the strict one-shot variant.

## Consequences

Positive:
- Downstream callers can rely on provider-enforced JSON shape rather than text parsing.
- The strict contract makes capability gaps loud (`:no_structured_output`) instead of silently degrading.
- Symmetry with ADR 1's per-request capability override means callers can force-disable on known-bad models.

Negative / risks:
- We assume req_llm's OpenAI adapter forwards `response_format` for `:ollama` backend. If integration testing shows it strips the field for non-OpenAI backends, we will route through `:provider_opts` — no public API change.
- Two structured-output helpers (`Structured` vs `StructuredOutput`) increases surface area; the contract difference (best-effort vs strict) justifies keeping them separate.
