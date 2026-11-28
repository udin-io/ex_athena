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
    with {:ok, %{version: version, path: dir}} = ok <-
           read_and_snapshot(cwd, session_id, file_path) do
      if is_binary(tool_call_id) and tool_call_id != "" do
        File.write!(Path.join(dir, "#{version}.calls"), tool_call_id <> "\n", [:append])
      end

      ok
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
  Put back each file that the dropped tool calls of a chat changed.

  `keep_calls` holds the ids of the tool calls the chat keeps. For every file
  with saved versions, the first version that a call outside `keep_calls`
  snapshot is the file as it was before that call ran; that version is
  written back, or the file is removed when it did not exist then. A version
  recorded without a call id cannot be placed and is never chosen.

  Only files inside `within` are touched, so a history folder can never move
  a write outside the chat's own folder. Returns `{:ok, files_restored}`.
  """
  @spec restore_files(String.t(), String.t(), MapSet.t(String.t()), String.t()) ::
          {:ok, non_neg_integer()}
  def restore_files(cwd, session_id, keep_calls, within) do
    within = Path.expand(within)
    root = history_dir(cwd, session_id)

    case File.ls(root) do
      {:ok, sha_dirs} ->
        {:ok, Enum.count(sha_dirs, &restore_one(Path.join(root, &1), keep_calls, within))}

      _ ->
        {:ok, 0}
    end
  end

  defp restore_one(dir, keep_calls, within) do
    {versions, _} = list_versions(dir)

    with {:ok, original} <- File.read(Path.join(dir, "path")),
         true <- inside?(original, within),
         version when is_integer(version) <-
           Enum.find(versions, &dropped?(dir, &1, keep_calls)) do
      if File.exists?(Path.join(dir, "#{version}.tombstone")) do
        _ = File.rm(original)
      else
        File.mkdir_p!(Path.dirname(original))
        File.write!(original, File.read!(Path.join(dir, "#{version}.bin")))
      end

      true
    else
      _ -> false
    end
  end

  defp dropped?(dir, version, keep_calls) do
    case File.read(Path.join(dir, "#{version}.calls")) do
      {:ok, body} ->
        body |> String.split("\n", trim: true) |> Enum.any?(&(not MapSet.member?(keep_calls, &1)))

      _ ->
        false
    end
  end

  defp inside?(path, root) do
    path = Path.expand(path)
    path == root or String.starts_with?(path, root <> "/")
  end

  # ── Internals ────────────────────────────────────────────────────

  defp do_snapshot(cwd, session_id, file_path, body) do
    sha =
      :crypto.hash(:sha256, Path.expand(file_path))
      |> Base.encode16(case: :lower)

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
        versions =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".bin"))
          |> Enum.map(fn name -> name |> String.trim_trailing(".bin") |> String.to_integer() end)
          |> Enum.sort()

        latest_body =
          case List.last(versions) do
            nil -> nil
            v -> File.read!(Path.join(dir, "#{v}.bin"))
          end

        {versions, latest_body}

      _ ->
        {[], nil}
    end
  end
end
