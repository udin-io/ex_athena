# ADR 0010 — ETS-backed Schema Store for Sessions

**Status:** Accepted

## Context

Parent ticket calls for OpenCode-style row-shaped persistence (sessions /
messages / snapshots) but explicitly forbids SQLite. The existing
`Sessions.Store` behaviour is event-log-shaped; layering row queries on top
would require linear scans on every fork / undo / snapshot lookup.

## Decision

Introduce `ExAthena.Sessions.SchemaStore` as a new behaviour alongside the
existing event-log `Store`. Provide `ExAthena.Sessions.Stores.ETS` as the
first implementation, owning four named ETS tables:

| Table                          | Type           | Key                                     |
|--------------------------------|----------------|-----------------------------------------|
| `:ex_athena_session_rows`      | `:set`         | `session_id`                            |
| `:ex_athena_message_rows`      | `:ordered_set` | `{session_id, seq, message_id}`         |
| `:ex_athena_snapshot_rows`     | `:ordered_set` | `{session_id, message_id, snapshot_id}`|
| `:ex_athena_session_events`    | `:ordered_set` | `{session_id, monotonic_time}`          |

The same module also implements the existing `Store` behaviour so callers can
choose `store: :ets` and get both APIs against one supervised GenServer. Disk
durability stays delegated to `Stores.Jsonl` and is rebuilt via
`migrate_jsonl/1` at boot.

## Consequences

- **(+)** Sub-tickets 2–4 inherit O(log n) row lookups and ordered range scans
  via `:ets.match_object/2` prefix patterns.
- **(+)** No new runtime dependency; ETS ships with OTP.
- **(+)** Existing event-log consumers (current `Session.resume/2`, sidechain
  writer) keep working with `store: :ets`.
- **(−)** ETS is in-memory; durability requires the JSONL → ETS migration on
  boot (sub-ticket 2 will wire that automatically).
- **(−)** Two behaviours to keep in sync. Mitigated by having one ETS module
  implement both.
