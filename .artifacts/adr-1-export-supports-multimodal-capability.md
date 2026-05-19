# ADR 1: Export `supports_multimodal?/0` as a public capability function

**Status:** Accepted

## Context

`ExAthena` v0.9.0 introduced full multimodal support: `ExAthena.Messages.ContentPart` provides factory functions for `:image`, `:image_url`, and `:file` content parts, and the `req_llm` adapter correctly serializes them. However, no public function was added to signal this capability to callers.

Downstream consumers (notably `udin_code`) resorted to `function_exported?(ExAthena, :supports_multimodal?, 0)` guards that always evaluate to `false` because the function never existed. As a result, images are silently dropped at the adapter boundary in `udin_code`.

## Decision

Add `def supports_multimodal?, do: true` to the `ExAthena` module (`lib/ex_athena.ex`) with a `@spec` of `() :: true` and a `@doc` that:
- States the function returns `true` when the library forwards multimodal content parts to the underlying provider.
- Lists the supported part types: image, image_url, file.
- References `ExAthena.Messages.ContentPart`.

The function always returns the compile-time constant `true` rather than inspecting provider capabilities at runtime. The rationale is that multimodal support is a library-level property (the serialization path exists in the req_llm adapter), not a per-provider toggle. Provider-specific capability checks are handled separately via `ExAthena.capabilities/1`.

Version is bumped from 0.9.0 to 0.10.0 (minor bump) to signal the new public API surface.

## Consequences

- Downstream callers can reliably detect multimodal support without module-existence sniffing.
- The `udin_code` dead guard becomes live, unblocking image forwarding.
- The function signature `() :: true` makes the return type explicit; if multimodal support is ever made conditional in the future, this spec and implementation must both be revisited.
- No breaking changes; purely additive.
