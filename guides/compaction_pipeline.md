# Compaction pipeline (v0.4)

When the conversation's estimated tokens crosses `compact_at` (default
60% of the provider's `max_tokens`), the loop runs the compaction
pipeline before the next iteration.

The default pipeline mirrors Claude Code's five-layer design from the
[paper](https://arxiv.org/abs/2604.14228): cheap deterministic stages
run first, the expensive LLM-summary stage runs only when those
couldn't get the conversation under target.

```
state.messages
  ↓
[BudgetReduction] → drop oversized tool-result bodies
  ↓
[Snip]            → drop stale tool-result bodies (already integrated)
  ↓
[Microcompact]    → collapse runs of 3+ adjacent same-tool results
  ↓
[ContextCollapse] → non-destructive view-time projection
  ↓
[Summary]         → LLM summary of the middle of history
  ↓
state.messages (or state.meta[:compact_view])
```

Each stage is a module implementing `ExAthena.Compactor.Stage` with
`compact_stage/2` and `name/0`. The pipeline orchestrator
(`ExAthena.Compactor.Pipeline`) walks the list with `Enum.reduce_while`
and short-circuits once estimated tokens fall below target. Every
stage runs inside its own
`[:ex_athena, :compaction, <:stage_name>, :start | :stop]` telemetry
span.

## Built-in stages

### `Compactors.BudgetReduction`

Cheap, deterministic. For each tool-result message whose content
exceeds `:per_tool_result_max_chars` (default 16k), replace the body
with `[truncated; full=N chars; ref=<id>]` and persist the original
to `state.meta[:tool_result_archive]` keyed by `ref`.

This single stage often gets the conversation under target on its own
when one outlier tool produced a giant response (a `Read` of a 100KB
file, a `Bash` `grep` over a huge tree).

### `Compactors.Snip`

Cheap, deterministic. Drops stale tool-result bodies older than
`:snip_age_iterations` turns (default 4) whose paired assistant turn
already happened. Each is replaced with a `<snipped: stale tool-result
for call <id>>` marker — pairing-by-id stays intact.

Memory + skill messages and the live suffix are never touched.

### `Compactors.Microcompact`

Medium cost, deterministic. Runs of 3+ adjacent tool-result messages
collapse into a single elided summary tagged `name: "microcompact"`.
The summary lists each call's id + first 200 chars of its result.

### `Compactors.ContextCollapse`

Medium cost, *non-destructive*. Builds a projected message list for
the *next* request only — the authoritative `state.messages` is never
mutated. The projection collapses two patterns:

- **Superseded reads**: a `Read` whose file was later edited collapses
  to a `<read superseded by later edit: <path>>` stub.
- **Repeated identical tool calls**: same tool name + same args
  consecutive (skip-tool-results-aware) get a `(repeat)` marker on the
  follow-up call.

Stored at `state.meta[:compact_view]`. Resume / replay / rewind read
the original `state.messages`, so they stay correct.

### `Compactors.Summary`

Expensive — runs an LLM call. The middle of the message list is
summarised into a single assistant message tagged `name:
"compactor_summary"`. Cost counts against the run's budget. Only fires
when the deterministic stages couldn't get the conversation under
target.

## Reactive recovery

When a mode returns `{:error, :error_prompt_too_long}` (e.g. the
provider explicitly said "context too long"), the loop runs the
pipeline with `force: true` — every stage attempts compaction
unconditionally, regardless of estimated tokens. The same iteration is
then retried once. If still over (or compaction itself errors), the
run terminates with a typed `:error_prompt_too_long` capacity
termination (PR0 finish-reason).

Gated by `:reactive_compact` (default `true`):

```elixir
ExAthena.run("explore the repo", reactive_compact: false)  # opt out
```

## Configuration

### Per-call

```elixir
ExAthena.run("…",
  compact_at: 0.5,                  # trigger at 50% instead of 60%
  per_tool_result_max_chars: 8_000,
  snip_age_iterations: 8,
  microcompact_run_threshold: 5,
  compaction_pipeline: [
    ExAthena.Compactors.BudgetReduction,
    ExAthena.Compactors.Summary    # skip the others
  ])
```

### Global

```elixir
config :ex_athena, :compactor,
  compact_at: 0.6,
  pinned_prefix_count: 1,
  live_suffix_count: 6,
  per_tool_result_max_chars: 16_000,
  snip_age_iterations: 4
```

### Custom stages

Implement `ExAthena.Compactor.Stage`:

```elixir
defmodule MyApp.Compactors.DropImages do
  @behaviour ExAthena.Compactor.Stage

  @impl true
  def name, do: :drop_images

  @impl true
  def compact_stage(%ExAthena.Loop.State{} = state, estimate) do
    new_messages =
      Enum.map(state.messages, fn
        %{role: :user, content: content} = msg when is_binary(content) ->
          if String.contains?(content, "<image>"),
            do: %{msg | content: "<image elided>"},
            else: msg

        msg ->
          msg
      end)

    if new_messages == state.messages do
      :skip
    else
      {:ok,
       %{state | messages: new_messages},
       %{estimate | tokens: ExAthena.Compactor.estimate_tokens(new_messages)}}
    end
  end
end

ExAthena.run("...",
  compaction_pipeline: [
    MyApp.Compactors.DropImages,
    ExAthena.Compactors.BudgetReduction,
    ExAthena.Compactors.Summary
  ])
```

Stages should be **idempotent** — the reactive-recovery path may run
the pipeline a second time with `force: true`. Returning `:skip` on a
second pass is the canonical way to be idempotent.

## Hooks

- `:PreCompact` — fires before the pipeline runs at all.
- `:PreCompactStage` — fires before each individual stage. Payload:
  `%{stage: atom(), estimate: %{tokens, max_tokens}}`.
- `:PostCompact` — fires after a successful compaction. Payload:
  `%{metadata: %{before, after, dropped_count, stages_applied, reason}}`.

## Pinning rules

The compactor never drops:

- Messages in the **pinned prefix** — `:pinned_prefix_count` slots
  (default 1) at the front, *plus* any memory + pre-loaded skill
  messages (PR1).
- Messages in the **live suffix** — `:live_suffix_count` slots
  (default 6) at the tail.

Memory + skill messages tagged `name: "memory"` / `name: "skill:<name>"`
are pinned by default. Hosts can pin custom messages by extending
`pinned_prefix_count`.

## See also

- [`ExAthena.Compactor.Pipeline`](https://hexdocs.pm/ex_athena/ExAthena.Compactor.Pipeline.html)
- [`ExAthena.Compactor.Stage`](https://hexdocs.pm/ex_athena/ExAthena.Compactor.Stage.html)
- [Hooks reference](hooks_reference.md) — `PreCompact*` / `PostCompact`
  payload shapes.
- [Memory + skills](memory_and_skills.md) — what gets pinned.
