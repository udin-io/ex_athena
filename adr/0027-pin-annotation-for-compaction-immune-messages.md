# ADR 1: Pin Annotation for Compaction-Immune Messages

**Status:** Proposed

## Context

On `:error_prompt_too_long`, the loop kernel calls `force_compact/1`, which runs every compaction stage (Snip, Microcompact, ContextCollapse, Summary) with `force: true`. The compactor pipeline has no mechanism to identify which messages are semantically load-bearing for the consumer. Three classes of messages are particularly vulnerable:

1. The `ExitPlanMode` tool result whose plan text the runner is about to read from `state.messages`.
2. The `set_pr_url` tool result whose URL downstream code needs to extract.
3. The sentinel-bearing assistant message used by generic-runner completion detection.

Any of these can be silently dropped by compaction, producing a "session finished successfully but the artifact is gone" failure that is hard to diagnose.

## Decision

### 1. `pin: boolean` field on `Message`

Add `pin: false` to `ExAthena.Messages.Message`'s `defstruct`. Any caller — mode code, tool execution, consumer-injected messages — can set `pin: true` to declare a message as compaction-immune. The field defaults to `false`, keeping all existing behavior unchanged. `from_map/1` reads `pin` from incoming maps, defaulting to `false`.

### 2. `auto_pin: %{tool_names: [...]}` loop option

`Loop.run/2` accepts `auto_pin: %{tool_names: ["ExitPlanMode", "set_pr_url"]}`. This is stored in `state.meta[:auto_pin]` via `compaction_meta/1`. When `force_compact/1` is called, it first invokes `apply_auto_pin/1`, which:

- Builds a `tool_call_id → tool_name` index from all assistant messages' `tool_calls` lists.
- Iterates over tool-role messages; any whose `tool_results` contain a call ID matching a named tool gets `pin: true` stamped on it.

Auto-pinning runs only on the reactive-recovery path (`force_compact`), not during routine proactive compaction. This matches the ticket intent: protecting messages the consumer is *about to* consume when the context window is already exceeded.

### 3. All compaction stages respect `pin: true`

- **Snip**: add `msg.pin` as the first guard in the reduce cond — pinned messages are never replaced with snip markers.
- **Microcompact**: add a `%Message{pin: true}` head clause to `do_collapse` that passes through immediately; `take_tool_run` stops collecting at pinned messages.
- **ContextCollapse**: add a `%Message{role: :tool, pin: true}` match-first clause in `collapse_superseded_reads` to pass the message through without rewriting content.
- **Summary**: after `split_messages/3`, partition the `middle` with `Enum.split_with(middle, & &1.pin)`. Only non-pinned messages are summarized; pinned messages are stitched back in after the summary message in the reconstructed list.

## Consequences

**Positive:**
- Load-bearing messages survive reactive compaction unconditionally.
- The API is additive: `pin: false` is the default, so zero existing code breaks.
- Callers can pin individual messages explicitly (`%{msg | pin: true}`) or configure auto-pinning by tool name — two complementary mechanisms for different use cases.
- All five stages enforce the same invariant, so adding a new custom stage to the pipeline doesn't silently break pinning (the field is on the struct and custom stages can check it).

**Negative / trade-offs:**
- Pinned messages in the middle of a large conversation permanently consume context tokens that the compactor cannot reclaim. In pathological cases (many pinned messages + very long context), compaction may fail to bring the conversation under the token budget.
- The `auto_pin` option only fires on the reactive path; callers who want proactive pinning must set `pin: true` manually before messages are stored in `state.messages`.
- Summary's reconstructed message order places pinned messages *after* the summary message (not at their original indices). This is semantically correct (the model sees "summary of prior work, then the preserved result") but changes relative ordering within the former middle partition.
