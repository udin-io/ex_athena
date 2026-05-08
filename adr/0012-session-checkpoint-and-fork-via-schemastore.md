# ADR — `Session.checkpoint/2` and `Session.fork/2` via `SchemaStore`

## Status

Accepted (sub-ticket 3 of 4 under issue #25).

## Context

Sub-ticket 1 shipped `ExAthena.Sessions.SchemaStore` (a row-shaped behaviour) and `ExAthena.Sessions.Stores.ETS` (the first implementation, with `sessions`, `messages`, `snapshots`, `events` tables). Sub-ticket 2 shipped `Session.resume/2` and made `Session` dual-write messages to the row tables when the configured store implements `SchemaStore`.

This sub-ticket adds two authoring primitives — `checkpoint/2` (named savepoint within a session) and `fork/2` (clone a session up to a savepoint into a new session id with parent linkage). Both are pure store operations: they do not interact with the running `Session` GenServer process and do not need to know about `Loop.State` shape.

Several design decisions need recording:

1. Should `fork/2` copy snapshot rows by default? They reference `message_id`s, which we are rewriting during the clone.
2. What is the idempotency contract for `checkpoint/2` — anchor-only or anchor + label?
3. Should `checkpoint/2` snapshot the whole message list, or just metadata about the anchor?
4. What happens when the configured store does not implement `SchemaStore` (e.g. `:in_memory` or `:jsonl`)?

## Decision

1. **Both functions require `SchemaStore`.** When `SchemaStore.implements?(store)` is `false`, return `{:error, :unsupported_store}` and emit no telemetry. Reason: row-shaped CRUD is the only way to do this efficiently; replaying an event log to clone a session would be a footgun and would silently exclude `:jsonl` users from `/undo` semantics.
2. **`checkpoint/2` stores metadata, not the full transcript.** The snapshot row carries `%{label, message_count, anchor_seq, metadata}`. The message rows themselves are the durable transcript; `rewind/3` (sub-ticket 4) will use `delete_messages_after/2` to truncate to the anchor without needing a redundant copy of every prior message inside each snapshot.
3. **`checkpoint/2` is idempotent on `(message_id, label, metadata)`.** A repeat call against the same anchor with the same label/metadata returns the existing snapshot row. Different labels at the same anchor produce distinct rows — operators may want to mark the same fork-point with multiple semantic names. Telemetry includes an `idempotent: bool` flag so a UI can distinguish "new checkpoint" from "reused checkpoint".
4. **`fork/2` does NOT carry snapshots by default.** Snapshot ids reference message ids that we are rewriting during the clone; copying them silently would bury the rewrite. Callers opt in via `copy_snapshots: true`, in which case we rewrite each carried snapshot's `message_id` to the new clone's id and assign a fresh `snapshot_id`.
5. **No new behaviour callbacks.** Both functions are implemented entirely on top of the `SchemaStore` callbacks already shipped in sub-ticket 1: `get_session/1`, `put_session/1`, `list_messages/1`, `put_message/1`, `list_snapshots/1`, `put_snapshot/1`, `get_snapshot/1`.
6. **Fresh per-message ids and fresh `seq` values in the fork.** Each cloned message gets a fresh `id` from `SchemaStore.new_message_id/0` and a fresh monotonic `seq` so the new session has its own ordered timeline independent of the source.

## Consequences

### Positive

- Stores remain the single source of truth; no parallel persistence layer.
- Idempotency is observable to operators via the `idempotent: true` telemetry flag.
- Snapshot payloads stay small (constant-size metadata, not O(n) message bytes), keeping the ETS `snapshots` table compact.
- Future row-shaped stores (e.g. a Postgres-backed `SchemaStore`) get `checkpoint/2` and `fork/2` for free with no code changes.
- Cleanly separates the two persistence behaviours: `Store` (event log) for sequential replay, `SchemaStore` (row tables) for random access. Fork/checkpoint are firmly in the latter camp.

### Negative

- `:in_memory` and `:jsonl` users cannot use these primitives. This is acceptable because both stores already lack the random-access semantics the primitives need; recommending `:ets` (or a future row store) is the correct guidance.
- Idempotency comparison is a linear scan over `list_snapshots/1`. Sub-ticket 4 may add an index if the snapshot count grows large enough to matter.
- Cloning a session with thousands of messages is O(n) message inserts. This is fine for ETS; future SQL-backed stores can override with a single `INSERT ... SELECT` once they implement their own `Session.fork/2` fast path.
- `:in_memory`/`:jsonl` callers must explicitly opt into `:ets` (or migrate via `ETS.migrate_jsonl/1` already shipped in sub-ticket 1) before they can call these primitives — a documented breaking expectation, but not a code break.
