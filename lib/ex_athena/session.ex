defmodule ExAthena.Session do
  @moduledoc """
  GenServer that owns a multi-turn conversation.

  A `Session` is the right abstraction when you want:

    * the message history to persist across multiple user turns,
    * resumable state across LiveView reconnects,
    * streaming deltas broadcast to subscribers,
    * an identifiable process pid / name you can monitor.

  For one-shot agent runs, use `ExAthena.Loop.run/2` directly. For truly
  stateless single-turn inference, `ExAthena.query/2`.

  ## Usage

      {:ok, pid} = ExAthena.Session.start_link(
        provider: :ollama,
        model: "llama3.1",
        tools: :all,
        cwd: "/path/to/project"
      )

      {:ok, result} = ExAthena.Session.send_message(pid, "read mix.exs and list deps")
      IO.puts(result.text)

      ExAthena.Session.stop(pid)

  Each `send_message` appends to the session's message list, runs the agent
  loop to completion, and returns the final result. Subsequent messages
  include the full prior history, so the model has context.

  ## Session resume

  Pass `:messages` to `start_link/1` to seed the conversation with a prior
  history, typically obtained from `resume/2`:

      {:ok, msgs} = ExAthena.Session.resume(session_id, store: :ets)
      {:ok, pid}  = ExAthena.Session.start_link(
        provider: :ollama,
        messages: msgs,
        session_id: session_id
      )

  When the configured store implements `ExAthena.Sessions.SchemaStore`
  (currently only `ETS`), the session also dual-writes every message to the
  row tables so `resume/2` can read from them directly.
  """

  use GenServer

  alias ExAthena.Loop
  alias ExAthena.Messages
  alias ExAthena.Sessions.{SchemaStore, Store}
  alias ExAthena.Sessions.Stores.{ETS, InMemory, Jsonl}
  alias ExAthena.Telemetry

  # ── Client API ─────────────────────────────────────────────────────

  @doc """
  Start a session. Accepts the same options as `ExAthena.Loop.run/2` plus:

    * `:name` — GenServer name.
    * `:system_prompt` — pinned system prompt used on every turn.
    * `:store` — `:in_memory` (default), `:ets`, `:jsonl`, or a custom module
      implementing `ExAthena.Sessions.Store`. Per-turn events are persisted
      via the chosen store; `resume/2` reads them back.
    * `:messages` — seed the conversation with a prior message history (e.g.
      from `resume/2`). Each entry is passed through `Messages.from_map/1`.
    * `:session_id` — reuse a stable id from a prior session; generated if
      absent.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Resume a session by reading prior messages back from a store.

  ## Options

    * `:store` — `:in_memory` (default), `:ets`, `:jsonl`, or a module.
      When the store implements `SchemaStore`, the row tables are queried
      directly; otherwise the event-log is replayed.
    * `:as` — shape of the returned payload:
      - `:messages` (default) — `{:ok, [Message.t()]}`, backwards compatible.
      - `:state` — `{:ok, %Loop.State{messages: ..., session_id: ...}}`.
      - `:map` — `{:ok, %{session_id:, messages:, last_user:, last_assistant:}}`.
    * `:replay_last_user_turn` — when `true`, drops the trailing assistant
      message (and any trailing non-user messages) so callers can re-feed
      the last user prompt. Defaults to `false`.

  Emits `[:ex_athena, :session, :resume]` telemetry with measurements
  `%{message_count: n}` and metadata `%{session_id:, source:, store:}`.
  """
  @spec resume(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def resume(session_id, opts \\ []) when is_binary(session_id) do
    store = resolve_store(Keyword.get(opts, :store, :in_memory))
    as = Keyword.get(opts, :as, :messages)
    replay = Keyword.get(opts, :replay_last_user_turn, false)

    source = if SchemaStore.implements?(store), do: :schema_store, else: :event_log

    with {:ok, messages} <- load_messages(store, session_id, source) do
      messages = if replay, do: trim_to_last_user(messages), else: messages

      Telemetry.event(
        [:ex_athena, :session, :resume],
        %{message_count: length(messages)},
        %{session_id: session_id, source: source, store: store}
      )

      {:ok, shape_payload(as, session_id, messages)}
    end
  end

  @doc "Send a user message; blocks until the loop terminates."
  @spec send_message(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(server, message, opts \\ []) do
    GenServer.call(server, {:send_message, message, opts}, :infinity)
  end

  @doc "Return the current message list (for debugging / persistence)."
  @spec messages(GenServer.server()) :: [map()]
  def messages(server), do: GenServer.call(server, :messages)

  @doc "Return the stable session id assigned at start."
  @spec session_id(GenServer.server()) :: String.t()
  def session_id(server), do: GenServer.call(server, :session_id)

  @doc "Stop the session."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal)

  # ── Server ──────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    session_id = Keyword.get(opts, :session_id) || generate_session_id()
    opts = Keyword.put(opts, :session_id, session_id)
    store = resolve_store(Keyword.get(opts, :store, :in_memory))

    seed_messages =
      opts
      |> Keyword.get(:messages, [])
      |> Enum.map(&Messages.from_map/1)

    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    _ =
      store.append(
        session_id,
        Store.new_event(:session_start, %{ts: ts, resumed: seed_messages != []})
      )

    if SchemaStore.implements?(store) do
      store.put_session(%{id: session_id, created_at: ts, updated_at: ts})
    end

    {:ok,
     %{
       opts: opts,
       session_id: session_id,
       store: store,
       messages: seed_messages,
       usage: nil
     }}
  end

  @impl GenServer
  def handle_call({:send_message, message, extra_opts}, _from, state) do
    loop_opts =
      state.opts
      |> Keyword.merge(extra_opts)
      |> Keyword.put(:messages, state.messages)
      |> Keyword.put(:session_id, state.session_id)

    _ =
      state.store.append(
        state.session_id,
        Store.new_event(:user_message, %{message: %{role: :user, content: message}})
      )

    maybe_schema_put_message(state.store, state.session_id, :user, %{
      role: :user,
      content: message
    })

    case Loop.run(message, loop_opts) do
      {:ok, result} ->
        new_messages = Enum.drop(result.messages, length(state.messages) + 1)

        Enum.each(new_messages, &persist_message(&1, state))

        state = %{
          state
          | messages: result.messages,
            usage: merge_usage(state.usage, result.usage)
        }

        {:reply, {:ok, result}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:messages, _from, state), do: {:reply, state.messages, state}

  def handle_call(:session_id, _from, state), do: {:reply, state.session_id, state}

  # ── Internal ────────────────────────────────────────────────────────

  defp persist_message(msg, state) do
    event_kind = role_to_event_kind(msg.role)
    serialized = serialize_message(msg)
    state.store.append(state.session_id, Store.new_event(event_kind, %{message: serialized}))
    maybe_schema_put_message(state.store, state.session_id, msg.role, serialized)
  end

  defp role_to_event_kind(:assistant), do: :assistant_message
  defp role_to_event_kind(:tool), do: :tool_result
  defp role_to_event_kind(:user), do: :user_message
  defp role_to_event_kind(:system), do: :system_message

  defp maybe_schema_put_message(store, session_id, role, content) do
    if SchemaStore.implements?(store) do
      store.put_message(%{
        id: SchemaStore.new_message_id(),
        session_id: session_id,
        role: role,
        content: content,
        ts: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end
  end

  defp load_messages(store, session_id, :schema_store) do
    case store.list_messages(session_id) do
      {:ok, rows} ->
        messages =
          rows
          |> Enum.sort_by(& &1.seq)
          |> Enum.map(fn row -> Messages.from_map(row.content) end)

        {:ok, messages}

      err ->
        err
    end
  end

  defp load_messages(store, session_id, :event_log) do
    with {:ok, events} <- store.read(session_id) do
      messages =
        events
        |> Enum.flat_map(fn
          %{event: :user_message, data: %{message: m}} -> [m]
          %{event: :assistant_message, data: %{message: m}} -> [m]
          _ -> []
        end)
        |> Enum.map(&Messages.from_map/1)

      {:ok, messages}
    end
  end

  defp trim_to_last_user(messages) do
    messages
    |> Enum.reverse()
    |> Enum.drop_while(&(&1.role != :user))
    |> Enum.reverse()
  end

  defp shape_payload(:messages, _session_id, messages), do: messages

  defp shape_payload(:state, session_id, messages) do
    %Loop.State{messages: messages, session_id: session_id}
  end

  defp shape_payload(:map, session_id, messages) do
    last_user = messages |> Enum.filter(&(&1.role == :user)) |> List.last()
    last_assistant = messages |> Enum.filter(&(&1.role == :assistant)) |> List.last()

    %{
      session_id: session_id,
      messages: messages,
      last_user: last_user,
      last_assistant: last_assistant
    }
  end

  defp merge_usage(nil, new), do: new
  defp merge_usage(old, nil), do: old

  defp merge_usage(old, new) do
    %{
      input_tokens: sum(old[:input_tokens], new[:input_tokens]),
      output_tokens: sum(old[:output_tokens], new[:output_tokens]),
      total_tokens: sum(old[:total_tokens], new[:total_tokens])
    }
  end

  defp sum(nil, b), do: b
  defp sum(a, nil), do: a
  defp sum(a, b), do: a + b

  defp generate_session_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp resolve_store(:in_memory), do: InMemory
  defp resolve_store(:jsonl), do: Jsonl
  defp resolve_store(:ets), do: ETS
  defp resolve_store(mod) when is_atom(mod), do: mod

  defp serialize_message(msg) do
    %{
      role: msg.role,
      content: msg.content,
      name: Map.get(msg, :name),
      tool_calls: serialize_tool_calls(Map.get(msg, :tool_calls)),
      tool_results: serialize_tool_results(Map.get(msg, :tool_results))
    }
  end

  defp serialize_tool_calls(nil), do: nil

  defp serialize_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn tc ->
      %{id: tc.id, name: tc.name, arguments: tc.arguments}
    end)
  end

  defp serialize_tool_results(nil), do: nil

  defp serialize_tool_results(results) when is_list(results) do
    Enum.map(results, fn tr ->
      %{
        tool_call_id: tr.tool_call_id,
        content: tr.content,
        is_error: tr.is_error,
        ui_payload: tr.ui_payload
      }
    end)
  end
end
