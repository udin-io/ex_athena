defmodule ExAthena.Agents.Worktree do
  @moduledoc """
  Git-worktree isolation for subagents.

  When a subagent's `isolation: :worktree` is set, the parent's `cwd`
  is checked: must be inside a git repo, must have `git` on PATH,
  and (by default) must have a clean working tree. If any safety
  check fails, the caller falls back to `:in_process` cleanly.

  Worktrees are created under `~/.cache/ex_athena/worktrees/<sess>/<name>-<n>`,
  branched off `HEAD`. After the subagent finishes:

    * If it left changes in the worktree, the path + branch are
      surfaced in the spawn result so the caller can review/merge.
    * If the worktree is clean, it's removed via
      `git worktree remove --force`.

  The `WorktreeSweeper` GenServer (see
  `ExAthena.Agents.WorktreeSweeper`) GCs orphaned worktrees on
  application start.

  This module deliberately uses `System.cmd/3` directly (not
  `Tools.Bash`) so worktree creation/teardown bypasses the parent's
  permission gate — otherwise a parent in `:plan` mode could never
  spawn a worktree-isolated subagent.
  """

  alias ExAthena.Agents.Definition

  @worktree_root Path.join([System.user_home!() || "/tmp", ".cache", "ex_athena", "worktrees"])

  @doc """
  Decide isolation strategy for `def` against the parent's `cwd`.

  Returns one of:

    * `{:worktree, %{path: ..., branch: ...}}` — created and ready.
    * `{:in_process, reason}` — fell back; reason is a short atom
      explaining why (`:no_git`, `:not_a_repo`, `:dirty_tree`,
      `:create_failed`).
    * `{:in_process, :requested}` — the def explicitly asks for
      in-process; no checks were attempted.
  """
  @spec resolve(Definition.t(), String.t(), String.t()) ::
          {:worktree, map()} | {:in_process, atom()}
  def resolve(%Definition{isolation: :in_process}, _cwd, _session_id),
    do: {:in_process, :requested}

  def resolve(%Definition{isolation: :worktree, name: name}, cwd, session_id) do
    with :ok <- check_git_available(),
         :ok <- check_inside_repo(cwd),
         :ok <- check_clean_tree(cwd) do
      create_worktree(cwd, session_id, name)
    end
  end

  @doc """
  Decide what to do with a worktree after the subagent finishes.

  Returns `{:kept, info}` if the worktree had changes (caller is
  expected to surface the path + branch), or `{:removed, info}`
  when cleanup succeeded. Failure to remove is logged but
  non-fatal; the sweeper will catch it later.
  """
  @spec finalize(map()) :: {:kept, map()} | {:removed, map()} | {:error, term()}
  def finalize(%{path: path, parent_cwd: parent_cwd} = info) do
    case System.cmd("git", ["status", "--porcelain"], cd: path, stderr_to_stdout: true) do
      {"", 0} ->
        case System.cmd(
               "git",
               ["worktree", "remove", "--force", path],
               cd: parent_cwd,
               stderr_to_stdout: true
             ) do
          {_, 0} -> {:removed, info}
          {_, _} -> {:error, :remove_failed}
        end

      {_dirty, 0} ->
        {:kept, info}

      {_, _} ->
        {:error, :status_failed}
    end
  end

  # ── Safety checks ────────────────────────────────────────────────

  defp check_git_available do
    if System.find_executable("git"),
      do: :ok,
      else: {:in_process, :no_git}
  end

  defp check_inside_repo(cwd) do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> :ok
      _ -> {:in_process, :not_a_repo}
    end
  end

  defp check_clean_tree(cwd) do
    case System.cmd("git", ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true) do
      {"", 0} -> :ok
      {_dirty, 0} -> {:in_process, :dirty_tree}
      _ -> {:in_process, :status_failed}
    end
  end

  # ── Create / branch ──────────────────────────────────────────────

  defp create_worktree(cwd, session_id, name) do
    suffix = System.unique_integer([:positive, :monotonic])
    branch = "ex_athena/#{session_id}-#{name}-#{suffix}"
    path = Path.join([@worktree_root, session_id, "#{name}-#{suffix}"])

    File.mkdir_p!(Path.dirname(path))

    case System.cmd(
           "git",
           ["worktree", "add", "-b", branch, path, "HEAD"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {_, 0} -> {:worktree, %{path: path, branch: branch, parent_cwd: cwd}}
      {_, _} -> {:in_process, :create_failed}
    end
  end

  @doc false
  @spec worktree_root() :: String.t()
  def worktree_root, do: @worktree_root
end
