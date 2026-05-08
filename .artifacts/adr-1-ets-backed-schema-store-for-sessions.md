# ADR 1: ETS-backed schema store for sessions

**Status:** Proposed

## Context

The parent ticket *feat(sessions): finish session persistence — resume, checkpoint, fork, undo/redo* introduces operations (resume from a snapshot, fork from a message id, /undo to a prior turn) that need O(1)/O(log n) row-level lookups by `session_id`, `message_id`, and `snapshot_id`. The current `ExAthena.Sessions.Store` behaviour is event-log-shaped — `append/2`, `read/1`, `list/0`, `tail/2`. Layering row queries on top would require a linear scan of the entire transcript on every fork or undo.

The audit explicitly forbids SQLite (no `exqlite` dependency), so we cannot adopt the OpenCode SQLite-via-Drizzle scheme directly. ETS ships with OTP, gives us O(1) lookup on `:set` and O(log n) ordered range scans on `:ordered_set`, and is the natural fit for in-process row storage. Disk durability is already covered by the existing `ExAthena.Sessions.Stores.Jsonl` implementation, so the new store does not need its own disk format — it just needs a way to import what is already on disk.

This sub-ticket lands the row schema and the migration helper. Sub-tickets 2-4 (resume / checkpoint+fork / rewind) consume the new API.

## Decision

1. **Introduce `ExAthena.Sessions.SchemaStore` as a new behaviour** alongside the existing event-log `ExAthena.Sessions.Store`. The new behaviour defines a row-shaped API: `put_session`, `get_session`, `list_sessions`, `delete_session`, `put_message`, `list_messages`, `delete_messages_after`, `delete_messages_for_session`, `put_snapshot`, `get_snapshot`, `list_snapshots`, `delete_snapshots_for_session`. The behaviour also exposes `new_message_id/0` and `new_snapshot_id/0` helpers (16-byte base64, matching the existing `Session.generate_session_id/0` pattern).

2. **Provide `ExAthena.Sessions.Stores.ETS` as the first implementation.** It owns three named ETS tables for the schema layer plus a fourth for legacy event-log compat:

   - `:ex_athena_session_rows` — `:set`, key = `session_id`.
   - `:ex_athena_message_rows` — `:ordered_set`, key = `{session_id, seq, message_id}`.
   - `:ex_athena_snapshot_rows` — `:ordered_set`, key = `{session_id, message_id, snapshot_id}`.
   - `:ex_athena_session_events` — `:ordered_set`, key = `{session_id, monotonic_ts}`.

   `:ordered_set` keys give us prefix-range scans by `session_id` for free.

3. **The same module also implements the legacy `Store` behaviour** so callers can pick `store: :ets` from `ExAthena.Session` and inherit both APIs against one supervised GenServer. The v0.4.8 `Session.resume/2` shim continues to work with `store: :ets` until sub-ticket 2 rewires it to the schema layer.

4. **Disk durability stays delegated to `Stores.Jsonl`.** A new `ExAthena.Sessions.Stores.ETS.migrate_jsonl/1` helper reads `<sid>.jsonl` files from a configurable root (default `.exathena/sessions`), folds the event stream into row records, and inserts them through the public CRUD path. Idempotent via an `:overwrite` flag (default `true`). Snapshots are not synthesised because there are no `:snapshot` events in the v0.4.8 JSONL format.

5. **`put_message/1` assigns `seq` from `:erlang.unique_integer([:monotonic, :positive])`** when the caller didn't supply one, which gives stable insertion order even when ISO timestamps tie. `delete_messages_after/2` keeps the anchor row (rewind contract — sub-ticket 4 needs the anchor to survive). `delete_session/1` cascades into `delete_messages_for_session/1` and `delete_snapshots_for_session/1`.

6. **`ExAthena.Sessions.Stores.ETS` is added to the `ExAthena.Application` supervision tree** alongside the existing `Stores.InMemory`, and `ExAthena.Session.resolve_store/1` gains a `:ets` clause.

## Consequences

**Positive**

- Sub-tickets 2-4 inherit O(log n) row lookups and ordered range scans without writing any new persistence code.
- No new runtime dependency — ETS ships with OTP.
- Existing event-log consumers (current `Session.resume/2`, `Agents.Sidechain.write/1`) keep working unchanged with `store: :ets`.
- Migration is a pure function over the JSONL source — easy to test, easy to re-run.
- Two `:ordered_set` tables keyed on `(session_id, …)` make per-session queries naturally indexed; we never need to filter in Elixir.

**Negative**

- ETS is in-memory; durability across BEAM restarts requires the JSONL → ETS migration on boot. Sub-ticket 2 will wire that automatically; until then it is a manual call.
- Two behaviours to keep in lockstep (`Store` and `SchemaStore`). Mitigated by having one ETS module implement both, and by sub-tickets 2-4 standardising on `SchemaStore` for new code.
- `get_snapshot/1` is a linear scan in the v1 ETS implementation. Sub-ticket 4 will add a secondary index if /undo lookups become a hot path.
- The `:overwrite` flag changes migration semantics; tests cover both branches but operators need to know which they want.

**Neutral**

- The four ETS tables live in one supervised GenServer process. If that process crashes, all four tables die with it. This is acceptable because the migration helper can rebuild from the JSONL on disk; sub-ticket 2 will document the boot-time rebuild path.
