defmodule ExAthena.Agents.RunFolder do
  @moduledoc """
  The folder every worker of a run starts in, when the orchestrator moved it.

  An orchestrator that sets up a git worktree for a ticket does it in bash, so
  ExAthena never learns of it: each worker started in the parent's folder, and
  its brief ended with "Working directory: <main checkout> … never work outside
  it". Relative reads and greps searched the wrong tree, and an auto-delegated
  "run the suite" step ran the suite on `main`.

  The orchestrator now names the folder once (`ExAthena.Tools.SetWorkingFolder`).
  The name sits in one ETS table seeded per run (`install/1`) and inherited by
  every subagent, the way `ExAthena.Agents.Quota`'s counter is, so one choice
  covers the whole tree. `ExAthena.Tools.SpawnAgent` reads it when it picks a
  worker's folder.

  The model never passes a free-form path to `spawn_agent`: models used to pass
  junk paths. `validate/2` accepts only a folder that `git worktree list` of the
  parent's repo shows and that lies inside the confinement roots.

  Journal, transcript and sidechain stay under the parent's folder; only the
  worker's working folder moves.
  """

  alias ExAthena.ToolContext

  @key :run_folder

  @doc "Seed the run's folder cell, keeping one a subagent already inherited."
  @spec install(map()) :: map()
  def install(assigns),
    do: Map.put_new_lazy(assigns, @key, fn -> :ets.new(@key, [:set, :public]) end)

  @doc "The folder the orchestrator named, or `nil`."
  @spec get(map() | nil) :: Path.t() | nil
  def get(assigns) do
    with %{@key => table} <- assigns || %{},
         [{:folder, path}] <- safe_lookup(table) do
      path
    else
      _ -> nil
    end
  end

  @doc """
  Check `path` and make it the run's folder.

  Returns `{:ok, folder}`, or `{:error, message}` with a message the model reads.
  """
  @spec set(ToolContext.t(), term()) :: {:ok, Path.t()} | {:error, String.t()}
  def set(ctx, path) do
    with {:ok, table} <- fetch_table(ctx.assigns),
         {:ok, folder} <- validate(ctx, path) do
      :ets.insert(table, {:folder, folder})
      {:ok, folder}
    end
  end

  @doc "Whether `path` is a worktree of the repo at `ctx.cwd` inside the roots."
  @spec validate(ToolContext.t(), term()) :: {:ok, Path.t()} | {:error, String.t()}
  def validate(_ctx, path) when not is_binary(path) or path == "",
    do: {:error, "`path` is required: pass the absolute path of a git worktree."}

  def validate(ctx, path) do
    folder = Path.expand(path, ctx.cwd)

    with {:ok, worktrees} <- worktrees(ctx.cwd),
         :ok <- listed(folder, worktrees),
         :ok <- inside_roots(folder, ctx) do
      {:ok, folder}
    end
  end

  defp fetch_table(%{@key => table}) when is_reference(table), do: {:ok, table}
  defp fetch_table(_), do: {:error, "this run cannot change its working folder."}

  defp safe_lookup(table) do
    :ets.lookup(table, :folder)
  rescue
    ArgumentError -> []
  end

  @git_timeout_ms 10_000

  defp worktrees(cwd) do
    case System.find_executable("git") do
      nil ->
        {:error, "git is not on PATH, so the worktree list cannot be read."}

      git ->
        task =
          Task.async(fn ->
            System.cmd(git, ["worktree", "list", "--porcelain"], cd: cwd, stderr_to_stdout: true)
          end)

        case Task.yield(task, @git_timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {out, 0}} ->
            {:ok, usable_worktrees(out)}

          {:ok, _} ->
            {:error, "#{cwd} is not inside a git repository, so there is no worktree to use."}

          _ ->
            {:error, "git worktree list did not answer in time."}
        end
    end
  end

  # One block per worktree. A bare repo and an entry whose folder is gone
  # (`prunable`) are listed but cannot hold a worker.
  defp usable_worktrees(out) do
    out
    |> String.split("\n\n", trim: true)
    |> Enum.map(&String.split(&1, "\n", trim: true))
    |> Enum.reject(fn lines ->
      "bare" in lines or Enum.any?(lines, &String.starts_with?(&1, "prunable"))
    end)
    |> Enum.flat_map(fn lines -> for "worktree " <> path <- lines, do: Path.expand(path) end)
    |> Enum.filter(&File.dir?/1)
  end

  defp listed(folder, worktrees) do
    if folder in worktrees do
      :ok
    else
      {:error,
       "#{folder} is not a worktree of this repository. Create it with " <>
         "`git worktree add`, then pass its path. Worktrees: #{Enum.join(worktrees, ", ")}."}
    end
  end

  defp inside_roots(folder, ctx) do
    if not ToolContext.confined?(ctx) or ToolContext.within_roots?(folder, ctx.allowed_roots) do
      :ok
    else
      {:error,
       "#{folder} is outside the folders this run may touch (#{Enum.join(ctx.allowed_roots, ", ")})."}
    end
  end
end
