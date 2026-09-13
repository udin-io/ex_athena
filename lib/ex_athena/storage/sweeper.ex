defmodule ExAthena.Storage.Sweeper do
  @moduledoc """
  Age-based GC for the on-disk history a checkout accumulates.

  Two directories under `.exathena/` grow for the life of a checkout and
  nothing ever shrinks them: `file-history/` (pre-edit file snapshots, written
  by `ExAthena.Checkpoint`) and `sessions/` (session transcripts from
  `ExAthena.Sessions.Stores.Jsonl`, worker reports from
  `ExAthena.Agents.Sidechain`, worker journals from `ExAthena.Agents.Journal`).
  One busy session spawning seventeen workers leaves thirty-five files behind.

  ## This deletes the user's data, so "old" is defined conservatively

  A session directory's own mtime says when an entry was last added to it, not
  when its contents last changed — a session resumed after a month appends to
  `journal/<id>.ndjson` and leaves every enclosing directory's mtime untouched.
  Sweeping on the directory's mtime alone would reap a live session's worker
  reports out from under `ExAthena.Tools.ReadWorkerReport`. So an entry counts
  as old only when *nothing anywhere in its subtree* has been modified inside
  the retention window.

  Entries are also swept in groups, not one by one. One session id owns two
  entries at the sessions root — `<id>.jsonl` and `<id>/` — and only the first
  of them is touched by a resumed session that spawns no new workers. Entries
  sharing a root name are kept or removed together, so a fresh transcript
  protects its worker directory and vice versa.

  Anything that cannot be stat-ed or listed is treated as fresh and left alone:
  the cost of keeping a stale directory is disk space, and the cost of the
  opposite mistake is the user's forensics.

  Symlinks are never followed, on the walk or on the delete. `File.rm_rf/1`
  removes the link itself, so a link inside the root cannot be used to reach a
  tree outside it.

  Started under the application supervisor as a `restart: :transient` one-shot
  `Task`: it runs once at boot and exits. Best-effort — failures are logged at
  info level and never stop the application from starting.
  """

  require Logger

  @doc """
  Remove every group under `root` untouched for longer than `max_age_seconds`.

  Returns `{:ok, removed}` where `removed` lists the top-level paths that were
  deleted. A `max_age_seconds` of `0` or less disables the sweep and keeps
  everything; a `root` that does not exist, or cannot be read, removes nothing.
  """
  @spec sweep(Path.t(), integer()) :: {:ok, [Path.t()]}
  def sweep(_root, max_age_seconds) when max_age_seconds <= 0, do: {:ok, []}

  def sweep(root, max_age_seconds) do
    cutoff = System.os_time(:second) - max_age_seconds

    case File.ls(root) do
      {:ok, entries} ->
        removed =
          entries
          |> Enum.group_by(&Path.rootname/1)
          |> Enum.flat_map(fn {_id, names} ->
            paths = Enum.map(names, &Path.join(root, &1))
            if Enum.any?(paths, &fresh?(&1, cutoff)), do: [], else: remove(paths)
          end)

        {:ok, removed}

      {:error, _} ->
        {:ok, []}
    end
  end

  # True as soon as anything in the subtree was modified after the cutoff, so a
  # live session costs one stat and an abandoned one is walked only because it
  # is about to be deleted anyway.
  defp fresh?(path, cutoff) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} when mtime > cutoff ->
        true

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} -> Enum.any?(entries, &fresh?(Path.join(path, &1), cutoff))
          {:error, _} -> true
        end

      {:ok, _stat} ->
        false

      {:error, _} ->
        true
    end
  end

  defp remove(paths) do
    Enum.flat_map(paths, fn path ->
      case File.rm_rf(path) do
        {:ok, _} ->
          [path]

        {:error, reason, file} ->
          Logger.info("Storage.Sweeper could not remove #{file}: #{:file.format_error(reason)}")
          []
      end
    end)
  end
end
