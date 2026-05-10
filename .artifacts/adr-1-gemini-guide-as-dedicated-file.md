# ADR 1: Dedicated `guides/gemini.md` rather than extending `guides/providers.md`

## Status

Accepted

## Context

Issue #40 asks for a Gemini setup guide and explicitly specifies the path `guides/gemini.md`, "mirroring the structure of the existing Ollama guide". On inspection, no `guides/ollama.md` exists — Ollama (and every other provider today) is documented as a section inside the single `guides/providers.md` file. We must decide whether to:

1. Add a new `## Gemini` section to the existing `guides/providers.md` (matches today's structure), or
2. Create a new dedicated file `guides/gemini.md` (matches the ticket text and the model used by other ecosystems for per-provider deep-dives).

## Decision

Create the dedicated file `guides/gemini.md` as the ticket specifies, and additionally add a short Gemini stub section to `guides/providers.md` that links out to the new file. The README provider table gets a new `:gemini` row that links directly to `guides/gemini.md`.

The dedicated file covers: overview, getting an API key, env var convention, configure block, first call, model table, capabilities table, tool-calling caveats, rate-limit notes, troubleshooting.

## Consequences

Positive:

- Honors the ticket acceptance criteria literally.
- Gives Gemini-specific deep content (rate limits, tool-call schema caveats) room to breathe without bloating `providers.md`.
- Establishes a precedent: future per-provider deep-dives (Ollama, Claude) can be split out the same way.

Negative / trade-offs:

- Two places now mention Gemini (`providers.md` stub + dedicated file). Drift risk is low because the stub is intentionally short and links out.
- Asymmetric with other providers until they get their own guides; the README table softens this by linking only Gemini for now.
