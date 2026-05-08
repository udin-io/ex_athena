# ADR: `Session.rewind/3` and ETS snapshot index for `/undo`

## Status

Accepted (sub-ticket 4 of 4 — feat(sessions): finish session persistence).

## Context

The parent ticket finishes session persistence by adding rewind on top of the already-merged resume / checkpoint / fork primitives. Two design questions had to be answered:

1. **Public API shape for rewind.** `checkpoint/2` and `fork/2` use `(session_id, opts)`. Rewind takes one extra discriminator (snapshot vs. message anchor), and the parent description explicitly says `rewind/3`.
2. **How to make snapshot lookup fast enough for `/undo`.** Today `Stores.ETS.get_snapshot/1` wildcards over the snapshot table (O(n) over all snapshot rows). A typical `/undo` flow may resolve a snapshot id once per keystroke; an O(1) path is appropriate.

## Decision

**1. Public API:**

```elixir
@spec rewind(String.t(), {:snapshot, String.t()} | {:message, String.t()}, keyword()) ::
        {:ok, map()} | {:error, term()}
```

- Tagged-tuple anchor (`{:snapshot, id}` / `{:message, id}`) keeps the call site explicit and gives `rewind` its `/3` arity without a sentinel option.
- Same store-gating as `checkpoint/2`/`fork/2`: requires a `SchemaStore` implementation, otherwise `{:error, :unsupported_store}`.
- Implementation reuses the existing `SchemaStore.delete_messages_after/2` callback — no new behaviour callbacks.
- Emits `[:ex_athena, :session, :rewind]` with measurements `%{messages_deleted, message_count}` and metadata `%{session_id, anchor_message_id, target, store}`.
- Snapshots whose anchor message is now beyond the rewound transcript are **kept** (they remain valid redo targets for a future ticket).

**2. Snapshot index:**

Add a new ETS `:set` table `:ex_athena_snapshot_index` inside `Stores.ETS` keyed by `snapshot_id` mapping to `{session_id, message_id}`. The table is an internal implementation detail — no public API or behaviour-callback change.

- `put_snapshot/1` dual-writes (primary table + index).
- `delete_snapshots_for_session/1` also `match_delete`s the index.
- `delete_session/1` cleans the index transitively via `delete_snapshots_for_session/1`.
- `get_snapshot/1` becomes O(1): index lookup → primary lookup by full key.
- The `reset/0` test helper wipes the index along with the other tables.

## Consequences

**Positive**
- `/undo` flows pay O(1) for snapshot resolution; before, every resolution scanned the snapshot table.
- Tagged-tuple anchor is unambiguous and pattern-matches cleanly inside `do_rewind`.
- Snapshots are preserved across rewinds, leaving the door open for a `/redo` sub-ticket without a data migration.
- `SchemaStore` callbacks are unchanged: stores other than ETS continue to work without backfilling an index.

**Negative**
- Two-table consistency for snapshots: any future `delete_snapshot/1` must update both tables. Mitigated by keeping mutation paths (`put_snapshot/1`, `delete_snapshots_for_session/1`, `delete_session/1`) confined to the ETS module and exercised by the new test cases.
- Tagged-tuple anchor diverges slightly from `checkpoint`/`fork`'s opts-only style; the consistency cost is small and the explicitness wins.

**Neutral**
- Snapshots beyond the rewind anchor remain in storage. Storage is in-memory ETS; redo without an explicit purge is acceptable for v1.
