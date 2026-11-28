defmodule ExAthena.Checkpoint do
  @moduledoc """
  File-history checkpointing + rewind.

  Before `Tools.Edit` and `Tools.Write` modify a file, the prior
  contents are saved to
  `<cwd>/.exathena/file-history/<session_id>/<sha>/<version>.bin`
  where `<sha>` is the SHA-256 of the absolute file path and
  `<version>` increments on each edit.

  Each version also lists, in `<version>.calls`, the tool calls that took
  it, so `restore_files/4` can tell which versions belong to steps a rewind
  drops (`ExAthena.Chats.rewind/3`).

  Adapted from Claude Code's `~/.claude/file-history/<session_id>/`
  layout. The 30-day TTL is enforced at boot by
  `ExAthena.Storage.Sweeper`, and is settable in the settings modal.
  """

  @history_subdir ".exathena/file-history"

  # ── Public API ───────────────────────────────────────────────────

  @doc """
  Snapshot the prior contents of `path` before an edit. Returns the
  version directory + version number for telemetry / debugging.

  Idempotent: if the file's contents match the most-recent
  checkpoint version exactly, the existing version is reused (no
  duplicate write). `tool_call_id`, when given, is added to the
  version's call list either way.
  """
  @spec snapshot(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, %{version: non_neg_integer(), path: String.t()}}
          | {:error, term()}
  def snapshot(cwd, session_id, file_path, tool_call_id \\ nil) when is_binary(file_path) do
    seen = content_sha(file_path)

    with {:ok, %{version: version, path: dir}} = ok <-
           read_and_snapshot(cwd, session_id, file_path) do
      if is_binary(tool_call_id) and tool_call_id != "" do
        File.write!(Path.join(dir, "#{version}.calls"), tool_call_id <> "\n", [:append])
      end

      mark_foreign(dir, version, seen)
      ok
    end
  end

  # The file differs from what the chat last left in it, so someone else
  # changed it before this call: the version is marked, and a rewind past
  # it would undo their change.
  defp mark_foreign(dir, version, seen) do
    note = Path.join(dir, "written")

    case File.read(note) do
      {:ok, ^seen} -> :ok
      {:ok, _other} -> File.write!(Path.join(dir, "#{version}.foreign"), "")
      _ -> :ok
    end

    File.write!(note, seen)
  end

  @doc """
  Note what a chat's edit left in `file_path`, right after the write. Rewind
  then puts the file back only while it still holds exactly that: a file
  someone else changed since (another chat, a fork, a person) is left alone
  and listed. Best-effort, like `snapshot/4`.
  """
  @spec record_written(String.t(), String.t() | nil, String.t()) :: :ok
  def record_written(cwd, session_id, file_path)
      when is_binary(session_id) and session_id != "" do
    dir = Path.join(history_dir(cwd, session_id), path_sha(Path.expand(file_path)))
    if File.dir?(dir), do: File.write!(Path.join(dir, "written"), content_sha(file_path))
    :ok
  rescue
    _ -> :ok
  end

  def record_written(_cwd, _session_id, _file_path), do: :ok

  defp content_sha(path) do
    case File.read(path) do
      {:ok, body} -> :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      {:error, :enoent} -> "absent"
      {:error, _} -> "unreadable"
    end
  end

  # Unchanged since this chat last wrote it, or no note kept (an older
  # history), so the file is this chat's to put back.
  defp still_ours?(dir, original) do
    case File.read(Path.join(dir, "written")) do
      {:ok, sha} -> sha == content_sha(original)
      _ -> true
    end
  end

  defp read_and_snapshot(cwd, session_id, file_path) do
    case File.read(file_path) do
      {:ok, body} ->
        do_snapshot(cwd, session_id, file_path, body)

      {:error, :enoent} ->
        # New file — nothing to snapshot. We still mark a `version: 0`
        # placeholder so a subsequent rewind can detect "this file
        # didn't exist at checkpoint time" and remove it.
        do_snapshot(cwd, session_id, file_path, :tombstone)

      err ->
        err
    end
  end

  @doc "Path to the file-history directory for `session_id` under `cwd`."
  @spec history_dir(String.t(), String.t()) :: String.t()
  def history_dir(cwd, session_id) do
    Path.join([cwd, @history_subdir, session_id])
  end

  @doc """
  Put back each file that a chat's dropped tool calls changed.

  `drop_calls` holds the ids of the tool calls a rewind takes out of the
  chat. For every file with saved versions, the first version one of those
  calls took is the file as it was before that call ran; it is written back,
  or the file is removed when it did not exist then. Calls outside
  `drop_calls` never move a file: a call a compaction summarised, or one an
  earlier rewind already undid, keeps its effect. A version saved without a
  call id is never chosen.

  The history folder sits inside the project, so the model can write to it.
  An entry is skipped unless its folder name is the hash of its path, the
  path lies inside `within` with no symlink on the way, the file there (if
  any) is a regular file, and the saved version is a regular file.

  A file whose content differs from what the chat's last edit left in it
  (`record_written/3`) is left alone and listed as failed: someone else
  changed it since.

  Returns `{:ok, %{restored: n, restored_paths: [path], failed: [path]}}`.
  """
  @spec restore_files(String.t(), String.t(), MapSet.t(String.t()), String.t()) ::
          {:ok, map()}
  def restore_files(cwd, session_id, drop_calls, within) do
    cwd |> plan_restores(session_id, drop_calls, within) |> apply_restores()
  end

  @doc """
  What `restore_files/4` would do, without doing it: `{:put, path, dir,
  version}` for a file to put back, `{:failed, path}` for one to leave and
  name. A caller with histories in several folders merges the plans first.
  """
  @spec plan_restores(String.t(), String.t(), MapSet.t(String.t()), String.t()) :: [tuple()]
  def plan_restores(cwd, session_id, drop_calls, within) do
    within = Path.expand(within)
    root = history_dir(cwd, session_id)

    case File.ls(root) do
      {:ok, sha_dirs} ->
        Enum.flat_map(sha_dirs, &plan_one(Path.join(root, &1), drop_calls, within))

      _ ->
        []
    end
  end

  @doc "Carry out a plan from `plan_restores/4`; returns what `restore_files/4` does."
  @spec apply_restores([tuple()]) :: {:ok, map()}
  def apply_restores(plans) do
    results =
      Enum.map(plans, fn
        {:put, original, dir, version} ->
          dir |> put_back(version, original) |> note_restored(dir, original)

        {:failed, _} = failed ->
          failed
      end)

    restored = for {:restored, path} <- results, do: path

    {:ok,
     %{
       restored: length(restored),
       restored_paths: restored,
       failed: for({:failed, path} <- results, do: path)
     }}
  end

  defp plan_one(dir, drop_calls, within) do
    versions = version_numbers(dir)

    with {:ok, original} <- File.read(Path.join(dir, "path")),
         original = Path.expand(original),
         true <- Path.basename(dir) == path_sha(original),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(dir),
         true <- safe_target?(original, within),
         version when is_integer(version) <- Enum.find(versions, &dropped?(dir, &1, drop_calls)) do
      foreign_after? =
        Enum.any?(versions, &(&1 > version and File.exists?(Path.join(dir, "#{&1}.foreign"))))

      if still_ours?(dir, original) and not foreign_after?,
        do: [{:put, original, dir, version}],
        else: [{:failed, original}]
    else
      _ -> []
    end
  end

  defp note_restored({:restored, _} = result, dir, original) do
    _ = File.write(Path.join(dir, "written"), content_sha(original))
    result
  end

  defp note_restored(result, _dir, _original), do: result

  defp put_back(dir, version, original) do
    bin = Path.join(dir, "#{version}.bin")

    cond do
      File.exists?(Path.join(dir, "#{version}.tombstone")) ->
        _ = File.rm(original)
        {:restored, original}

      regular?(bin) ->
        File.mkdir_p!(Path.dirname(original))
        File.write!(original, File.read!(bin))
        {:restored, original}

      true ->
        :skipped
    end
  rescue
    _ -> {:failed, original}
  end

  defp dropped?(dir, version, drop_calls) do
    case File.read(Path.join(dir, "#{version}.calls")) do
      {:ok, body} ->
        body |> String.split("\n", trim: true) |> Enum.any?(&MapSet.member?(drop_calls, &1))

      _ ->
        false
    end
  end

  # Inside `within`, and no part of the path below it is a symlink, so a write
  # cannot be steered outside the folder.
  defp safe_target?(path, within) do
    with true <- String.starts_with?(path, within <> "/"),
         parts = path |> Path.relative_to(within) |> Path.split(),
         false <- Enum.member?(parts, "..") do
      parts
      |> Enum.scan(within, &Path.join(&2, &1))
      |> Enum.all?(&safe_part?(&1, &1 == path))
    else
      _ -> false
    end
  end

  defp safe_part?(part, last?) do
    case File.lstat(part) do
      {:ok, %File.Stat{type: :symlink}} -> false
      {:ok, %File.Stat{type: :regular}} -> true
      {:ok, %File.Stat{type: :directory}} -> not last?
      {:error, :enoent} -> true
      _ -> false
    end
  end

  # One link only: a hard link to a file elsewhere is not a saved version.
  defp regular?(path), do: match?({:ok, %File.Stat{type: :regular, links: 1}}, File.lstat(path))

  defp path_sha(path), do: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)

  # ── Internals ────────────────────────────────────────────────────

  defp do_snapshot(cwd, session_id, file_path, body) do
    sha = path_sha(Path.expand(file_path))

    dir = Path.join(history_dir(cwd, session_id), sha)
    File.mkdir_p!(dir)

    {existing_versions, latest_body} = list_versions(dir)

    cond do
      body == latest_body ->
        # Re-use the latest version; no new write.
        {:ok, %{version: List.last(existing_versions) || 0, path: dir}}

      true ->
        version = (List.last(existing_versions) || -1) + 1
        target = Path.join(dir, "#{version}.bin")

        case body do
          :tombstone -> File.write!(target, "")
          contents -> File.write!(target, contents)
        end

        # Track tombstones via a sidecar so rewind can remove the file
        # rather than restore empty bytes.
        if body == :tombstone do
          File.write!(Path.join(dir, "#{version}.tombstone"), "")
        end

        # Persist the original absolute path next to the versions so
        # rewind knows where to restore.
        path_marker = Path.join(dir, "path")
        if not File.exists?(path_marker), do: File.write!(path_marker, Path.expand(file_path))

        {:ok, %{version: version, path: dir}}
    end
  end

  defp list_versions(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        versions = numbers(entries)

        {versions, latest_body(dir, List.last(versions))}

      _ ->
        {[], nil}
    end
  end

  # A tombstone's empty bytes never stand for an empty file that exists.
  defp latest_body(_dir, nil), do: nil

  defp latest_body(dir, v) do
    if File.exists?(Path.join(dir, "#{v}.tombstone")),
      do: :tombstone,
      else: File.read!(Path.join(dir, "#{v}.bin"))
  end

  defp version_numbers(dir) do
    case File.ls(dir) do
      {:ok, entries} -> numbers(entries)
      _ -> []
    end
  end

  # A name that is not `<integer>.bin` is skipped, not a crash.
  defp numbers(entries) do
    entries
    |> Enum.flat_map(fn name ->
      with true <- String.ends_with?(name, ".bin"),
           {n, ""} <- Integer.parse(String.trim_trailing(name, ".bin")) do
        [n]
      else
        _ -> []
      end
    end)
    |> Enum.sort()
  end
end
