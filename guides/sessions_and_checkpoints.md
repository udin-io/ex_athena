# Sessions + checkpoints (v0.4)

v0.4 makes sessions durable, replayable, and recoverable.

- **`ExAthena.Sessions.Store`** — append-only event-log behaviour.
  Two stores ship: in-memory (default) and ETS-buffered JSONL.
- **`Session.resume/2`** — rebuilds the message history from any store.
- **`ExAthena.Checkpoint`** — file-history snapshots before every
  `Edit` / `Write`, which `ExAthena.Chats.rewind/3` uses to put files
  back.

## The Store behaviour

```elixir
defmodule ExAthena.Sessions.Store do
  @callback append(session_id, event) :: :ok
  @callback read(session_id) :: {:ok, [event]}
  @callback list() :: [session_id]
  @callback tail(session_id, n) :: {:ok, [event]}
end
```

Events are maps:

```elixir
%{
  ts: "2026-04-26T12:34:56.789Z",
  event: :user_message,    # atom
  data: %{message: ...},   # event-specific payload
  uuid: "kY7vZb3eQa..."    # stable per-event id
}
```

`Store.new_event/2` builds events with timestamp + uuid stamped.

### Built-in stores

#### `Stores.InMemory`

ETS-backed (`:ordered_set`, monotonic-time keyed). Default store. The
application supervisor keeps a single named GenServer alive so the
table is shared across the BEAM. Ephemeral — events vanish on restart.

#### `Stores.Jsonl`

ETS-buffered with periodic flush (default 250ms). Hot-path appends
never block on I/O. Files at `<root>/<session_id>.jsonl` (root
defaults to `<cwd>/.exathena/sessions/`). Synchronous `Jsonl.flush/1`
for tests + clean shutdown.

```elixir
{:ok, _pid} = ExAthena.Sessions.Stores.Jsonl.start_link(
  root: "/var/lib/myapp/sessions",
  flush_interval_ms: 500
)
```

The store also handles JSON's no-atom-type quirk: on read, the
`event` field is coerced back to an atom so reconstructed events match
the shape of `Store.new_event/2` output.

## Session integration

`ExAthena.Session.start_link/1` accepts `:store`:

```elixir
{:ok, pid} = ExAthena.Session.start_link(
  provider: :ollama,
  model: "qwen2.5-coder",
  tools: :all,
  store: :jsonl,           # :in_memory (default), :jsonl, or a custom module
  session_id: "deploy-123" # optional — auto-generates when omitted
)
```

What gets persisted:

- On start: `:session_start` event.
- On every `send_message/2`:
  - `:user_message` for the inbound prompt.
  - After the loop returns, the GenServer walks `result.messages` and
    emits one event per new entry: `:assistant_message` for assistant
    turns, `:tool_result` for tool-role messages.

### Resume

```elixir
# Read events back and rebuild the message list.
{:ok, prior_messages} = ExAthena.Session.resume("deploy-123", store: :jsonl)

# Pass into a fresh Session via :messages.
{:ok, pid} = ExAthena.Session.start_link(
  store: :jsonl,
  session_id: "deploy-123",
  messages: prior_messages,
  provider: :ollama, model: "qwen2.5-coder", tools: :all
)
```

Permissions deliberately do NOT survive resume — Claude Code's design
pattern: each session re-establishes trust with the host. The caller
is expected to set `:phase`, `:can_use_tool`, etc. on the resumed
session.

## Checkpointing

Every `Tools.Edit` and `Tools.Write` invocation calls
`Checkpoint.snapshot/3` before mutating. Snapshots live at:

```
<cwd>/.exathena/file-history/<session_id>/<sha>/<version>.bin
```

- `<sha>` is the SHA-256 of the absolute file path (so two paths that
  share a basename never collide).
- `<version>` is 0-indexed, incremented on each new edit. Identical
  contents reuse the latest version (idempotent).
- A `path` sidecar file in the directory records the original absolute
  path.
- Tombstones (`<v>.tombstone`) mark "this file didn't exist at
  checkpoint time" so rewind removes the file rather than restoring
  empty bytes.

Snapshots only fire when the `ToolContext` carries a non-empty
`session_id`. Failures are silently swallowed — the safety net is
best-effort, not a correctness gate.

## Rewind

Rewind works on a saved chat (`ExAthena.Chats`), by step:

```elixir
{:ok, %{steps_dropped: n, files_restored: m}} =
  ExAthena.Chats.rewind(chat_id, step_uuid)
```

