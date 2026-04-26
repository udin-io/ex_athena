defmodule ExAthena.Sessions.Stores.Jsonl do
  @moduledoc """
  ETS-buffered JSONL session store.

  Hot-path appends go to an in-memory ETS table keyed by monotonic
  time so writes never block the loop. A background process flushes
  buffered events to JSONL files every 250ms (or immediately when
  forced via `flush/1`).

  Path: `<root>/<session_id>.jsonl`. `root` defaults to
  `<cwd>/.exathena/sessions/`; configurable via the `:root` option
  passed to `start_link/1`.

  Each JSONL line is one event: `{"ts": "...", "event": "...",
  "data": {...}, "uuid": "..."}`.
  """

  @behaviour ExAthena.Sessions.Store

  use GenServer

  @flush_interval_ms 250
  @table __MODULE__.Buffer

  # ── GenServer lifecycle ──────────────────────────────────────────

  @doc """
  Options:

    * `:root` (default: `Path.join(File.cwd!(), ".exathena/sessions")`)
    * `:flush_interval_ms` (default 250).
    * `:name` (default `__MODULE__`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    root =
      Keyword.get_lazy(opts, :root, fn ->
        Path.join(File.cwd!(), ".exathena/sessions")
      end)

    File.mkdir_p!(root)

    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:ordered_set, :public, :named_table, write_concurrency: true])

      _ ->
        :ok
    end

    interval = Keyword.get(opts, :flush_interval_ms, @flush_interval_ms)
    schedule_flush(interval)

    {:ok, %{root: root, interval: interval}}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    do_flush(state.root)
    schedule_flush(state.interval)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    do_flush(state.root)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:reset, root}, _from, state) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    target = root || state.root
    File.rm_rf!(target)
    File.mkdir_p!(target)
    {:reply, :ok, %{state | root: target}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    do_flush(state.root)
    :ok
  end

  # ── Public helpers ───────────────────────────────────────────────

  @doc "Force a synchronous flush (for tests + clean shutdown)."
  @spec flush(GenServer.server()) :: :ok
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  @doc "Test helper: clear all buffered events + storage root."
  @spec reset(String.t() | nil) :: :ok
  def reset(root \\ nil), do: GenServer.call(__MODULE__, {:reset, root})

  # ── Store callbacks ──────────────────────────────────────────────

  @impl ExAthena.Sessions.Store
  def append(session_id, event) when is_binary(session_id) and is_map(event) do
    ensure_table()
    key = {session_id, :erlang.monotonic_time()}
    :ets.insert(@table, {key, event})
    :ok
  end

  @impl ExAthena.Sessions.Store
  def read(session_id) when is_binary(session_id) do
    # Force a flush so on-disk content reflects the latest hot-path appends.
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> flush()
    end

    path = path_for(session_id)

    case File.read(path) do
      {:ok, body} ->
        events =
          body
          |> String.split("\n", trim: true)
          |> Enum.map(&decode_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, events}

      {:error, :enoent} ->
        {:ok, []}

      err ->
        err
    end
  end

  @impl ExAthena.Sessions.Store
  def list do
    case GenServer.whereis(__MODULE__) do
      nil ->
        []

      _pid ->
        flush()
        root = current_root()

        case File.ls(root) do
          {:ok, entries} ->
            entries
            |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
            |> Enum.map(&Path.basename(&1, ".jsonl"))

          _ ->
            []
        end
    end
  end

  @impl ExAthena.Sessions.Store
  def tail(session_id, n) when is_binary(session_id) and is_integer(n) and n > 0 do
    case read(session_id) do
      {:ok, events} -> {:ok, Enum.take(events, -n)}
      err -> err
    end
  end

  @doc "Resolved storage path for a session id (for tests + tooling)."
  @spec path_for(String.t()) :: String.t()
  def path_for(session_id) do
    Path.join(current_root(), "#{session_id}.jsonl")
  end

  defp current_root do
    case GenServer.whereis(__MODULE__) do
      nil ->
        Path.join(File.cwd!(), ".exathena/sessions")

      pid ->
        :sys.get_state(pid).root
    end
  end

  # ── Internal ─────────────────────────────────────────────────────

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:ordered_set, :public, :named_table, write_concurrency: true])

      _ ->
        :ok
    end
  end

  defp schedule_flush(interval), do: Process.send_after(self(), :flush, interval)

  defp do_flush(root) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        # Drain the table by session and append each session's events to its
        # JSONL file in monotonic order.
        events_by_session =
          :ets.tab2list(@table)
          |> Enum.group_by(fn {{sid, _ts}, _ev} -> sid end, fn {{_sid, ts}, ev} ->
            {ts, ev}
          end)

        Enum.each(events_by_session, fn {sid, items} ->
          sorted = items |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
          path = Path.join(root, "#{sid}.jsonl")
          File.mkdir_p!(Path.dirname(path))

          payload =
            sorted
            |> Enum.map_join("", fn ev -> Jason.encode!(ev) <> "\n" end)

          _ = File.write(path, payload, [:append])
        end)

        :ets.delete_all_objects(@table)
    end
  end

  defp decode_line(line) do
    case Jason.decode(line, keys: :atoms!) do
      {:ok, %{event: event_name} = map} when is_binary(event_name) ->
        # JSON has no atom type — coerce the event name back to an atom
        # for shape-parity with newly-built events from `Store.new_event/2`.
        Map.put(map, :event, String.to_atom(event_name))

      {:ok, map} ->
        map

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
