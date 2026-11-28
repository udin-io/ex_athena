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

    with :ok <- check_id(id),
         :ok <- create_guard(attrs) do
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

  # A test seam: `config :ex_athena, :chats_create_guard, fun` makes `create/1`
  # return what `fun.(attrs)` returns when it is not `:ok`, so a test can make
  # a create fail the way a full disk would.
  defp create_guard(attrs) do
    case Application.get_env(:ex_athena, :chats_create_guard) do
      fun when is_function(fun, 1) -> fun.(attrs)
      _ -> :ok
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

  `expect: version` makes the write conditional: it returns `{:error, :moved}`
  when the chat's `version` (from `load/1` or `version/1`) has moved since,
  because another front end added a turn or rewound it. A front end passes
  the version it last read, so its stale copy never writes over that work.
  `return: :version` returns `{:ok, version}`, the chat's version after this
  write, read under the same lock, to pass as the next `expect:`.

  The check and the write share a lock inside one program. Between two
  programs they are one only while the writer holds the chat (`hold/1`), so a
  front end saves its turn before it releases the hold.
  """
  @spec sync(id(), [Message.t()], keyword()) ::
          :ok | {:ok, non_neg_integer()} | {:error, term()}
  def sync(id, messages, opts \\ [])

  def sync(id, messages, opts) when is_list(messages) do
    with :ok <- check_id(id) do
      result = locked(id, fn -> do_sync(id, messages, Keyword.get(opts, :expect)) end)

      case {result, Keyword.get(opts, :return)} do
        {{:ok, version}, :version} -> {:ok, version}
        {{:ok, _version}, _} -> :ok
        {err, _} -> err
      end
    end
  end

  def sync(_id, _messages, _opts), do: {:error, :invalid_id}

  @doc """
  How far the chat has moved: the number of lines that changed its history
  (messages, compactions, rewinds). It only grows. See `sync/3`'s `:expect`.
  """
  @spec version(id()) :: {:ok, non_neg_integer()} | {:error, term()}
  def version(id) do
    with :ok <- check_id(id),
         {:ok, chat} <- read_chat(id) do
      {:ok, chat.version}
    end
  end

  # Each message is taken through the codec first, so it compares equal to
  # its saved copy: a plain map, or a value JSON cannot hold (a pid in a tool
  # panel), would otherwise differ every turn and rewrite the history.
  defp do_sync(id, messages, expect) do
    messages = Enum.map(messages, &as_saved/1)

    with {:ok, %{steps: steps, version: version}} <- read_chat(id),
         :ok <- check_version(version, expect) do
      active = Enum.map(steps, & &1.message)
      kept = common_prefix(active, messages)
      lines = sync_lines(kept == length(active), kept, Enum.drop(messages, kept))

      with :ok <- append_lines(id, lines), do: {:ok, version + length(lines)}
    end
  end

  defp check_version(_version, nil), do: :ok
  defp check_version(version, version), do: :ok
  defp check_version(_version, _expected), do: {:error, :moved}

  defp sync_lines(true, _kept, rest), do: Enum.map(rest, &message_line(new_step(&1)))

  defp sync_lines(false, kept, rest) do
    entries = Enum.map(rest, &step_object(new_step(&1)))
    [ordered([{"type", "compact"}, {"at", now()}, {"keep", kept}, {"messages", entries}])]
  end

  @doc """
  Create the chat when it is missing, sync `messages`, then record the
  header fields that changed: the call a front end makes on each save.
  Takes `sync/3`'s `:expect`; a refused sync records no header change.
  """
  @spec save(id(), map(), [Message.t()], keyword()) :: :ok | {:error, term()}
  def save(id, fields, messages, opts \\ []) when is_map(fields) and is_list(messages) do
    with :ok <- check_id(id) do
      fields = Map.take(fields, @header_fields)

      locked(id, fn ->
        do_save(id, read_header(id), fields, messages, Keyword.get(opts, :expect))
      end)
    end
  end

  defp do_save(id, {:ok, header}, fields, messages, expect) do
    with {:ok, _version} <- do_sync(id, messages, expect) do
      update(id, Map.reject(fields, fn {k, v} -> Map.get(header, k) == v end))
    end
  end

  defp do_save(id, :error, fields, messages, _expect) do
    with {:ok, _} <- create(Map.put(fields, :id, id)),
         {:ok, _version} <- do_sync(id, messages, nil),
         do: :ok
  end

  @doc """
  `message` as it reads back from a saved chat: through the codec and back.
  Compare a front end's messages with a saved chat's this way.
  """
  @spec as_saved(Message.t() | map()) :: Message.t()
  def as_saved(message) do
    message |> ExAthena.Messages.from_map() |> Codec.encode() |> Codec.decode()
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
    with :ok <- check_id(id) do
      while_held(id, fn -> do_fork(id, opts) end)
    end
  end

  defp do_fork(id, opts) do
    with {:ok, chat} <- read_chat(id),
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
    with :ok <- check_id(id) do
      while_held(id, fn -> do_rewind(id, step_uuid, opts) end)
    end
  end

  # Files first, then the line: a rewind that stops half way leaves the chat
  # as it was, and names the files it could not put back.
  defp do_rewind(id, step_uuid, opts) do
    with {:ok, chat} <- read_chat(id),
         {:ok, kept, _} <- slice(chat.steps, step_uuid || :missing) do
      dropped = Enum.drop(chat.steps, length(kept))

      files =
        if Keyword.get(opts, :restore_files, true),
          do: restore_files(chat, id, call_ids(dropped)),
          else: %{restored: 0, failed: []}

      with :ok <-
             append_lines(id, [ordered([{"type", "rewind"}, {"at", now()}, {"to", step_uuid}])]) do
        {:ok,
         %{
           steps_dropped: length(dropped),
           files_restored: files.restored,
           files_failed: files.failed,
           message_count: length(kept)
         }}
      end
    end
  end

  # The chat's own file history, in every folder it has worked in (a `/cd`
  # moves it). A fork's copied steps ran under the chat it came from, so a
  # fork's rewind puts back none of their files. Each file counts once.
  defp restore_files(chat, id, drop_calls) do
    plans = Enum.flat_map(chat.folders, &Checkpoint.plan_restores(&1, id, drop_calls, &1))

    # A file with history in two folders (a `/cd` between its edits) cannot
    # be put in order across them, so it is named, not guessed.
    merged =
      plans
      |> Enum.group_by(&elem(&1, 1))
      |> Enum.map(fn
        {_path, [plan]} -> plan
        {path, _several} -> {:failed, path}
      end)

    {:ok, files} = Checkpoint.apply_restores(merged)
    %{restored: files.restored, failed: files.failed}
  end

  defp folders(header, lines) do
    metas =
      for %{"type" => "meta", "fields" => fields} <- lines,
          %{cwd: cwd} <- [safe_decode(fields)],
          do: cwd

    [header[:cwd] | metas] |> Enum.filter(&is_binary/1) |> Enum.uniq()
  end

  @doc "Remove a chat's record."
  @spec delete(id()) :: :ok | {:error, term()}
  def delete(id) do
    with :ok <- check_id(id), do: File.rm(path(id))
  end

  @doc """
  Mark a turn as running in chat `id`, held by the calling process.

  Returns `{:error, :busy}` when another process holds it, in this program or
  another one (the terminal UI and the web UI run apart). The hold is a lock
  file, `<id>.lock`, made with an exclusive create, holding the program's OS
  pid and a token. It ends at `release/1` or when the caller exits; a lock
  left by a program that is gone is taken over.

  Liveness is judged by OS pid, so two programs in separate pid namespaces
  (two containers sharing the folder) cannot see each other's locks as alive.
  Two programs that take over one stale lock in the same instant can both
  hold it for that turn.
  """
  @spec hold(id()) :: :ok | {:error, :busy | :invalid_id | term()}
  def hold(id) do
    with :ok <- check_id(id) do
      if held_here?(id), do: :ok, else: take_lock(id)
    end
  end

  @doc "End the calling process's hold on chat `id`."
  @spec release(id()) :: :ok
  def release(id) do
    if valid_id?(id) and held_here?(id) do
      case :global.whereis_name(watch_name(id)) do
        pid when is_pid(pid) -> send(pid, :release)
        _ -> :ok
      end

      :global.unregister_name(hold_name(id))
      wait_released(id)
    end

    :ok
  end

  defp wait_released(id, tries \\ 50) do
    if tries > 0 and File.exists?(lock_path(id)) do
      Process.sleep(2)
      wait_released(id, tries - 1)
    end
  end

  defp held_here?(id), do: :global.whereis_name(hold_name(id)) == self()

  # The name is taken first: inside one program it is atomic, so two
  # processes never both reach the file. The file then claims the chat from
  # other programs.
  defp take_lock(id) do
    ensure_root!()

    if :global.register_name(hold_name(id), self()) == :yes do
      id |> create_lock(1) |> after_create(id)
    else
      {:error, :busy}
    end
  end

  defp after_create({:ok, path, token}, id) do
    holder = self()
    watcher = spawn(fn -> watch(holder, path, token) end)
    :global.re_register_name(watch_name(id), watcher)
    :ok
  end

  defp after_create(err, id) do
    :global.unregister_name(hold_name(id))
    err
  end

  defp create_lock(id, retries) do
    path = lock_path(id)
    token = new_uuid()

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        File.chmod!(path, 0o600)
        IO.binwrite(io, "#{System.pid()} #{token}")
        File.close(io)
        {:ok, path, token}

      {:error, :eexist} when retries > 0 ->
        if take_over_stale(id, path), do: create_lock(id, retries - 1), else: {:error, :busy}

      {:error, :eexist} ->
        {:error, :busy}

      err ->
        err
    end
  end

  # The watcher removes the lock when the holder exits or releases it, and
  # only while the file still holds its own token.
  defp watch(holder, path, token) do
    ref = Process.monitor(holder)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
      :release -> :ok
    end

    with {:ok, body} <- File.read(path),
         true <- String.ends_with?(body, " " <> token) do
      File.rm(path)
    end
  end

  # A stale lock is moved aside with one rename, which only one program can
  # win, and removed only when the moved file is the one judged stale.
  defp take_over_stale(id, path) do
    aside = path <> ".stale-" <> new_uuid()

    with {:ok, body} <- File.read(path),
         true <- stale_lock?(id, body),
         :ok <- File.rename(path, aside),
         {:ok, ^body} <- File.read(aside) do
      _ = File.rm(aside)
      true
    else
      {:ok, _other} ->
        _ = File.rename(aside, path)
        false

      _ ->
        false
    end
  end

  # A lock of this program is stale once its watcher is gone; one of another
  # program, once that program's OS process is gone.
  defp stale_lock?(id, body) do
    own = System.pid()

    case String.split(body, " ", parts: 2) do
      [^own, _token] -> :global.whereis_name(watch_name(id)) == :undefined
      [os_pid, _token] -> not os_process_alive?(os_pid)
      _ -> false
    end
  end

  # Fails closed: a pid that cannot be checked counts as alive.
  defp os_process_alive?(os_pid) do
    case Integer.parse(os_pid) do
      {n, ""} when n > 0 -> os_pid_alive?(n)
      _ -> true
    end
  end

  defp os_pid_alive?(n) do
    cond do
      File.dir?("/proc/self") ->
        File.dir?("/proc/#{n}")

      ps = System.find_executable("ps") ->
        match?({_, 0}, System.cmd(ps, ["-p", Integer.to_string(n)], stderr_to_stdout: true))

      true ->
        true
    end
  end

  # Rewind and fork run under a hold of their own, so neither meets a turn
  # running here or in another program; the caller's own hold counts.
  defp while_held(id, fun) do
    if held_here?(id) do
      locked(id, fun)
    else
      with :ok <- hold(id) do
        try do
          locked(id, fun)
        after
          release(id)
        end
      end
    end
  end

  defp lock_path(id), do: Path.join(root(), id <> ".lock")

  # ── Reading ───────────────────────────────────────────────────────

  defp read_chat(id) do
    with {:ok, body, mtime} <- read_file(id),
         [first | rest] <- decoded_lines(body),
         %{"type" => "chat", "chat" => header} <- first do
      steps = fold(rest, [])

      {:ok,
       header
       |> decode_header(id)
       |> merge_meta(rest)
       |> then(&Map.put(&1, :folders, folders(decode_header(header, id), rest)))
       |> Map.merge(%{
         updated_at: mtime,
         steps: steps,
         messages: Enum.map(steps, & &1.message),
         version: Enum.count(rest, &(&1["type"] in ["message", "compact", "rewind"]))
       })}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} = err -> err
      _ -> {:error, :unreadable}
    end
  rescue
    _ -> {:error, :unreadable}
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
      {:ok, header |> decode_header(id) |> merge_meta(metas) |> Map.put(:updated_at, mtime)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # The header must name the file it sits in: a copied file is not a second
  # chat with the same id.
  defp decode_header(encoded, id) do
    case safe_decode(encoded) do
      %{id: ^id} = header -> header
      _ -> raise ArgumentError, "chat header does not name this chat"
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
      %{"type" => "meta", "fields" => fields}, acc ->
        case safe_decode(fields) do
          %{} = changed -> Map.merge(acc, Map.take(changed, @header_fields))
          _ -> acc
        end

      _, acc ->
        acc
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
    kept = acc |> Enum.reverse() |> Enum.take(max(keep, 0))
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
    for %{message: m} <- steps,
        item <- List.wrap(m.tool_calls) ++ List.wrap(m.tool_results),
        id = call_id(item),
        is_binary(id),
        into: MapSet.new(),
        do: id
  end

  defp call_id(%{tool_call_id: id}), do: id
  defp call_id(%{id: id}), do: id
  defp call_id(_), do: nil

  defp common_prefix(a, b), do: common_prefix(a, b, 0)
  defp common_prefix([x | a], [x | b], n), do: common_prefix(a, b, n + 1)
  defp common_prefix(_, _, n), do: n

  # ── Writing ───────────────────────────────────────────────────────

  defp new_step(%Message{} = message), do: %{uuid: new_uuid(), at: now(), message: message}

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

  defp hold_name(id), do: {__MODULE__, :turn, id}
  defp watch_name(id), do: {__MODULE__, :watch, id}

  defp new_uuid, do: 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
