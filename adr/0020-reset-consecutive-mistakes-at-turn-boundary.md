# ADR 1: Reset `consecutive_mistakes` at the turn boundary, not per tool call

## Status

Proposed (supersedes the per-call reset behaviour added alongside `adr-1-propagate-consecutive-mistakes-resets-through-parallel-fold-deltas.md`).

## Context

The mistake counter currently resets inside `ExAthena.Modes.ReAct.do_execute/2` on each successful tool clause (`{:ok, _}`, `{:ok, text, ui}`, phase transition) and bumps inside the same function on failure clauses (unknown tool, permission denied, `{:error, _}`, invalid return).

When a single turn contains multiple tool calls executed serially (mutating tools), the *last* tool's state replaces earlier states. A turn that succeeds then fails ends with `consecutive_mistakes = prev + 1`; a turn with a single failing call never sees a reset. Production traces on 2026-05-08 show this exact shape: `finish_reason=:stop, tool_calls=N` immediately followed by `:error_consecutive_mistakes`.

The earlier ADR (`adr-1-propagate-consecutive-mistakes-resets-through-parallel-fold-deltas.md`) only fixed the *concurrent* path — bumps from concurrent siblings being discarded while a successful sibling's reset is preserved. The serial path and the single-failing-call path were not addressed.

## Decision

Move the reset decision from inside `do_execute/2` to the turn boundary in `do_iterate/2`:

1. After `Parallel.run/3` returns `{:ok, tool_messages, state}`, classify the batch by the `is_error` flag already carried on each `Messages.tool_result/3,4`.
2. If `Enum.any?(tool_messages, & &1.is_error == false)`, call `reset_mistakes(state)` once.
3. If every result is an error, leave the per-call bumps in place — the counter still climbs on pure-error turns, preserving the existing "give up after N consecutive failures" contract.

The per-call `bump_mistake/1` calls inside `do_execute/2` remain. The per-call `reset_mistakes/1` calls inside `do_execute/2` are **removed** (they become redundant with the turn-boundary reset and would mask bumps from sibling calls in the same turn).

`Parallel.fold_deltas/2` and its `maybe_propagate_reset/2` helper are unchanged; they still correctly merge per-task counter deltas before this turn-level decision runs on the merged state.

## Consequences

**Positive**

- A turn with any successful tool result resets the counter, regardless of whether other calls in the same batch failed or what order they ran.
- The decision lives in one place (`do_iterate/2`) rather than scattered across six clauses of `do_execute/2`.
- Existing tests `successful tool call resets the mistake counter` (v03_test.exs:116) and `successful parallel tool call resets the mistake counter` (v03_test.exs:163) continue to pass — they exercise all-success batches.

**Negative / trade-offs**

- A turn with one success and one failure now resets to 0 even though the model still made a mistake on that turn. We treat partial progress as a sign the model is recovering, which matches the human reading of "consecutive mistakes" (a *streak* of all-failure turns).
- The per-call reset removal means the diagnostic logging from the diagnostic phase must be removed cleanly to avoid masking the new behaviour during review.

**Neutral**

- No change to `Parallel.fold_deltas/2`; the earlier ADR (`adr-1-propagate-consecutive-mistakes-resets-through-parallel-fold-deltas.md`) remains in force and complements this decision.
- No change to the threshold gate in `Loop.loop/1`; ordering remains "check threshold → iterate".
