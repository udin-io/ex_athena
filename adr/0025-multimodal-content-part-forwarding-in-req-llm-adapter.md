# ADR: Forward ExAthena.Messages.ContentPart through req_llm adapter

## Status
Accepted

## Context

Sub-ticket 1 introduced `ExAthena.Messages.ContentPart` and extended `Message.content` to `String.t() | [ContentPart.t()] | nil`. The req_llm adapter's `text_parts/1` function only handled binary strings, leaving list content unhandled. Without a conversion path, multimodal messages (containing `:image`, `:image_url`, or `:file` content parts) would raise a `FunctionClauseError` at runtime rather than being forwarded to providers.

`ReqLLM.Message.ContentPart` already provides exact-matching constructors — `text/1`, `image/2`, `image_url/1`, `file/3` — so the mapping is one-to-one with no impedance mismatch.

## Decision

Add a `text_parts/1` clause for `is_list(parts)` that maps each `ExAthena.Messages.ContentPart` to its `ReqLLM.Message.ContentPart` counterpart via a private `to_req_llm_content_part/1` helper. The mapping covers all four current variants:

- `:text` → `ReqLLM.Message.ContentPart.text(text)`
- `:image` → `ReqLLM.Message.ContentPart.image(data, media_type)`
- `:image_url` → `ReqLLM.Message.ContentPart.image_url(url)`
- `:file` → `ReqLLM.Message.ContentPart.file(data, filename, media_type)`

No changes to any `to_req_llm_message/1` clauses are required — all roles (`:user`, `:system`, `:assistant`, `:tool`) already delegate to `text_parts/1`.

The helper is private, keeping the conversion logic encapsulated within the adapter module.

## Consequences

**Positive:**
- Multimodal messages constructed as `[ContentPart.t()]` now flow correctly to all req_llm-backed providers (Ollama, OpenAI-compatible, Gemini).
- All existing string-only callers are completely unaffected — the `nil`, `""`, and `binary` clauses are unchanged.
- The change is purely additive — no public API signatures change.

**Negative / Trade-offs:**
- Any future `ContentPart` type added to `ExAthena.Messages.ContentPart` (e.g., `:video_url`) will require a corresponding `to_req_llm_content_part/1` clause. This is a deliberate explicit mapping rather than a dynamic passthrough, to maintain type safety at the provider boundary. A missing clause will raise `FunctionClauseError` at runtime, which is preferable to silently dropping content.
