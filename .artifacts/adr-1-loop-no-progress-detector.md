# ADR: Loop No-Progress Detector

**Status:** Proposed

---

## Context

`ExAthena.Loop` enforces three termination conditions — `max_iterations`, `max_consecutive_mistakes`, `max_budget_usd` — but has no mechanism to detect when consecutive iterations are producing identical tool calls with no new state. Modes have to build their own progress detectors, or they don't, and the loop happily spins for 25 iterations. In `udin_code`, this manifests as the SDK runner burning ~19 minutes of a 20-minute planning timeout retrying the same denied `bash` command.

---

## Decision

### 1. New termination subtype: `:error_no_progress`

Add `:error_no_progress` to `ExAthena.Loop.Terminations` with category `:capacity`. This is a capacity-class termination (the run hit a configured limit), consistent with `:error_consecutive_mistakes` and `:error_max_turns`.

### 2. State additions

Add four fields to `ExAthena.Loop.State`:

- `max_unproductive_iterations: 3` — configurable threshold (default 3).
- `unproductive_iterations: 0` — consecutive unproductive iteration counter.
- `last_tool_fingerprint: nil` — sorted `[{name, args_binary}]` list from the previous iteration, used to detect identical tool calls.
- `no_progress_snapshot: nil` — populated with the last `N*4` messages when the guard fires.

### 3. Optional Mode callback: `productivity_signal/2`

Add an optional `@callback productivity_signal(prev_state, new_state) :: boolean()` to `ExAthena.Loop.Mode`. Modes can override the kernel's default check with domain-specific logic.

### 4. Kernel-level default productivity check

When a mode does not implement `productivity_signal/2`, the loop kernel uses `default_productivity_signal/3`: an iteration is productive if its tool-call fingerprint differs from the previous iteration's fingerprint, OR if it produced new non-empty assistant text. The fingerprint is a sorted list of `{tool_name, args_binary}` pairs extracted from new assistant messages.

Fingerprint computation:
- `ToolCall.arguments` is a map → `Jason.encode!/1`
- `ToolCall.arguments` is a binary (pre-encoded) → pass-through
- `ToolCall.arguments` is nil → `"{}"`

This mirrors the encoding convention established in the `format_tool_calls/1` ADR.

### 5. Counter management in `loop/1`

- After `{:continue, new_state}`: call `update_progress_tracking(prev_state, new_state)` to compute the fingerprint, check productivity, and increment or reset `unproductive_iterations`.
- In the `cond` block (before `true ->`): check `state.unproductive_iterations >= state.max_unproductive_iterations`. If exceeded, capture snapshot and terminate with `:error_no_progress`.
- The `handle_prompt_too_long/1` retry path has its own `{:continue, new_state}` arm — apply `update_progress_tracking/2` there too.

### 6. Result snapshot field

Add `no_progress_snapshot: nil` to `ExAthena.Result`. Populated from `state.no_progress_snapshot` in `to_result/2`. The snapshot is the last `max_unproductive_iterations * 4` messages, giving consumers the stuck-state context for a remediation reprompt.

### 7. ReAct reference implementation

`ExAthena.Modes.ReAct` implements `productivity_signal/2` as the reference implementation, mirroring the kernel default. This establishes the pattern for future modes without duplicating logic in the kernel.

---

## Consequences

**Positive:**
- Eliminates the 19-minute timeout burn in `udin_code` caused by stuck tool retries.
- Adds a typed, categorised termination that consumers can handle distinctly from other capacity limits.
- The `no_progress_snapshot` enables automated remediation reprompts.
- The optional mode callback lets specialised modes (Reflexion, PlanAndSolve) define richer progress semantics without modifying the kernel.

**Negative / Trade-offs:**
- The fingerprint approach detects identical tool-call repetition but does not detect semantic stagnation (e.g., writing the same file content twice with different tool-call args). This is intentional — semantic stagnation requires mode-specific knowledge.
- `max_unproductive_iterations: 0` would fire on the first iteration (counter starts at 0, check is `>=`). Callers must use `1` as the minimum meaningful value; this should be documented in the option's `@doc`.
- The first iteration always has `last_tool_fingerprint: nil`, so any non-empty current fingerprint compares unequal to `nil`, correctly marking the first iteration as productive regardless of content.
- Adding four fields to `State` grows the struct; all have sensible defaults so existing call sites are unaffected.
