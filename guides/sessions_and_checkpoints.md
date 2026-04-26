# Sessions + checkpoints (v0.4)

v0.4 makes sessions durable, replayable, and recoverable.

- **`ExAthena.Sessions.Store`** — append-only event-log behaviour.
  Two stores ship: in-memory (default) and ETS-buffered JSONL.
- **`Session.resume/2`** — rebuilds the message history from any store.
- **`ExAthena.Checkpoint`** — file-history snapshots before every
  `Edit` / `Write`, plus a `/rewind` API that restores files +
  truncates the session log.

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

```elixir
{:ok, %{files_restored: n, events_dropped: m}} =
  ExAthena.Checkpoint.rewind(session_id, mode, opts)
```

Two modes:

| Mode | Effect |
|---|---|
| `:code_and_history` | Restore each checkpointed file to its version-0 snapshot AND truncate the JSONL session log to the chosen `to_uuid`. |
| `:history_only` | Only truncate the JSONL — files keep their current contents. |

Required option:

- `:to_uuid` — the event UUID at which to truncate. Find it in the
  `Result.messages` history or the JSONL log.

Optional:

- `:cwd` — defaults to `File.cwd!/0`.

```elixir
# Walk back the entire session: restore every file the agent touched.
{:ok, _} = ExAthena.Checkpoint.rewind(session_id, :code_and_history,
  cwd: project_root,
  to_uuid: "first-event-uuid")

# Just drop the conversation context — keep the files as-is.
{:ok, _} = ExAthena.Checkpoint.rewind(session_id, :history_only,
  to_uuid: bad_branch_event_uuid)
```

## TTL sweeper

`ExAthena.Checkpoint.Sweeper` runs once at application boot and
removes file-history directories older than 30 days. Disable via
`:enable_checkpoint_sweeper`:

```elixir
config :ex_athena, enable_checkpoint_sweeper: false
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
