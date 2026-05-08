# ADR-1: Propagate consecutive_mistakes Resets Through Parallel fold_deltas

## Status

Accepted

## Context

`ExAthena.Loop.Parallel` runs `parallel_safe?` tool calls concurrently via `Task.async_stream`. After all tasks complete, `fold_deltas/2` merges per-task state deltas back into the main state. The original implementation only merged `budget` to avoid race conditions on the mistake counter when multiple tasks run simultaneously — the comment reads: "Mistake counter and ctx phase belong to the sequential path."

However, this design also discards `reset_mistakes/1` calls from *successful* parallel tasks, leaving the `consecutive_mistakes` counter elevated in the main state. Both `ExAthena.Tools.Glob` and `ExAthena.Tools.Read` declare `parallel_safe?: true`, so they both route through `run_concurrent` → `fold_deltas`. When either succeeds, the counter reset is thrown away.

Over multiple loop iterations, this causes the counter to exceed `max_consecutive_mistakes` even though no consecutive model mistakes actually occurred — the counter never got reset by intervening successful parallel tool calls.

The existing test "successful tool call resets the mistake counter" (v03_test.exs) uses `read` (parallel-safe) but passes accidentally: `max_consecutive_mistakes: 2` and the counter only reaches 1, so the threshold is never triggered. The test does not verify a reset actually occurred.

## Decision

Extend `fold_deltas/2` to propagate `consecutive_mistakes` from a task state **only when the task lowered the value** — specifically, when `n < state.consecutive_mistakes`. This covers the reset case (`n = 0`) while continuing to discard bumps (`n = initial + 1`), preserving the original race-condition safety guarantee.

The implementation splits `fold_deltas/2` into a pipeline of two private helpers:

```elixir
defp fold_deltas(state, new_state) do
  state
  |> maybe_update_budget(new_state)
  |> maybe_propagate_reset(new_state)
end

defp maybe_update_budget(state, %{budget: b}) when not is_nil(b), do: %{state | budget: b}
defp maybe_update_budget(state, _), do: state

defp maybe_propagate_reset(state, %{consecutive_mistakes: n})
     when n < state.consecutive_mistakes,
     do: %{state | consecutive_mistakes: n}

defp maybe_propagate_reset(state, _), do: state
```

The guard `n < state.consecutive_mistakes` is the minimal predicate: it propagates any downward movement (resets) and ignores any upward movement (bumps from errors in concurrent tasks).

A new regression test is added in v03_test.exs that will fail without the fix and pass with it: bad call → parallel glob (success) → bad call → final response, with `max_consecutive_mistakes: 2`. Without the fix the counter reaches 2 at turn 3 and triggers `error_consecutive_mistakes`; with the fix the glob reset brings it back to 0 so turn 3 only reaches 1.

## Consequences

**Positive:**
- Successful parallel tool calls correctly reset the mistake counter, matching the behavior of the serial path.
- `error_consecutive_mistakes` only fires when mistakes are genuinely consecutive — not when interrupted by successful parallel calls.
- No change to the race-condition safety for concurrent bumps.

**Neutral:**
- If multiple parallel tasks all reset the counter, the final folded value is 0 regardless — correct and idempotent.
- If some tasks succeed (reset) and some fail (bump), the reset propagates because `n = 0 < initial`. This is the right behavior: one successful tool call in a batch is enough to reset.

**Negative:**
- None identified. The change is additive and narrowly scoped to a single private function.
