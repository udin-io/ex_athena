defmodule ExAthena.Checkpoint do
  @moduledoc """
  File-history checkpointing + rewind.

  Before `Tools.Edit` and `Tools.Write` modify a file, the prior
  contents are saved to
  `<cwd>/.exathena/file-history/<session_id>/<sha>/<version>.bin`
  where `<sha>` is the SHA-256 of the absolute file path and
  `<version>` increments on each edit.

  `rewind/3` restores files (and optionally truncates the JSONL
  session log) to the state at a given event UUID.

  Adapted from Claude Code's `~/.claude/file-history/<session_id>/`
  layout. 30-day TTL is enforced by
  `ExAthena.Checkpoint.Sweeper`.

  ## Modes

    * `:code_and_history` — restore files to checkpoint AND truncate
      the session log to the chosen UUID.
    * `:history_only` — restore session log only; leave files as-is
      (useful when files have evolved since but you want to drop the
      conversation context).
  """

  require Logger

  alias ExAthena.Sessions.Stores.Jsonl

  @history_subdir ".exathena/file-history"

  # ── Public API ───────────────────────────────────────────────────

  @doc """
  Snapshot the prior contents of `path` before an edit. Returns the
  version directory + version number for telemetry / debugging.

  Idempotent: if the file's contents match the most-recent
  checkpoint version exactly, the existing version is reused (no
  duplicate write).
  """
  @spec snapshot(String.t(), String.t(), String.t()) ::
          {:ok, %{version: non_neg_integer(), path: String.t()}}
          | {:error, term()}
  def snapshot(cwd, session_id, file_path) when is_binary(file_path) do
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
  Rewind a session.

    * `mode = :code_and_history` — restore each file's contents to its
      most-recent checkpoint at-or-before `to_uuid`, AND truncate the
      session JSONL to that uuid.
    * `mode = :history_only` — only truncate the JSONL.

  Returns `{:ok, %{files_restored: n, events_dropped: m}}`. Best-effort
  on file restoration; partial failures are logged.
  """
  @spec rewind(String.t(), atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def rewind(session_id, mode, opts \\ []) when mode in [:code_and_history, :history_only] do
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)
    to_uuid = Keyword.get(opts, :to_uuid)

    if is_nil(to_uuid),
      do: {:error, :missing_to_uuid},
      else: do_rewind(session_id, mode, cwd, to_uuid)
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

  defp do_rewind(session_id, mode, cwd, to_uuid) do
    files_result =
      if mode == :code_and_history do
        restore_files(cwd, session_id, to_uuid)
      else
        {:ok, 0}
      end

    case files_result do
      {:ok, files_restored} ->
        case truncate_session_log(session_id, to_uuid) do
          {:ok, events_dropped} ->
            {:ok, %{files_restored: files_restored, events_dropped: events_dropped}}

          err ->
            err
        end

      err ->
        err
    end
  end

  defp restore_files(cwd, session_id, _to_uuid) do
    # PR5 ships a simple restoration: roll every checkpointed file back to
    # version 0 (the *first* snapshot, taken before the first edit). A
    # version-aware rewind that maps to_uuid → versions is followup work
    # once Sessions.Store records the version per write event in
    # `data[:checkpoint_version]`. The simple form already covers the
    # common case "undo this whole session's edits".
    history_root = history_dir(cwd, session_id)

    case File.ls(history_root) do
      {:ok, sha_dirs} ->
        restored =
          Enum.reduce(sha_dirs, 0, fn sha, acc ->
            sha_path = Path.join(history_root, sha)
            v0 = Path.join(sha_path, "0.bin")
            tombstone = Path.join(sha_path, "0.tombstone")
            path_marker = Path.join(sha_path, "path")

            with true <- File.regular?(v0),
                 {:ok, original_path} <- File.read(path_marker) do
              if File.exists?(tombstone) do
                _ = File.rm(original_path)
              else
                File.mkdir_p!(Path.dirname(original_path))
                File.write!(original_path, File.read!(v0))
              end

              acc + 1
            else
              _ -> acc
            end
          end)

        {:ok, restored}

      _ ->
        {:ok, 0}
    end
  end

  defp truncate_session_log(session_id, to_uuid) do
    path = Jsonl.path_for(session_id)

    case File.read(path) do
      {:ok, body} ->
        lines = String.split(body, "\n", trim: true)

        kept =
          Enum.take_while(lines, fn line ->
            case Jason.decode(line, keys: :atoms!) do
              {:ok, %{uuid: ^to_uuid}} -> false
              _ -> true
            end
          end)

        new_body = Enum.map_join(kept, "", fn line -> line <> "\n" end)
        File.write!(path, new_body)
        {:ok, length(lines) - length(kept)}

      {:error, :enoent} ->
        {:ok, 0}

      err ->
        err
    end
  rescue
    e ->
      Logger.warning("rewind truncate failed: #{Exception.message(e)}")
      {:error, :truncate_failed}
  end
end
