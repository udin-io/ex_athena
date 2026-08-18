# ADR 34: Sandbox Fail-Closed With `confine: :best_effort` Opt-Out

**Status:** Accepted

## Context

Issue #135 (July 2026 security audit): when a run is confined
(`confine: true` / `allowed_roots: [...]`) but the host has no OS sandbox
helper (`sandbox-exec` on macOS, `bwrap` on Linux), the Bash tool ran the
command **unconfined** with only a `Logger.warning`. The "confined" contract
silently degraded to "unconfined" on exactly the hosts where the caller asked
for a security boundary — a classic fail-open. Log lines are not a policy
surface: hosts and callers had no programmatic signal, and the model kept
executing shell commands outside the boundary the host believed was in force.

The issue proposed a `sandbox: :required | :preferred | :off` run option with
hosts defaulting to `:required`, or at minimum a telemetry event and a
UI-visible notice.

## Decision

1. **Fail closed by default.** When confinement is requested and
   `ExAthena.Sandbox.wrap/4` reports no helper, `bash` refuses to run and
   returns the typed error `{:error, {:sandbox_unavailable, helper}}` where
   `helper` is `ExAthena.Sandbox.required_helper/0` (`"sandbox-exec"` /
   `"bwrap"`). The refusal reaches the model as a normal tool error and the
   host through the standard tool-result/event surface, so it is UI-visible
   per call.

2. **One knob, not two.** Rather than a parallel `sandbox:` option, the
   posture rides the existing `confine:` idiom: every current confinement
   form (`confine: true`, `allowed_roots: [...]`, host default via
   `confine_default?/0`) means **enforced**; the new `confine: :best_effort`
   value is the explicit opt-out that restores warn-and-run-unconfined for
   callers who accept degradation (e.g. containers that are themselves the
   boundary). The mode is carried on `ExAthena.ToolContext.confine_mode`
   (`:enforced` default | `:best_effort`).

3. **Telemetry either way.** Both paths emit
   `[:ex_athena, :sandbox, :unavailable]` with
   `%{helper, outcome (:denied | :ran_unconfined), session_id}`.

4. **Subagents inherit the mode clamped** (extends the issue #130 invariant):
   an `:enforced` parent always spawns `:enforced` children; only a
   `:best_effort` parent propagates `:best_effort`. A child is never weaker
   than its parent.

5. **Detection seam.** `Sandbox.wrap/4` / `available?/1` accept a `:finder`
   option (default `&System.find_executable/1`); `bash` reads a host-supplied
   finder from `ctx.assigns[:sandbox_finder]`. Host/test-controlled only,
   never model-controlled — it lets tests simulate a helperless machine
   without global state, keeping the suite async and platform-independent.

## Consequences

**Positive:**
- The confinement contract is real: "confined" can no longer silently mean
  "unconfined". The failure is typed, names the missing helper, and is
  observable via telemetry.
- No breaking change for the library default (unconfined runs untouched);
  hosts without helpers get a loud, actionable error instead of a quiet hole.
- Degradation is a deliberate, per-run, host-level decision with an audit
  trail.

**Negative / Trade-offs:**
- Confined runs on helperless hosts now see `bash` fail where it used to
  "work". That is the point, but hosts that relied on the old behaviour must
  either install the helper or pass `confine: :best_effort`.
- `EX_ATHENA_CONFINE=0` remains an explicit, documented way to turn
  confinement off entirely for first-party hosts — unchanged by this ADR
  (it is a user decision, not a silent fallback).
