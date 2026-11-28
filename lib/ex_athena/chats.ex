defmodule ExAthena.Chats do
  @moduledoc """
  The saved chat record every front end writes and reads.

  One file per chat, `<root>/<id>.jsonl`, under a folder readable by its owner
  only (0700, each file 0600). `root` is `config :ex_athena, :chats_dir`,
  `~/.ex_athena/chats` by default.

  The file only grows. Each line is one JSON object whose `type` comes first:

    * `chat` — the first line: folder, provider, model, permission, title, and
      where a fork or a helper came from.
    * `meta` — header fields that changed (a new title, model or permission).
    * `message` — one message, with a `uuid` that names its step.
    * `compact` — compaction rewrote the history: keep the first `keep` active
      steps, then these.
    * `rewind` — the chat goes on from step `to`.

  Nothing rewrites a line, so a crash can cut at most the last one; `load/1`
  skips a line it cannot decode, and the next write starts on a fresh line.
  Steps a compaction or a rewind drops stay in the file for a later look.

  Messages go through `ExAthena.Chats.Codec`, so each one reads back exactly as
  written. Front ends hand `sync/2` their whole message list after each turn;
  it works out what is new.

  A turn in progress holds the chat with `hold/1`. `rewind/3` and `fork/2`
  refuse a held chat with `{:error, :busy}`, so neither can cut or copy a turn
  half written. The hold ends with `release/1` or when the holder exits.

  Every function refuses an id that is not 1 to 64 letters, digits, `-` or
  `_`, before any path is built from it.
  """

  alias ExAthena.Chats.Codec
  alias ExAthena.Checkpoint
  alias ExAthena.Messages.Message

  @default_dir "~/.ex_athena/chats"
  @header_fields [:cwd, :provider, :model, :permission, :title]
  @id_format ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @header_prefixes [~s({"type":"chat"), ~s({"type":"meta")]

  @type id :: String.t()
  @type step :: %{uuid: String.t(), at: String.t(), message: Message.t()}
  @type header :: %{
          required(:id) => id(),
          optional(:cwd) => String.t() | nil,
          optional(:provider) => atom() | nil,
          optional(:model) => String.t() | nil,
          optional(:permission) => atom() | nil,
          optional(:title) => String.t() | nil,
          optional(:created_at) => String.t(),
          optional(:updated_at) => DateTime.t(),
          optional(:forked_from) => %{chat: id(), step: String.t() | nil} | nil,
          optional(:parent) => %{chat: id(), step: String.t() | nil} | nil
        }

  @doc "The folder that holds every chat."
  @spec root() :: Path.t()
  def root do
    :ex_athena |> Application.get_env(:chats_dir, @default_dir) |> Path.expand()
  end

  @doc "Whether `id` may name a chat."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id), do: is_binary(id) and Regex.match?(@id_format, id)

  @doc "A new random chat id."
  @spec new_id() :: id()
  def new_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @doc "The file that holds chat `id`."
  @spec path(id()) :: Path.t()
  def path(id), do: Path.join(root(), id <> ".jsonl")

  @doc """
  Start a chat record.

  `attrs` takes `:id` (generated when absent), the header fields `:cwd`,
  `:provider`, `:model`, `:permission` and `:title`, plus `:forked_from` and
  `:parent` (`%{chat: id, step: uuid}`; a chat with a `:parent` is a helper's
  and stays out of `list/1`). Returns `{:error, :exists}` for an id in use.
  """
  @spec create(map()) :: {:ok, header()} | {:error, term()}
  def create(attrs) when is_map(attrs) do
    id = Map.get(attrs, :id) || new_id()

    with :ok <- check_id(id) do
      header =
        attrs
        |> Map.take(@header_fields ++ [:forked_from, :parent])
        |> Map.merge(%{id: id, created_at: now()})

      line = ordered([{"type", "chat"}, {"v", 1}, {"chat", Codec.encode(header)}])

      case create_file(path(id), encode_line(line)) do
        :ok -> {:ok, Map.put(header, :updated_at, DateTime.utc_now())}
        err -> err
      end
    end
  end

  @doc "Record new values for header fields (`:title`, `:model`, ...)."
  @spec update(id(), map()) :: :ok | {:error, term()}
  def update(id, fields) when is_map(fields) do
    with :ok <- check_id(id) do
      case Map.take(fields, @header_fields) do
        empty when map_size(empty) == 0 ->
          :ok

        changed ->
          append_lines(id, [
            ordered([{"type", "meta"}, {"at", now()}, {"fields", Codec.encode(changed)}])
          ])
      end
    end
  end

  @doc """
  Bring the record up to `messages`, a front end's whole history after a turn.

  When `messages` extends the active history, the new messages are added.
  When it differs earlier on (compaction replaced the middle), one `compact`
  line records the new history; the old steps stay in the file.
  """
  @spec sync(id(), [Message.t()]) :: :ok | {:error, term()}
  def sync(id, messages) when is_list(messages) do
    with :ok <- check_id(id) do
      locked(id, fn -> do_sync(id, messages) end)
    end
  end

  def sync(_id, _messages), do: {:error, :invalid_id}

  defp do_sync(id, messages) do
    with {:ok, %{steps: steps}} <- read_chat(id) do
      active = Enum.map(steps, & &1.message)
      kept = common_prefix(active, messages)
      append_lines(id, sync_lines(kept == length(active), kept, Enum.drop(messages, kept)))
    end
  end

  defp sync_lines(true, _kept, rest), do: Enum.map(rest, &message_line(new_step(&1)))

  defp sync_lines(false, kept, rest) do
    entries = Enum.map(rest, &step_object(new_step(&1)))
    [ordered([{"type", "compact"}, {"at", now()}, {"keep", kept}, {"messages", entries}])]
  end

  @doc """
  Read a chat: its header fields, `messages` (the active history) and `steps`
  (the same messages with the `uuid` and time of each).
  """
  @spec load(id()) :: {:ok, map()} | {:error, :invalid_id | :not_found | term()}
  def load(id) do
    with :ok <- check_id(id), do: read_chat(id)
  end

  @doc """
  The saved chats, newest first, as headers.

  Options: `:cwd` keeps only that folder's chats; `helpers: true` also lists
  helpers' records.
  """
  @spec list(keyword()) :: [header()]
  def list(opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    helpers? = Keyword.get(opts, :helpers, false)

    root()
    |> File.ls()
    |> case do
      {:ok, names} -> names
      _ -> []
    end
    |> Enum.flat_map(&listed_header/1)
    |> Enum.filter(&((is_nil(cwd) or &1[:cwd] == cwd) and (helpers? or is_nil(&1[:parent]))))
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  defp listed_header(name) do
    id = Path.basename(name, ".jsonl")

    with true <- String.ends_with?(name, ".jsonl") and valid_id?(id),
         {:ok, header} <- read_header(id) do
      [header]
    else
      _ -> []
    end
  end

  @doc """
  Copy a chat's steps up to `:step` (a uuid; the last step when absent) into
  a new chat that names where it came from. Options: `:step`, `:title`.
  """
  @spec fork(id(), keyword()) :: {:ok, header()} | {:error, term()}
  def fork(id, opts \\ []) do
    with :ok <- check_id(id),
         :ok <- check_idle(id),
         {:ok, chat} <- read_chat(id),
         {:ok, kept, step} <- slice(chat.steps, Keyword.get(opts, :step)) do
      attrs =
        chat
        |> Map.take(@header_fields)
        |> Map.put(:title, Keyword.get(opts, :title, chat[:title]))
        |> Map.put(:forked_from, %{chat: id, step: step})

      with {:ok, header} <- create(attrs),
           :ok <- append_lines(header.id, Enum.map(kept, &message_line/1)) do
        {:ok, header}
      end
    end
  end

  @doc """
  Make the chat go on from step `step_uuid`.

  The steps after it leave the active history but stay in the file. Each file
  the dropped steps' tool calls edited goes back to how it was, unless
  `restore_files: false`; only files inside the chat's folder are touched.
  Returns `{:ok, %{steps_dropped: n, files_restored: m, message_count: k}}`.
  """
  @spec rewind(id(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rewind(id, step_uuid, opts \\ []) do
    with :ok <- check_id(id),
         :ok <- check_idle(id) do
      locked(id, fn -> do_rewind(id, step_uuid, opts) end)
    end
  end

  defp do_rewind(id, step_uuid, opts) do
    with {:ok, chat} <- read_chat(id),
         {:ok, kept, _} <- slice(chat.steps, step_uuid || :missing),
         :ok <-
           append_lines(id, [ordered([{"type", "rewind"}, {"at", now()}, {"to", step_uuid}])]) do
      restored =
        if Keyword.get(opts, :restore_files, true) and is_binary(chat[:cwd]) do
          {:ok, n} = Checkpoint.restore_files(chat.cwd, id, call_ids(kept), chat.cwd)
          n
        else
          0
        end

      {:ok,
       %{
         steps_dropped: length(chat.steps) - length(kept),
         files_restored: restored,
         message_count: length(kept)
       }}
    end
  end

  @doc "Remove a chat's record."
  @spec delete(id()) :: :ok | {:error, term()}
  def delete(id) do
    with :ok <- check_id(id), do: File.rm(path(id))
  end

  @doc """
  Mark a turn as running in chat `id`, held by the calling process.

  Returns `{:error, :busy}` when another process holds it. The hold ends at
  `release/1` or when the caller exits.
  """
  @spec hold(id()) :: :ok | {:error, :busy | :invalid_id}
  def hold(id) do
    with :ok <- check_id(id) do
      name = hold_name(id)
      take_hold(:global.whereis_name(name), name)
    end
  end

  defp take_hold(pid, _name) when pid == self(), do: :ok

  defp take_hold(:undefined, name),
    do: if(:global.register_name(name, self()) == :yes, do: :ok, else: {:error, :busy})

  defp take_hold(_other, _name), do: {:error, :busy}

  @doc "End the calling process's hold on chat `id`."
  @spec release(id()) :: :ok
  def release(id) do
    if valid_id?(id) and :global.whereis_name(hold_name(id)) == self() do
      :global.unregister_name(hold_name(id))
    end

    :ok
  end

  # ── Reading ───────────────────────────────────────────────────────

  defp read_chat(id) do
    with {:ok, body, mtime} <- read_file(id),
         [first | rest] <- decoded_lines(body),
         %{"type" => "chat", "chat" => header} <- first do
      steps = fold(rest, [])

      {:ok,
       header
       |> Codec.decode()
       |> merge_meta(rest)
       |> Map.merge(%{
         updated_at: mtime,
         steps: steps,
         messages: Enum.map(steps, & &1.message)
       })}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} = err -> err
      _ -> {:error, :unreadable}
    end
  end

  # The list reads only the header and meta lines, found by their prefix, so a
  # long chat costs a scan for line starts rather than a decode of every step.
  defp read_header(id) do
    with {:ok, body, mtime} <- read_file(id),
         [first | metas] <-
           body
           |> String.split("\n", trim: true)
           |> Enum.filter(&String.starts_with?(&1, @header_prefixes))
           |> Enum.flat_map(&decode_line/1),
         %{"type" => "chat", "chat" => header} <- first do
      {:ok, header |> Codec.decode() |> merge_meta(metas) |> Map.put(:updated_at, mtime)}
    else
      _ -> :error
    end
  end

  defp read_file(id) do
    path = path(id)

    with {:ok, body} <- File.read(path),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix) do
      {:ok, body, DateTime.from_unix!(mtime)}
    end
  end

  defp decoded_lines(body),
    do: body |> String.split("\n", trim: true) |> Enum.flat_map(&decode_line/1)

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => _} = obj} -> [obj]
      _ -> []
    end
  end

  defp merge_meta(header, lines) do
    Enum.reduce(lines, header, fn
      %{"type" => "meta", "fields" => fields}, acc -> Map.merge(acc, safe_decode(fields))
      _, acc -> acc
    end)
  end

  # Steps are folded newest-first and reversed once at the end.
  defp fold([], acc), do: Enum.reverse(acc)

  defp fold([%{"type" => "message"} = line | rest], acc) do
    case decode_step(line) do
      {:ok, step} -> fold(rest, [step | acc])
      :error -> fold(rest, acc)
    end
  end

  defp fold([%{"type" => "compact", "keep" => keep, "messages" => entries} | rest], acc)
       when is_integer(keep) and is_list(entries) do
    kept = acc |> Enum.reverse() |> Enum.take(keep)
    added = Enum.flat_map(entries, &(&1 |> decode_step() |> ok_step()))
    fold(rest, Enum.reverse(kept ++ added))
  end

  defp fold([%{"type" => "rewind", "to" => to} | rest], acc) do
    forward = Enum.reverse(acc)

    case Enum.find_index(forward, &(&1.uuid == to)) do
      nil -> fold(rest, acc)
      i -> fold(rest, forward |> Enum.take(i + 1) |> Enum.reverse())
    end
  end

  defp fold([_ | rest], acc), do: fold(rest, acc)

  defp ok_step({:ok, step}), do: [step]
  defp ok_step(_), do: []

  defp decode_step(%{"uuid" => uuid, "message" => encoded} = line) when is_binary(uuid) do
    case safe_decode(encoded) do
      %Message{} = message -> {:ok, %{uuid: uuid, at: line["at"], message: message}}
      _ -> :error
    end
  end

  defp decode_step(_), do: :error

  defp safe_decode(term) do
    Codec.decode(term)
  rescue
    _ -> nil
  end

  defp slice(steps, nil) do
    {:ok, steps, steps |> List.last() |> then(&(&1 && &1.uuid))}
  end

  defp slice(steps, uuid) do
    case Enum.find_index(steps, &(&1.uuid == uuid)) do
      nil -> {:error, :not_found}
      i -> {:ok, Enum.take(steps, i + 1), uuid}
    end
  end

  defp call_ids(steps) do
    Enum.reduce(steps, MapSet.new(), fn %{message: m}, acc ->
      calls = Enum.map(m.tool_calls || [], & &1.id)
      results = Enum.map(m.tool_results || [], & &1.tool_call_id)
      acc |> MapSet.union(MapSet.new(calls)) |> MapSet.union(MapSet.new(results))
    end)
  end

  defp common_prefix(a, b), do: common_prefix(a, b, 0)
  defp common_prefix([x | a], [x | b], n), do: common_prefix(a, b, n + 1)
  defp common_prefix(_, _, n), do: n

  # ── Writing ───────────────────────────────────────────────────────

  defp new_step(%Message{} = message), do: %{uuid: new_uuid(), at: now(), message: message}

  defp new_step(map) when is_map(map), do: new_step(ExAthena.Messages.from_map(map))

  defp step_object(step),
    do: ordered([{"uuid", step.uuid}, {"at", step.at}, {"message", Codec.encode(step.message)}])

  defp message_line(step) do
    ordered([
      {"type", "message"},
      {"uuid", step.uuid},
      {"at", step.at},
      {"message", Codec.encode(step.message)}
    ])
  end

  defp ordered(pairs), do: Jason.OrderedObject.new(pairs)

  defp encode_line(obj), do: [Jason.encode_to_iodata!(obj), ?\n]

  # Created empty and restricted before anything goes in, so no other user can
  # read even the header (issue 303).
  defp create_file(path, data) do
    ensure_root!()

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        try do
          File.chmod!(path, 0o600)
          IO.binwrite(io, data)
        after
          File.close(io)
        end

      {:error, :eexist} ->
        {:error, :exists}

      err ->
        err
    end
  end

  # One write per call, in append mode. A line a crash cut short gets its
  # newline first, so the new line never joins the broken one.
  defp append_lines(_id, []), do: :ok

  defp append_lines(id, lines) do
    path = path(id)

    if File.regular?(path) do
      data = Enum.map(lines, &encode_line/1)

      with {:ok, io} <- File.open(path, [:append, :read, :binary]) do
        try do
          IO.binwrite(io, [newline_if_cut(io, path) | data])
        after
          File.close(io)
        end
      end
    else
      {:error, :not_found}
    end
  end

  defp newline_if_cut(io, path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > 0 ->
        case :file.pread(io, size - 1, 1) do
          {:ok, "\n"} -> []
          {:ok, _} -> "\n"
          _ -> []
        end

      _ ->
        []
    end
  end

  defp ensure_root! do
    dir = root()
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  defp locked(id, fun), do: :global.trans({{__MODULE__, id}, self()}, fun, [node()])

  defp check_id(id), do: if(valid_id?(id), do: :ok, else: {:error, :invalid_id})

  defp check_idle(id) do
    if :global.whereis_name(hold_name(id)) == :undefined, do: :ok, else: {:error, :busy}
  end

  defp hold_name(id), do: {__MODULE__, :turn, id}

  defp new_uuid, do: 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
