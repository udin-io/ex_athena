defmodule ExAthena.Web.Sessions do
  @moduledoc """
  Session persistence for the web UI.

  A chat's messages, title, folder, provider, model and permission live in the
  shared chat record (`ExAthena.Chats`), which the terminal UI reads and writes
  too. The web UI also keeps how it drew the chat (tool panels, the details
  stream, the Overview) as a cache under `~/.ex_athena/web/sessions/`, one
  Erlang term file per chat. `load/1` uses the cache while its messages match
  the record, and rebuilds the view from the record otherwise: a chat started
  in the terminal, or one the terminal went on with.

  A compact JSON index at ~/.ex_athena/web/recent.json tracks the most recently
  opened working directories so users can jump back to a project quickly.
  """

  alias ExAthena.Chat.Permission
  alias ExAthena.Chats
  alias ExAthena.Tuning

  @default_base_dir "~/.ex_athena/web"
  @max_recent 20

  @doc """
  Root of the on-disk session store.

  Configurable (`config :ex_athena, :web_dir, path`) so tests can point the
  store at a `@tag :tmp_dir` directory instead of the developer's real one.
  """
  @spec base_dir() :: Path.t()
  def base_dir do
    :ex_athena
    |> Application.get_env(:web_dir, @default_base_dir)
    |> Path.expand()
  end

  # ---------------------------------------------------------------------------
  # Sessions
  # ---------------------------------------------------------------------------

  @doc """
  Writes `data` to `path` readable by its owner only (0600).

  The file is created empty and restricted before the content goes in, so the
  content is never readable by others, even briefly.
  """
  @spec write_private!(Path.t(), iodata()) :: :ok
  def write_private!(path, data) do
    unless File.exists?(path) do
      File.touch!(path)
    end

    File.chmod!(path, 0o600)
    File.write!(path, data)
  end

  @doc """
  Restricts the store to its owner: the folder and the sessions folder 0700,
  every file in them 0600. Run at start, to close what an older version left
  open.
  """
  @spec secure_store!() :: :ok
  def secure_store! do
    base = ensure_base!()
    sessions = sessions_dir()

    for dir <- [base, sessions], name <- File.ls!(dir) do
      path = Path.join(dir, name)
      if File.regular?(path), do: File.chmod!(path, 0o600)
    end

    :ok
  end

  @doc "List all session headers, newest first, from the shared chat record."
  @spec list() :: [map()]
  def list do
    Chats.list()
    |> Enum.map(fn chat ->
      %{
        id: chat.id,
        title: chat[:title],
        cwd: chat[:cwd],
        provider: provider_name(chat[:provider]),
        model: chat[:model],
        permission: chat[:permission],
        updated_at: chat.updated_at
      }
    end)
    |> sort_by_recency()
  end

  @doc """
  Order session headers newest-first.

  Sorts with the `DateTime` module rather than raw term order. `%DateTime{}`
  values compared as plain terms go key-by-key in ascending key order, which
  reaches `:day` long before `:month` or `:year` — so `~U[2026-05-31]` sorts
  above `~U[2026-08-10]` and the sidebar ends up ordered by day-of-month.

  A header with a missing or malformed timestamp sorts last instead of raising.
  """
  @spec sort_by_recency([map()]) :: [map()]
  def sort_by_recency(headers) do
    Enum.sort_by(headers, &recency_key/1, {:desc, DateTime})
  end

  defp recency_key(header) do
    case Map.get(header, :updated_at) do
      %DateTime{} = dt -> dt
      _ -> ~U[1970-01-01 00:00:00Z]
    end
  end

  @doc "List session headers for a specific working directory, newest first."
  @spec list_for_cwd(String.t()) :: [map()]
  def list_for_cwd(cwd) do
    list() |> Enum.filter(&(&1[:cwd] == cwd))
  end

  @doc """
  Persist a session: its messages and header to the shared chat record, and
  the web UI's view of it to the cache. Overwrites the cache if the id exists.
  """
  @spec save(map()) :: :ok | {:error, term()}
  def save(%{id: id} = data) do
    with :ok <- Chats.save(id, record_fields(data), Map.get(data, :ex_messages) || []) do
      write_private!(cache_path(id), :erlang.term_to_binary(Map.put(data, :record, true)))
    end
  end

  @doc """
  When the record of `data.id` moved past `data.record_version` (another
  front end added a turn or rewound it), save `data` as a new chat forked
  from it and return `{:moved, new_id}`; otherwise `:current`. The web UI
  calls this before a turn, so its stale copy never writes over that work.
  """
  @spec fork_if_moved(map()) :: :current | {:moved, String.t()} | {:error, term()}
  def fork_if_moved(%{id: id} = data) do
    case {Chats.version(id), Map.get(data, :record_version)} do
      {{:ok, v}, expected} when is_integer(expected) and v != expected ->
        fields = data |> record_fields() |> Map.put(:forked_from, %{chat: id, step: nil})

        with {:ok, %{id: new_id}} <- Chats.create(fields),
             :ok <- save(%{data | id: new_id}) do
          {:moved, new_id}
        end

      _ ->
        :current
    end
  end

  @doc """
  Move every chat saved before the shared record into it, once. Returns how
  many moved. A cache already marked as moved is left alone, so a chat the
  cleanup removed from the record does not come back.
  """
  @spec migrate!() :: non_neg_integer()
  def migrate! do
    dir = sessions_dir()

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".session"))
    |> Enum.count(fn file ->
      with {:ok, data} <- read_cache(Path.join(dir, file)),
           false <- Map.get(data, :record, false),
           id = Path.basename(file, ".session"),
           :ok <- save(Map.put(data, :id, id)) do
        keep_age(id, Map.get(data, :updated_at))
        true
      else
        _ -> false
      end
    end)
  end

  # A moved chat keeps its age, so the list's order and the cleanup still
  # read when it was last used.
  defp keep_age(id, %DateTime{} = at), do: File.touch(Chats.path(id), DateTime.to_unix(at))
  defp keep_age(_id, _), do: :ok

  defp record_fields(data) do
    %{
      title: Map.get(data, :title),
      cwd: Map.get(data, :cwd),
      model: Map.get(data, :model),
      provider: provider_atom(Map.get(data, :provider)),
      permission: data |> Map.get(:permission) |> Permission.parse()
    }
  end

  defp provider_atom(nil), do: nil
  defp provider_atom(p) when is_atom(p), do: p

  defp provider_atom(p) when is_binary(p) do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> p
  end

  defp provider_name(nil), do: nil
  defp provider_name(p), do: to_string(p)

  @doc """
  Durably append a completed run's final assistant message to its session.

  Used by the run task so the answer survives even when the LiveView process
  that started the run has died (e.g. a websocket reconnect mid-run sends the
  final `{:athena_done, result}` to a now-dead pid). Load-modify-save, and
  **idempotent by `msg_id`** — a no-op if the LiveView already persisted that
  message, so the LiveView's richer (tool-event-bearing) version is preserved.

  An `orchestrator` snapshot, when given, is always written: it is the run's
  terminal Overview state and is strictly newer than anything an autosave
  could have stored.
  """
  @spec append_run_result(String.t(), String.t(), map(), map(), map() | nil) :: :ok
  def append_run_result(session_id, msg_id, assistant_msg, result, orchestrator \\ nil) do
    case load(session_id) do
      {:ok, data} ->
        case merge_run_result(data, msg_id, assistant_msg, result, orchestrator) do
          {:save, merged} -> save(merged)
          :skip -> :ok
        end

      # No session file yet (never saved) — nothing to attach to.
      {:error, _} ->
        :ok
    end
  end

  @doc false
  @spec merge_run_result(map(), String.t(), map(), map(), map() | nil) :: {:save, map()} | :skip
  def merge_run_result(data, msg_id, assistant_msg, result, orchestrator \\ nil) do
    msgs = Map.get(data, :display_messages, [])

    cond do
      not Enum.any?(msgs, &(&1.id == msg_id)) ->
        {:save,
         data
         |> Map.put(:display_messages, msgs ++ [assistant_msg])
         |> Map.put(:ex_messages, result.messages || Map.get(data, :ex_messages, []))
         |> Map.put(
           :provider_session_id,
           result.session_id || Map.get(data, :provider_session_id)
         )
         |> put_orchestrator(orchestrator)
         |> Map.put(:updated_at, DateTime.utc_now())}

      # The message was already written (a LiveView beat us to it) but the
      # Overview snapshot it saved is whatever its last autosave held — always
      # older than the terminal one, so that part is still worth writing.
      is_map(orchestrator) ->
        {:save,
         data
         |> Map.put(:orchestrator, orchestrator)
         |> Map.put(:updated_at, DateTime.utc_now())}

      true ->
        :skip
    end
  end

  defp put_orchestrator(data, nil), do: data
  defp put_orchestrator(data, snapshot), do: Map.put(data, :orchestrator, snapshot)

  @doc """
  The chat message text for a finished run, surfacing the `finish` deliverable
  so the submitted answer is always visible in the main chat.

  When the run ended via `finish` (`finish_reason: :submitted`) with a
  deliverable: it becomes the message text if nothing was streamed (the
  orchestrator delegated and only submitted a deliverable), or is appended to
  the streamed text otherwise — unless that text already contains it. Any other
  termination keeps the streamed text unchanged.
  """
  @spec final_message_text(String.t(), ExAthena.Result.t()) :: String.t()
  def final_message_text(stream_text, %{finish_reason: :submitted, deliverable: d})
      when is_binary(d) and d != "" do
    cond do
      String.trim(stream_text) == "" -> d
      String.contains?(stream_text, String.trim(d)) -> stream_text
      true -> stream_text <> "\n\n" <> d
    end
  end

  def final_message_text(stream_text, _result), do: stream_text

  @doc """
  Build a run's final assistant message from the `Result` alone (no live UI
  state) and durably append it to the session. The durable path for when the
  process that owns the run wants the answer saved regardless of whether a
  LiveView is currently attached. Idempotent by `msg_id` (see
  `append_run_result/5`), except for the optional terminal `orchestrator`
  snapshot, which is always written.
  """
  @spec persist_run_result(String.t(), String.t(), ExAthena.Result.t(), map() | nil) :: :ok
  def persist_run_result(session_id, msg_id, result, orchestrator \\ nil) do
    usage = result.usage || %{}

    status = %{
      iterations: result.iterations || 0,
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0),
      cost_usd: result.cost_usd || 0.0
    }

    msg = %{
      id: msg_id,
      role: :assistant,
      text: final_message_text(to_string(result.text || ""), result),
      tool_events: [],
      status: status,
      ex_snapshot: result.messages
    }

    append_run_result(session_id, msg_id, msg, result, orchestrator)
  rescue
    _ -> :ok
  end

  @doc """
  Load a full session by id: the record's messages and header, with the
  web UI's cached view when it still matches them.
  """
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(id) do
    with true <- Chats.valid_id?(id) || {:error, :invalid_id} do
      cache = read_cache(cache_path(id))

      case Chats.load(id) do
        {:ok, chat} -> {:ok, view(chat, cache)}
        {:error, :not_found} -> load_unmoved(id, cache)
        err -> err
      end
    end
  end

  # A cache with no record: an old chat not moved yet moves now; one already
  # moved lost its record to the cleanup and goes too.
  defp load_unmoved(id, {:ok, %{record: true}}) do
    _ = File.rm(cache_path(id))
    {:error, :enoent}
  end

  defp load_unmoved(id, {:ok, data}) do
    with :ok <- save(Map.put(data, :id, id)), do: load(id)
  end

  defp load_unmoved(_id, _), do: {:error, :enoent}

  defp view(chat, {:ok, data}) do
    cached = Enum.map(Map.get(data, :ex_messages) || [], &Chats.as_saved/1)

    k = length(cached)

    cond do
      cached == chat.messages ->
        Map.merge(data, header(chat))

      # The record went on past the cached view (a turn in the terminal):
      # keep the cached turns as drawn and add the new ones from the record.
      k > 0 and Enum.take(chat.messages, k) == cached ->
        data
        |> Map.merge(header(chat))
        |> Map.update(:display_messages, [], &(&1 ++ display_messages(chat.steps, k)))

      true ->
        rebuilt_view(chat)
    end
  end

  defp view(chat, _), do: rebuilt_view(chat)

  defp header(chat) do
    %{
      id: chat.id,
      title: chat[:title],
      cwd: chat[:cwd],
      provider: provider_name(chat[:provider]),
      model: chat[:model],
      permission: chat[:permission],
      ex_messages: chat.messages,
      record_version: chat.version
    }
  end

  # One user message and one reply per turn, each reply carrying the history
  # up to it so the details stream and fork can be rebuilt from it.
  defp rebuilt_view(chat) do
    chat
    |> header()
    |> Map.merge(%{
      created_at: parse_time(chat[:created_at]),
      updated_at: chat.updated_at,
      display_messages: display_messages(chat.steps),
      provider_session_id: nil,
      tool_uis: %{},
      details_stream: [],
      orchestrator: nil
    })
  end

  defp display_messages(steps, skip \\ 0) do
    messages = Enum.map(steps, & &1.message)

    steps
    |> Enum.with_index(1)
    |> Enum.drop(skip)
    |> Enum.chunk_while(
      [],
      fn {%{message: m}, _} = item, acc ->
        if m.role == :user and acc != [],
          do: {:cont, Enum.reverse(acc), [item]},
          else: {:cont, [item | acc]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.flat_map(&turn_messages(&1, messages))
  end

  defp turn_messages([{%{message: %{role: :user} = user, uuid: uuid}, _} | rest], messages) do
    [display_user(uuid, user) | turn_reply(rest, messages)]
  end

  defp turn_messages(items, messages), do: turn_reply(items, messages)

  defp turn_reply([], _messages), do: []

  defp turn_reply(items, messages) do
    {%{uuid: uuid}, last_index} = List.last(items)

    text =
      items
      |> Enum.map(fn {%{message: m}, _} -> m end)
      |> Enum.filter(&(&1.role == :assistant and is_binary(&1.content) and &1.content != ""))
      |> Enum.map_join("\n\n", & &1.content)

    [
      %{
        id: uuid,
        role: :assistant,
        text: text,
        tool_events: [],
        status: nil,
        ex_snapshot: Enum.take(messages, last_index)
      }
    ]
  end

  defp display_user(uuid, %{content: content}) do
    text =
      case content do
        text when is_binary(text) ->
          text

        parts when is_list(parts) ->
          parts |> Enum.filter(&(&1.type == :text)) |> Enum.map_join("\n", & &1.text)

        _ ->
          ""
      end

    %{id: uuid, role: :user, text: text, images: [], tool_events: [], status: nil}
  end

  defp parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_time(_), do: DateTime.utc_now()

  @doc "Delete a chat: its record and the web UI's cached view of it."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id) do
    with :ok <- Chats.delete(id) |> ok_if_missing() do
      File.rm(cache_path(id)) |> ok_if_missing()
    end
  end

  defp ok_if_missing({:error, :enoent}), do: :ok
  defp ok_if_missing(other), do: other

  defp cache_path(id), do: Path.join(sessions_dir(), "#{id}.session")

  # ---------------------------------------------------------------------------
  # Recently opened working directories
  # ---------------------------------------------------------------------------

  @doc """
  Return the list of recently opened working directories, newest first.
  Each entry: %{cwd: path, name: basename, opened_at: DateTime.t()}
  """
  @spec list_recent() :: [map()]
  def list_recent do
    case File.read(recent_path()) do
      {:ok, json} ->
        json
        |> Jason.decode!(keys: :atoms)
        |> Enum.map(fn entry ->
          opened_at =
            case DateTime.from_iso8601(entry.opened_at) do
              {:ok, dt, _} -> dt
              _ -> DateTime.utc_now()
            end

          %{cwd: entry.cwd, name: Path.basename(entry.cwd), opened_at: opened_at}
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc "Record a working directory as recently opened (deduplicates, capped by `:ui, :max_recent_dirs`)."
  @spec touch_recent(String.t()) :: :ok
  def touch_recent(cwd) do
    existing = list_recent()

    updated =
      [%{cwd: cwd, name: Path.basename(cwd), opened_at: DateTime.utc_now()} | existing]
      |> Enum.uniq_by(& &1.cwd)
      |> Enum.take(Tuning.get(:ui, :max_recent_dirs, @max_recent))

    payload =
      Enum.map(updated, fn e ->
        %{cwd: e.cwd, opened_at: DateTime.to_iso8601(e.opened_at)}
      end)

    ensure_base!()
    write_private!(recent_path(), Jason.encode!(payload))
    :ok
  rescue
    _ -> :ok
  end

  @doc "Remove a working directory from the recent list."
  @spec remove_recent(String.t()) :: :ok
  def remove_recent(cwd) do
    updated = list_recent() |> Enum.reject(&(&1.cwd == cwd))

    payload =
      Enum.map(updated, fn e ->
        %{cwd: e.cwd, opened_at: DateTime.to_iso8601(e.opened_at)}
      end)

    ensure_base!()
    write_private!(recent_path(), Jason.encode!(payload))
    :ok
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp sessions_dir do
    dir = Path.join(base_dir(), "sessions")
    ensure_base!()
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  defp ensure_base! do
    base = base_dir()
    File.mkdir_p!(base)
    File.chmod!(base, 0o700)
    base
  end

  defp recent_path, do: Path.join(base_dir(), "recent.json")

  defp read_cache(path) do
    with {:ok, bin} <- File.read(path),
         data when is_map(data) <- :erlang.binary_to_term(bin, [:safe]) do
      {:ok, data}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
