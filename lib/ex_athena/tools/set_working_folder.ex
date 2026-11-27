defmodule ExAthena.Tools.SetWorkingFolder do
  @moduledoc """
  Name the folder every worker of this run starts in, once.

  For an orchestrator that made a git worktree with `git worktree add`: after
  this call each worker starts in that worktree, its brief names that folder
  alone, and its relative reads and greps resolve there. Without it, workers
  start in the folder the run began in.

  The folder must be a worktree of the run's own repository (it appears in
  `git worktree list`) and lie inside the confinement roots; anything else is
  refused with an error the model reads. See `ExAthena.Agents.RunFolder`.

  Arguments:

    * `path` (required) — absolute path of the worktree.

  Orchestrator-only: `ExAthena.Tools.SpawnAgent` never hands it to a worker.
  """

  @behaviour ExAthena.Tool

  alias ExAthena.Agents.RunFolder

  @impl true
  def name, do: "set_working_folder"

  @impl true
  def description,
    do:
      "Set the folder all workers start in. Pass the absolute path of a git worktree " <>
        "you created for this task; workers spawned afterwards work there instead of " <>
        "the folder this run started in."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "Absolute path of a git worktree of this repository."
        }
      },
      required: ["path"]
    }
  end

  @impl true
  def execute(args, ctx) do
    case RunFolder.set(ctx, Map.get(args, "path")) do
      {:ok, folder} -> {:ok, "Workers now start in #{folder}."}
      {:error, message} -> {:error, message}
    end
  end
end
