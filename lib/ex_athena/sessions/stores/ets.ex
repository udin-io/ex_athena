defmodule ExAthena.Sessions.Stores.ETS do
  @moduledoc """
  ETS-backed store implementing both `ExAthena.Sessions.Store` (event-log)
  and `ExAthena.Sessions.SchemaStore` (row-shaped sessions / messages /
  snapshots).

  ## Tables

  | Name                           | Type           | Key                                        |
  |--------------------------------|----------------|--------------------------------------------|
  | `:ex_athena_session_rows`      | `:set`         | `session_id`                               |
  | `:ex_athena_message_rows`      | `:ordered_set` | `{session_id, seq, message_id}`            |
  | `:ex_athena_snapshot_rows`     | `:ordered_set` | `{session_id, message_id, snapshot_id}`    |
  | `:ex_athena_session_events`    | `:ordered_set` | `{session_id, monotonic_time}`             |

  The GenServer owns table creation. All public CRUD operations work
  without the GenServer's pid — reads are lock-free.

  ## Durability

  ETS is in-memory; data survives process crashes (tables are public) but
  not BEAM restarts. Call `migrate_jsonl/1` at boot to replay an existing
  JSONL store into the row tables.
  """

  @behaviour ExAthena.Sessions.Store
  @behaviour ExAthena.Sessions.SchemaStore

  use GenServer

  @sessions_table :ex_athena_session_rows
  @messages_table :ex_athena_message_rows
  @snapshots_table :ex_athena_snapshot_rows
  @events_table :ex_athena_session_events

  @all_tables [@sessions_table, @messages_table, @snapshots_table, @events_table]

  # ── GenServer lifecycle ──────────────────────────────────────────────

  @doc false
  def start_link(_arg \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    ensure_tables()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    Enum.each(@all_tables, fn t ->
      if :ets.whereis(t) != :undefined, do: :ets.delete_all_objects(t)
    end)

    {:reply, :ok, state}
  end

  # ── Public helpers ───────────────────────────────────────────────────

  @doc "Test helper: wipe all tables. Not part of the Store contract."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # ── SchemaStore callbacks — sessions ────────────────────────────────

  @impl ExAthena.Sessions.SchemaStore
  def put_session(session) when is_map(session) do
    ensure_tables()
    :ets.insert(@sessions_table, {session.id, session})
    :ok
  end

  @impl ExAthena.Sessions.SchemaStore
  def get_session(session_id) when is_binary(session_id) do
    ensure_tables()

    case :ets.lookup(@sessions_table, session_id) do
      [{_, session}] -> {:ok, session}
      [] -> {:error, :not_found}
    end
  end

  @impl ExAthena.Sessions.SchemaStore
  def list_sessions do
    ensure_tables()
    :ets.tab2list(@sessions_table) |> Enum.map(&elem(&1, 1))
  end

  @impl ExAthena.Sessions.SchemaStore
  def delete_session(session_id) when is_binary(session_id) do
    ensure_tables()
    :ets.delete(@sessions_table, session_id)
    delete_messages_for_session(session_id)
    delete_snapshots_for_session(session_id)
    :ok
  end

  # ── SchemaStore callbacks — messages ─────────────────────────────────

  @impl ExAthena.Sessions.SchemaStore
  def put_message(message) when is_map(message) do
    ensure_tables()
    seq = Map.get_lazy(message, :seq, fn -> :erlang.unique_integer([:monotonic, :positive]) end)
    message = Map.put(message, :seq, seq)
    :ets.insert(@messages_table, {{message.session_id, seq, message.id}, message})
    :ok
  end

  @impl ExAthena.Sessions.SchemaStore
  def list_messages(session_id) when is_binary(session_id) do
    ensure_tables()

    msgs =
      :ets.match_object(@messages_table, {{session_id, :_, :_}, :_})
      |> Enum.map(&elem(&1, 1))

    {:ok, msgs}
  end

  @impl ExAthena.Sessions.SchemaStore
  def delete_messages_after(session_id, message_id)
      when is_binary(session_id) and is_binary(message_id) do
    ensure_tables()

    case anchor_seq(session_id, message_id) do
      nil ->
        :ok

      seq ->
        :ets.select_delete(@messages_table, [
          {{{session_id, :"$1", :_}, :_}, [{:>, :"$1", seq}], [true]}
        ])

        :ok
    end
  end

  @impl ExAthena.Sessions.SchemaStore
  def delete_messages_for_session(session_id) when is_binary(session_id) do
    ensure_tables()
    :ets.match_delete(@messages_table, {{session_id, :_, :_}, :_})
    :ok
  end

  # ── SchemaStore callbacks — snapshots ────────────────────────────────

  @impl ExAthena.Sessions.SchemaStore
  def put_snapshot(snapshot) when is_map(snapshot) do
    ensure_tables()

    :ets.insert(
      @snapshots_table,
      {{snapshot.session_id, snapshot.message_id, snapshot.id}, snapshot}
    )

    :ok
  end

  @impl ExAthena.Sessions.SchemaStore
  def get_snapshot(snapshot_id) when is_binary(snapshot_id) do
    ensure_tables()

    case :ets.match_object(@snapshots_table, {{:_, :_, snapshot_id}, :_}) do
      [{_, snapshot}] -> {:ok, snapshot}
      [] -> {:error, :not_found}
    end
  end

  @impl ExAthena.Sessions.SchemaStore
  def list_snapshots(session_id) when is_binary(session_id) do
    ensure_tables()

    snaps =
      :ets.match_object(@snapshots_table, {{session_id, :_, :_}, :_})
      |> Enum.map(&elem(&1, 1))

    {:ok, snaps}
  end

  @impl ExAthena.Sessions.SchemaStore
  def delete_snapshots_for_session(session_id) when is_binary(session_id) do
    ensure_tables()
    :ets.match_delete(@snapshots_table, {{session_id, :_, :_}, :_})
    :ok
  end

  # ── Store callbacks (event-log) ──────────────────────────────────────

  @impl ExAthena.Sessions.Store
  def append(session_id, event) when is_binary(session_id) and is_map(event) do
    ensure_tables()
    key = {session_id, :erlang.monotonic_time()}
    :ets.insert(@events_table, {key, event})
    :ok
  end

  @impl ExAthena.Sessions.Store
  def read(session_id) when is_binary(session_id) do
    ensure_tables()

    events =
      :ets.match_object(@events_table, {{session_id, :_}, :_})
      |> Enum.sort_by(fn {{_sid, ts}, _ev} -> ts end)
      |> Enum.map(&elem(&1, 1))

    {:ok, events}
  end

  @impl ExAthena.Sessions.Store
  def list do
    ensure_tables()

    :ets.match(@events_table, {{:"$1", :_}, :_})
    |> List.flatten()
    |> Enum.uniq()
  end

  @impl ExAthena.Sessions.Store
  def tail(session_id, n) when is_binary(session_id) and is_integer(n) and n > 0 do
    case read(session_id) do
      {:ok, events} -> {:ok, Enum.take(events, -n)}
      err -> err
    end
  end

  # ── Migration helper ─────────────────────────────────────────────────

  @doc """
  Import sessions from a JSONL root directory into the ETS row tables.

  Options:
    * `:root` — directory of `<sid>.jsonl` files. Defaults to
      `Path.join(File.cwd!(), ".exathena/sessions")`.
    * `:overwrite` — when `true` (default), existing rows for a session are
      wiped before re-importing. When `false`, sessions already present in
      the store are skipped entirely.

  Returns `{:ok, %{sessions: n, messages: m}}`.
  """
  @spec migrate_jsonl(keyword()) ::
          {:ok, %{sessions: non_neg_integer(), messages: non_neg_integer()}}
  def migrate_jsonl(opts \\ []) do
    root =
      Keyword.get_lazy(opts, :root, fn ->
        Path.join(File.cwd!(), ".exathena/sessions")
      end)

    overwrite = Keyword.get(opts, :overwrite, true)

    session_files =
      case File.ls(root) do
        {:ok, entries} -> Enum.filter(entries, &String.ends_with?(&1, ".jsonl"))
        _ -> []
      end

    {total_sessions, total_messages} =
      Enum.reduce(session_files, {0, 0}, fn filename, {sess_acc, msg_acc} ->
        sid = Path.basename(filename, ".jsonl")

        if not overwrite and session_exists?(sid) do
          {sess_acc, msg_acc}
        else
          events = read_jsonl_file(Path.join(root, filename))
          {session_row, message_rows} = fold_events(sid, events)

          if overwrite do
            delete_messages_for_session(sid)
            delete_snapshots_for_session(sid)
          end

          put_session(session_row)
          Enum.each(message_rows, &put_message/1)

          {sess_acc + 1, msg_acc + length(message_rows)}
        end
      end)

    :telemetry.execute(
      [:ex_athena, :session, :migrate_jsonl],
      %{sessions: total_sessions, messages: total_messages},
      %{root: root}
    )

    {:ok, %{sessions: total_sessions, messages: total_messages}}
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp ensure_tables do
    Enum.each(
      [
        {@sessions_table, :set},
        {@messages_table, :ordered_set},
        {@snapshots_table, :ordered_set},
        {@events_table, :ordered_set}
      ],
      fn {name, type} ->
        if :ets.whereis(name) == :undefined do
          :ets.new(name, [type, :public, :named_table, read_concurrency: true])
        end
      end
    )
  end

  defp anchor_seq(session_id, message_id) do
    case :ets.match(@messages_table, {{session_id, :"$1", message_id}, :_}) do
      [[seq]] -> seq
      _ -> nil
    end
  end

  defp session_exists?(session_id) do
    case :ets.lookup(@sessions_table, session_id) do
      [_] -> true
      [] -> false
    end
  end

  defp read_jsonl_file(path) do
    case GenServer.whereis(ExAthena.Sessions.Stores.Jsonl) do
      nil ->
        read_jsonl_direct(path)

      _pid ->
        sid = path |> Path.basename(".jsonl")

        case ExAthena.Sessions.Stores.Jsonl.read(sid) do
          {:ok, events} -> events
          _ -> read_jsonl_direct(path)
        end
    end
  end

  defp read_jsonl_direct(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.map(&decode_jsonl_line/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp decode_jsonl_line(line) do
    case Jason.decode(line, keys: :atoms!) do
      {:ok, %{event: event_name} = map} when is_binary(event_name) ->
        Map.put(map, :event, String.to_atom(event_name))

      {:ok, map} ->
        map

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp fold_events(session_id, events) do
    ts_now = DateTime.utc_now() |> DateTime.to_iso8601()

    initial_session = %{
      id: session_id,
      created_at: ts_now,
      updated_at: ts_now
    }

    {session, messages, last_ts} =
      Enum.reduce(events, {initial_session, [], ts_now}, fn ev, {sess, msgs, _last_ts} ->
        case ev.event do
          :session_start ->
            created_at = ev.ts || ts_now
            {Map.merge(sess, %{created_at: created_at, updated_at: created_at}), msgs, ev.ts}

          kind when kind in [:user_message, :assistant_message, :tool_result, :system_message] ->
            role = event_kind_to_role(kind)
            content = get_in(ev, [:data, :message]) || %{}
            msg_id = ExAthena.Sessions.SchemaStore.new_message_id()

            msg = %{
              id: msg_id,
              session_id: session_id,
              role: role,
              content: content,
              ts: ev.ts
            }

            {sess, msgs ++ [msg], ev.ts}

          _ ->
            {sess, msgs, ev.ts}
        end
      end)

    session = Map.put(session, :updated_at, last_ts)
    {session, messages}
  end

  defp event_kind_to_role(:user_message), do: :user
  defp event_kind_to_role(:assistant_message), do: :assistant
  defp event_kind_to_role(:tool_result), do: :tool
  defp event_kind_to_role(:system_message), do: :system
end
