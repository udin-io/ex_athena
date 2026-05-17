# ADR: `images:` shorthand implemented in `Request.new/2`

## Status

Accepted

## Context

Sub-tickets 1 and 2 introduced `ExAthena.Messages.ContentPart` and updated the req_llm adapter to forward multimodal content. The remaining gap is that callers must manually construct `[%ContentPart{...}, ...]` lists and wrap them in a `Messages.user/1` call. The parent issue requests an ergonomic shorthand so the common case (attach image to the current turn) is a single option.

Two possible insertion points were considered:

1. **`Request.new/2`** — the shared normalisation layer used by `query/2`, `stream/3`, and `run/2`
2. **`ExAthena.Loop.build_initial_state/2`** — the loop-only state builder

## Decision

Implement `images:` handling in `Request.new/2`. This makes the shorthand available for all three public entry points (`query/2`, `stream/3`, `run/2`) at zero duplication cost.

`normalize_images/1` maps each image spec to a `ContentPart` struct:
- `%{data: binary(), media_type: String.t()}` → `ContentPart.image(data, media_type)`
- `%{url: String.t()}` → `ContentPart.image_url(url)`
- `%{data: binary()}` (no media_type) → `ContentPart.image(data, "image/png")`

`build_messages/3` dispatches on `{prompt, image_parts}`:
- No images → unchanged three-clause behaviour (preserves backward compatibility)
- Images + non-empty prompt → `existing ++ [Messages.user([ContentPart.text(prompt) | image_parts])]`
- Images + nil/empty prompt → merge into last user message in `existing`, or append a new user message with just image parts

`find_last_user/1` uses `Enum.reverse` + `Enum.split_while` to locate and split around the last user-role message without requiring `Enum.reduce` with index tracking.

## Consequences

**Positive:**
- Single implementation point; no duplication across `query/2` and `run/2`.
- Existing text-only callers are entirely unaffected; the no-images clauses are identical to the previous implementation.
- Type-safe: image specs are eagerly normalized to `ContentPart` structs before the messages list is assembled.
- `stream/3` automatically gains `images:` support at no extra cost since it also calls `Request.new/2`.

**Negative / watch:**
- `Request.new/2` now silently consumes `:images` from opts. If a future caller passes `:images` for an unrelated purpose the key will be consumed without error. This is unlikely given the key's self-documenting name.
- The `find_last_user/1` helper performs two `Enum.reverse` calls on the messages list; negligible for typical conversation lengths but worth noting for extremely long histories.
