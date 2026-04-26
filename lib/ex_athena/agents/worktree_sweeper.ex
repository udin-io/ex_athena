defmodule ExAthena.Agents.WorktreeSweeper do
  @moduledoc """
  One-shot startup task that GCs orphaned ex_athena git worktrees.

  When a parent process crashes mid-run, its subagent's worktree may
  be left behind on disk. Running `git worktree prune` reclaims any
  registered-but-deleted worktrees; we additionally remove our own
  cache directory entries that are older than 7 days and don't have
  matching prune entries.

  Started under the application supervisor; runs once at boot then
  exits. Logs are info-level — failures are best-effort.
  """

  require Logger

  alias ExAthena.Agents.Worktree

  @max_age_seconds 7 * 24 * 60 * 60

  @doc false
  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [__MODULE__, :run, []]},
      restart: :transient,
      type: :worker
    }
  end

  @spec run() :: :ok
  def run do
    if System.find_executable("git") do
      _ = run_prune()
      _ = sweep_old_dirs()
    end

    :ok
  rescue
    e ->
      Logger.info("WorktreeSweeper failed: #{Exception.message(e)}")
      :ok
  end

  defp run_prune do
    System.cmd("git", ["worktree", "prune"], stderr_to_stdout: true)
  end

  defp sweep_old_dirs do
    root = Worktree.worktree_root()

    case File.ls(root) do
      {:ok, entries} ->
        Enum.each(entries, &maybe_remove(Path.join(root, &1)))

      {:error, _} ->
        :ok
    end
  end

  defp maybe_remove(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime}} ->
        age = age_seconds(mtime)

        if age > @max_age_seconds do
          File.rm_rf(path)
          :ok
        end

      _ ->
        :ok
    end
  end

  defp age_seconds(mtime) do
    now = DateTime.utc_now() |> DateTime.to_unix()
    erl_to_unix = mtime |> :calendar.datetime_to_gregorian_seconds()
    epoch_offset = :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
    now - (erl_to_unix - epoch_offset)
  end
end
