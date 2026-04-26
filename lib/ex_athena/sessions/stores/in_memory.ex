defmodule ExAthena.Sessions.Stores.InMemory do
  @moduledoc """
  ETS-backed in-memory session store. Default; ephemeral.

  All events live in a single shared `:ordered_set` ETS table keyed by
  `{session_id, monotonic_time}` so reads are naturally in append-order
  without a per-event cursor.
  """

  @behaviour ExAthena.Sessions.Store

  @table __MODULE__

  use GenServer

  # ── GenServer lifecycle ──────────────────────────────────────────

  @doc false
  def start_link(_arg \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:ordered_set, :public, :named_table, read_concurrency: true])

      _ ->
        :ok
    end

    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # ── Store callbacks ──────────────────────────────────────────────

  @impl ExAthena.Sessions.Store
  def append(session_id, event) when is_binary(session_id) and is_map(event) do
    ensure_table()
    key = {session_id, monotonic()}
    :ets.insert(@table, {key, event})
    :ok
  end

  @impl ExAthena.Sessions.Store
  def read(session_id) when is_binary(session_id) do
    ensure_table()

    events =
      :ets.match_object(@table, {{session_id, :_}, :_})
      |> Enum.sort_by(fn {{_sid, ts}, _ev} -> ts end)
      |> Enum.map(fn {_, ev} -> ev end)

    {:ok, events}
  end

  @impl ExAthena.Sessions.Store
  def list do
    ensure_table()

    :ets.match(@table, {{:"$1", :_}, :_})
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

  @doc "Test helper: wipe all events. Not part of the Store contract."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:ordered_set, :public, :named_table, read_concurrency: true])

      _ ->
        :ok
    end
  end

  defp monotonic, do: :erlang.monotonic_time()
end
