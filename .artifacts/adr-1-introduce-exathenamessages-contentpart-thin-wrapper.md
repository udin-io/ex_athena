# ADR: Introduce ExAthena.Messages.ContentPart as a Thin Provider-Agnostic Wrapper

## Status

Accepted

## Context

`ExAthena.Messages.Message.content` is currently `String.t() | nil`. The `req_llm` library (which
backs all ExAthena providers) already has full multimodal support via `ReqLLM.Message.ContentPart`
with variants `:text`, `:image`, `:image_url`, `:video_url`, `:file`, `:thinking`. ExAthena cannot
propagate image content to providers because there is no place in its data model to store it.

Two design options were considered:

1. **Re-export `ReqLLM.Message.ContentPart` directly** — use the upstream struct as ExAthena's
   public content-part type.
2. **Thin wrapper `ExAthena.Messages.ContentPart`** — introduce a new ExAthena-owned struct that
   mirrors the relevant subset of `ReqLLM.Message.ContentPart`'s types and factory API.

## Decision

Introduce `ExAthena.Messages.ContentPart` as a **thin wrapper** (option 2).

The struct has fields `[:type, :text, :url, :data, :media_type, :filename]` and supports four
variants for the initial release: `:text`, `:image`, `:image_url`, `:file`. Factory functions
(`text/1`, `image/1-2`, `image_url/1`, `file/2-3`) intentionally mirror `ReqLLM.Message.ContentPart`'s
factory API so the mapping in the req_llm adapter is mechanical.

`Message.content` is widened to `String.t() | [ExAthena.Messages.ContentPart.t()] | nil`. Existing
string-content code paths are unaffected. A new `user/1` clause accepting `is_list(parts)` is added
alongside the existing binary clause.

The module lives at `lib/ex_athena/messages/content_part.ex` (its own file) rather than as a nested
module in `messages.ex`, because it is a first-class public type that callers will import independently.

## Consequences

**Positive:**
- ExAthena's public API does not depend on `req_llm` types; callers need not import `req_llm` directly.
- Future providers (direct HTTP, native Anthropic SDK) map from `ExAthena.Messages.ContentPart` to
  their own native format without changing the public data model.
- The subset approach (four types, not six) avoids committing to `:thinking` and `:video_url` until
  there is a clear use case and acceptance criteria.
- Factory signatures are identical to `ReqLLM.Message.ContentPart`'s, making the adapter mapping in
  sub-ticket 2 a one-to-one substitution with no cognitive overhead.
- All existing callers pass string content; the widened union type is purely additive.

**Negative:**
- Introduces a thin wrapper that must be kept in sync with the upstream library when new content types
  are needed (e.g., `:video_url`, `:thinking`).
- Callers who already construct `ReqLLM.Message.ContentPart` directly cannot pass those structs into
  `ExAthena.Messages.Message.content` without conversion.
