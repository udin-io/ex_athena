defmodule ExAthena.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      # Subagents spawn under this supervisor so a sub-loop crash can't
      # take down the parent run. `Task.Supervisor.async_nolink` + timeout
      # gives us unlinked concurrency we can reap on deadline.
      {Task.Supervisor, name: ExAthena.Tasks}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ExAthena.Supervisor)
  end
end