The chat goes on from `step_uuid`; the steps after it stay in the file but
leave the active history. Each version in the file history lists the tool
calls that took it, so rewind puts back, per file, the version from just
before the first dropped call. A file the dropped steps created is removed.
Only calls that the rewind drops move a file: a call a compaction
summarised, or one an earlier rewind already undid, keeps its effect. Pass
`restore_files: false` to keep the files as they are.

The file history sits inside the project, where the model can write, so
rewind skips an entry whose folder is not the hash of its path, whose path
leaves the chat's folder or crosses a symlink, or whose saved version is not
a plain file. Files are put back before the rewind is recorded, and the
result names any file it could not write (`files_failed`).

Each edit also notes what it left in the file, and each snapshot marks its
version when the file no longer held that note (someone else changed it in
between). Rewind puts a file back only while it still holds what the chat
last wrote and no marked version lies past the point it goes back to, so a
change by another chat, a fork or a person is never undone: the file is
left as it is and named in `files_failed`. A file whose history sits in two
folders (a `/cd` between its edits) is named the same way. Rewind
reads the history of every folder the chat worked in. A fork has no file
history from before the fork, so rewinding a fork past that point puts back
none of those files.

Version files are matched to steps by tool call id, so a provider that
reuses one call id across turns can make rewind put back a file a kept step
changed.

A front end that keeps its own copy of a chat passes the version it last
read: `Chats.sync(id, messages, expect: version)` returns `{:error, :moved}`
once another front end added a turn or rewound the chat, so a stale copy
never writes over that work.

Rewind and fork refuse a chat while a turn runs in it (`{:error, :busy}`).
A front end holds the chat for its turn with `ExAthena.Chats.hold/1`: a
lock file next to the chat, so the hold covers the terminal UI and the web
UI even though they run as separate programs. A lock whose program has
exited is taken over.

For the file history to line up, the loop's `session_id` must be the chat
id: that is the folder `Checkpoint.snapshot/4` writes under.

## TTL sweeper

`ExAthena.Storage.Sweeper` runs once at application boot and removes
`.exathena/file-history` and `.exathena/sessions` entries, and saved
chats in `~/.ex_athena/chats`, that nothing has touched for 30 days. Retention is per directory and settable
in the web settings modal ("On-disk history"); `0` keeps that directory
forever.

An entry counts as old only when nothing anywhere inside it has changed
within the window, and `<id>.jsonl` is kept or removed together with
`<id>/`, so resuming a session protects its worker transcripts too.

Disable the sweep entirely via `:enable_storage_sweeper`:

```elixir
config :ex_athena, enable_storage_sweeper: false
```

Same pattern as the `WorktreeSweeper` (see
[agents + subagents](agents_subagents.md)).

## Custom stores

Implement the `ExAthena.Sessions.Store` behaviour:

```elixir
defmodule MyApp.PubSubStore do
  @behaviour ExAthena.Sessions.Store

  @impl true
  def append(session_id, event) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "session:#{session_id}", {:event, event})
    MyApp.Repo.insert(MyApp.SessionEvent.changeset(%MyApp.SessionEvent{}, %{
      session_id: session_id,
      ts: event.ts,
      kind: event.event,
      data: event.data,
      uuid: event.uuid
    }))

    :ok
  end

  @impl true
  def read(session_id) do
    events =
      MyApp.Repo.all(from e in MyApp.SessionEvent,
        where: e.session_id == ^session_id,
        order_by: e.inserted_at)
      |> Enum.map(&to_event/1)

    {:ok, events}
  end

  # ... list/0, tail/2 ...
end

ExAthena.Session.start_link(
  provider: :ollama,
  store: MyApp.PubSubStore,
  ...
)
```

## See also

- [`ExAthena.Sessions.Store`](https://hexdocs.pm/ex_athena/ExAthena.Sessions.Store.html)
- [`ExAthena.Sessions.Stores.InMemory`](https://hexdocs.pm/ex_athena/ExAthena.Sessions.Stores.InMemory.html)
- [`ExAthena.Sessions.Stores.Jsonl`](https://hexdocs.pm/ex_athena/ExAthena.Sessions.Stores.Jsonl.html)
- [`ExAthena.Checkpoint`](https://hexdocs.pm/ex_athena/ExAthena.Checkpoint.html)
- [Agents + subagents](agents_subagents.md) — sidechain transcripts use
  the same JSONL pattern.
