# ADR: Session.resume reads SchemaStore with event-log fallback; Session dual-writes

## Status

Accepted

## Context

Sub-ticket 1 of the session persistence parent ticket added `ExAthena.Sessions.SchemaStore` (sessions/messages/snapshots row-shaped tables) and `Stores.ETS` implementing both that behaviour and the legacy append-only `Sessions.Store` event log. The original `Sessions.Store` is still in use: `ExAthena.Session` writes turn events through `store.append/2` and reconstructs history through `store.read/1` on resume.

Sub-tickets 3 (checkpoint/fork) and 4 (rewind/snapshot index) need O(log n) message-row primitives — `list_messages/1`, `delete_messages_after/2`, `put_snapshot/1`. They cannot use the event-log because event replay is O(n) and structurally cannot key off message ids.

This sub-ticket (PR2 — Session.resume) sits between the data layer and the higher-level lifecycle features. It must:

1. Make `Session.resume/2` work against the new SchemaStore tables (otherwise sub-tickets 3–4 are read-only — there is nothing for them to fork or rewind from).
2. Stay backwards compatible with the InMemory and Jsonl stores, which do **not** implement SchemaStore.
3. Not require Session callers to know which behaviour their store implements.

Two design questions surfaced:

- **Where do messages get written?** Today, only to the event log. To enable SchemaStore-based reads, message rows must also be populated. Options: (a) make Session dual-write opportunistically, (b) project event-log entries into row tables on read, (c) require the store to dual-write internally.
- **What does resume return?** Today it returns a flat `[Message.t()]`. The parent ticket says it should return "a state ready to either continue or re-run the last user turn". Options: (a) keep the list, (b) return a `%Loop.State{}` directly, (c) return a tagged map with `last_user` / `last_assistant` extracted, (d) all of the above behind an `:as` option.

## Decision

1. **Opportunistic dual-write at the Session layer.** When `store` implements `ExAthena.Sessions.SchemaStore` (detected via a new `SchemaStore.implements?/1` helper that checks `function_exported?/3` for every required callback), `Session.init/1` calls `store.put_session/1` and `Session.handle_call({:send_message, ...}, _, _)` calls `store.put_message/1` for the user message and every loop-emitted message. The event-log write is **kept** so existing read paths and the SSE bus (future server-mode ticket) continue to work. Stores that do not implement SchemaStore (InMemory, Jsonl) see zero behavioural change.

2. **`Session.resume/2` reads from SchemaStore when available, event-log otherwise.** Detection uses the same `SchemaStore.implements?/1` helper. The SchemaStore path calls `list_messages/1`, sorts by `:seq` defensively, and pipes each row's `:content` through `ExAthena.Messages.from_map/1`. The event-log path is the existing fold (extended to also include `:tool_result` events, which the current implementation drops on the floor).

3. **`:as` option chooses the return shape.** Backwards-compatible default `:messages` returns `[Message.t()]`. `:state` returns `%ExAthena.Loop.State{messages: msgs, session_id: sid}` with all other fields at struct defaults. `:map` returns `%{session_id, messages, last_user, last_assistant}`. The `Loop.State` form is intentionally sparse: provider, tools, hooks, and ctx are per-call configuration that callers re-supply on the next `Loop.run/2` or `Session.start_link/1`. The struct serves as a typed message-carrier so udin_code's `SessionResume` can return a typed value rather than a tuple.

4. **`:replay_last_user_turn` boolean trims the trailing assistant turn.** When `true`, drops messages after the last user message so callers can re-run an interrupted turn.

5. **`Session.start_link(:messages)` is honoured.** Today the docstring claims this works but `init/1` ignores it. We seed `state.messages` from the option (normalised through `Messages.from_map/1`) so the documented round-trip (`resume` → `start_link(messages: ...)` → `send_message`) actually preserves history.

6. **Telemetry: single discrete event `[:ex_athena, :session, :resume]`** via `ExAthena.Telemetry.event/3`. Measurements `%{message_count: n}`. Metadata `%{session_id, source: :schema_store | :event_log, store: module()}`. No span — resume is a one-shot read.

## Consequences

**Positive:**

- Sub-tickets 3 (checkpoint/fork) and 4 (rewind) inherit fully populated row tables, with no further write-path work.
- Existing InMemory + Jsonl tests continue to pass unmodified — the dual-write is gated on `implements?/1`.
- The `:as => :state` shape gives udin_code (and any host) a typed handle to plug straight into Loop.State without manual struct construction.
- BEAM-restart durability is testable: write through Jsonl, wipe ETS, run `migrate_jsonl/1`, resume — covered by an integration test in this sub-ticket.

**Negative / trade-offs:**

- Two writes per turn when the store implements both behaviours (event log + N message rows). Acceptable: ETS inserts are sub-microsecond; Jsonl users still single-write because Jsonl does not implement SchemaStore.
- `function_exported?/3`-based behaviour detection at every Session call. Mitigated by `Code.ensure_loaded?/1` once at start; the per-message check is essentially free.
- The `Loop.State` returned by `:as => :state` has many unset fields (provider_mod, tool_modules, ctx, etc.). This is intentional but could be misleading — documented in the `@doc` that the caller must reconfigure these on the next loop call.
- Three return shapes (`:messages`, `:state`, `:map`) is more API surface than the current single-list shape. Bounded by the `:as` keyword so callers opt into complexity.

**Forward-compatibility:**

- Sub-ticket 3's `Session.fork/2` will read messages via `SchemaStore.list_messages/1` and write the new session via `put_session/1` + `put_message/1` — same primitives this sub-ticket exercises.
- Sub-ticket 4's `Session.rewind/3` will use `delete_messages_after/2` and the snapshot index. Resume after a rewind will Just Work because the SchemaStore rows are the source of truth.
- The future SSE event-bus ticket (out of scope) will subscribe to the existing event-log appends; dual-writing keeps the bus surface intact.
