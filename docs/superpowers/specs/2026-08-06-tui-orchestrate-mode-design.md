# TUI: Orchestrate mode + AskUser support — Design

**Date:** 2026-08-06
**Status:** Approved (brainstorming session)

## Goal

Make `:orchestrate` mode usable from the TUI (`mix athena.chat`). Today the mode
exists in the library (`ExAthena.Modes.Orchestrate`) and the web UI offers it, but
the TUI's mode allow-lists exclude it, and the TUI never wires the `ask_user`
tool — which orchestrate's restricted toolset (`todo_write`, `spawn_agent`,
`finish`, `ask_user`) depends on for mid-run clarification.

## Scope decision

**Enable + ask_user.** Mode enablement plus full AskUser support with inline
answering. Explicitly out of scope (tracked as a follow-up issue, "tui:
orchestration view — Coordinator integration"):

- Coordinator-driven per-agent task tree / status pane (web Overview equivalent)
- `{:conclusion, ...}` / `{:queue_wait, ...}` / `{:submitted, ...}` timeline entries
- Per-agent grouping of subagent output (today: flattened one-liners)

## Design

### 1. Mode enablement

Add `:orchestrate` to the three hardcoded allow-lists:

- `lib/ex_athena/chat/tui.ex` — `@modes [:react, :plan_and_solve, :reflexion]`
  (drives both the `/mode` popup and `/mode NAME` validation via `parse_mode_atom/1`)
- `lib/mix/tasks/athena.chat.ex` — `@valid_modes` (the `--mode` CLI flag)
- `lib/ex_athena/chat/commands.ex` — help text (two places)

No new plumbing: `Session.set_mode/2` → `Runner.build_run_opts/2` → `mode:`
already flows through to `ExAthena.run/2`.

### 2. AskUser tool wiring (all modes, matching web)

In `ExAthena.Chat.Tui.Runner`:

- `build_run_opts/2` gains the target pid (threaded from `start/3`, where it is
  already available) and:
  - appends `ExAthena.Tools.AskUser` to the resolved toolset
  - adds `assigns: %{ask_user: target_pid}` (the TUI app process — the same pid
    that receives `{:athena_event, ...}`)

Wired for **all** modes, not just orchestrate — this matches the web UI, the
tool's own description restricts when the model should invoke it, and any
interactive run benefits. Contract (from `ExAthena.Tools.AskUser`): the tool
blocks in the run task process, sends
`{:athena_ask_user, %{tool_call_id, question, options}}` to the `ask_user` pid,
and waits for `{:athena_user_answer, tool_call_id, answer}` sent **to the run
task pid** (`Runner.start/3` already returns it; the web's RunServer uses the
same reply target).

### 3. Pending question — inline answering via the input line

Chosen UX: the question renders as a highlighted entry in the message log with
numbered options; the normal input line collects the answer. No popup.

```
┌ messages ──────────────────────────────┐
│ ? Orchestrator asks:                   │
│   Which database should the workers    │
│   target?                              │
│   [1] postgres  [2] sqlite             │
│   (type a number or a free-form reply) │
└────────────────────────────────────────┘
┌ input ─────────────────────────────────┐
│ answer> 1▌                             │
└────────────────────────────────────────┘
```

Mechanics:

- New `State` field: `pending_question :: nil | %{tool_call_id, question, options}`.
- `handle_info({:athena_ask_user, payload})` in the TUI app stores it, appends
  the highlighted question entry (question + numbered options + hint) to the
  message log, and adds a details-pane entry — mirroring existing event handling.
- While pending, Enter routes the input as the **answer**, not a new prompt:
  - input that parses as a valid 1-based option index resolves to that option's
    text
  - anything else is sent verbatim as a free-form answer
  - reply: `send(run_task_pid, {:athena_user_answer, tool_call_id, answer})`
- The answer is echoed into the log; `pending_question` is cleared.
- Input-area title/placeholder switches to `answer>` while pending.

Edge cases:

- `{:athena_done, _}` / `{:athena_error, _}` clear any pending question (the
  blocked tool process is gone).
- Empty input while pending is ignored — no accidental empty answers.
- TUI death while the tool is blocked is already handled by the tool's own
  monitor (`{:DOWN, ...}` → error result telling the model to proceed).

### 4. Testing (TDD)

- `State` reducer tests (pure): ask-question entry rendering data, answer
  routing, option-index resolution (valid index / out-of-range / free-form),
  clearing on `athena_done`/`athena_error`.
- `Runner.build_run_opts/2`: asserts AskUser present in tools and
  `assigns.ask_user` set to the target pid.
- Mode validation: `/mode orchestrate` accepted by `Commands`/`parse_mode_atom`,
  `--mode orchestrate` accepted by the mix task.
- No terminal automation required; all logic under test is pure or plain
  functions.

### 5. Docs

- Update `commands.ex` help text (part of §1).
- Note: `docs/04-modes.md` does not mention orchestrate at all and
  `ExAthena.Loop.Mode`'s moduledoc omits it from its builtin list — pre-existing
  gaps; fix the one-line moduledoc/help mentions only if touched, otherwise
  leave for the docs follow-up (avoid scope creep).
