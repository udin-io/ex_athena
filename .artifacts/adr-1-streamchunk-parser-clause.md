# ADR 1: Add ReqLLM.StreamChunk clause to Native tool-call parser

**Status:** Proposed

## Context
The req_llm provider streams tool calls and accumulates them as raw `%ReqLLM.StreamChunk{type: :tool_call, name:, arguments:, metadata:}` structs. `ExAthena.ToolCalls.Native.parse_one/1` recognises OpenAI, Claude, and generic id/name shapes but not StreamChunk, so calls reach the catch-all clause and fail with `{:unrecognised_tool_call, chunk}`. This halts planning sessions on the Ollama/req_llm path.

## Decision
Add a `parse_one/1` clause for `%ReqLLM.StreamChunk{type: :tool_call}` that extracts an optional id from `metadata["id"]` or `metadata[:id]` and delegates to the existing `build/3` helper. The parser remains the single source of truth for tool-call shapes; provider boundaries stay unaware of struct normalisation.

## Consequences
- StreamChunk-shaped tool calls dispatch correctly on the Ollama/req_llm path.
- Future provider-specific shapes follow the same pattern: add a clause, reuse `build/3`.
- No public API changes. No migration. Backwards compatible.
- Aligns with existing ADR "RawJson tool-call fallback and per-request capability override".
