# ADR: Introduce :error_schema_validation and :error_provider_auth finish_reason subtypes

**Status:** Accepted

## Context

`ExAthena.Loop.Terminations` defines typed termination subtypes for agent loop runs. Previously, all failure modes that were not capacity limits or halts fell through to `:error_during_execution`, which is classified as `:retryable`. This single bucket covered:

- Model returning unparseable/schema-invalid output (consumer should retry with a reformat hint)
- Provider returning HTTP 401/403 (consumer must fix credentials — never retry blindly)
- Provider returning network/transport errors (transient; retry makes sense)

Consumers using `Result.category/1` or pattern-matching on `Result.finish_reason` could not distinguish these cases, making it impossible to implement correct retry and user-surfacing logic downstream.

The issue also noted that `Result` carried no structured validation payload — callers could inspect `halted_reason` but only as an opaque term.

## Decision

### 1. New termination subtypes

Add two subtypes to `ExAthena.Loop.Terminations`:

- `:error_schema_validation` — the loop terminated because the model's output could not be parsed as valid structured output or tool calls. Category: `:retryable` (caller may retry with a reformat prompt hint).
- `:error_provider_auth` — the provider returned an HTTP 401 or 403. Category: `:fatal` (requires operator action to fix credentials; blind retry will not help).

Both are added to `@all_subtypes`, the `@type subtype` union, `category/1` dispatch, and `@moduledoc`.

### 2. error_diagnostic field on Result

Add `error_diagnostic: nil` to `ExAthena.Result`. When `finish_reason` is `:error_schema_validation`, this field is populated with:

```elixir
%{
  schema: request.response_format,   # the response_format that was active, if any
  received: response.text,            # raw text returned by the model
  violations: [%{reason: String.t()}] # list of violation descriptions
}
```

The `path` key inside each violation is optional; current parsers do not emit structured paths so violations carry only a `reason` string derived from `inspect(parse_error)`. Future parsers that emit richer diagnostics can populate `path`.

The field is `nil` for all other finish_reason values.

### 3. Detection in ReAct mode

`ExAthena.Modes.ReAct.do_iterate/2` has two `{:error, reason}` branches:

**Branch A (ToolCalls.extract failure, previously lines 121-126):** Changed to set `finish_reason: :error_schema_validation` and populate `state.meta[:error_diagnostic]`. Both `response` and `request` are in lexical scope at this point, providing the raw text and the active response_format.

**Branch B (provider query/stream failure, previously lines 129-134):** Inspects the error struct. `%ExAthena.Error{kind: :unauthorized}` routes to `:error_provider_auth`. All other errors remain `:error_during_execution`.

### 4. Threading through the loop kernel

`ExAthena.Loop.to_result/2` reads `state.meta[:error_diagnostic]` and assigns it to `result.error_diagnostic`. No changes to `ExAthena.Loop.State`'s typed fields are needed — `meta` is the existing free-form escape hatch for mode-specific data.

### 5. No change to StructuredOutput helper

`ExAthena.StructuredOutput.request/3` operates outside the loop and returns raw `{:ok, map()} | {:error, reason}` tuples. Its callers are not affected by this change.

## Consequences

**Positive:**
- Consumers can dispatch on `Result.finish_reason` to implement correct retry logic without inspecting opaque `halted_reason` internals.
- `Result.category/1` now returns `:fatal` for auth errors instead of `:retryable`, preventing futile retry storms.
- `Result.error_diagnostic` provides a structured payload for logging and user-facing error messages on schema validation failures.

**Negative / trade-offs:**
- Adding `:error_provider_auth` is a new `:fatal` subtype. Consumers that previously handled all `:fatal` results identically (e.g., `category == :fatal -> surface_to_user`) will now see auth errors routed there without any code change, which is the desired behavior but is technically a behavior change for callers who pattern-matched on `finish_reason: :error_during_execution` for auth errors specifically.
- The `violations` list currently contains only `inspect(reason)` strings, not structured paths. This is intentional — the ToolCalls parsers do not emit structured path information today. A future ADR can extend the diagnostic when richer parser output is available.
- `state.meta[:error_diagnostic]` uses the existing escape hatch rather than a typed State field. This is consistent with how `finish_reason` itself is stored (`state.meta[:finish_reason]`) and avoids widening the public State type in a minor patch.
