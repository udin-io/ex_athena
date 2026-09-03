defmodule ExAthena.Agents.Quota do
  @moduledoc """
  How many workers one run may spawn, counted across the whole tree.

  `ExAthena.Tools.SpawnAgent` has always had a *depth* rail, but nothing
  bounded the *number* of workers: a run could spawn forever as long as each
  worker stayed under the nesting cap. One live "review pr 490" turn spawned
  39 agents over two hours, and the orchestrator had no idea it was doing
  anything unusual.

  The counter is seeded once per run (`install/1`) and inherited unchanged by
  every subagent, so one allowance covers the whole tree rather than each
  branch getting its own. Sits in assigns next to
  `ExAthena.Agents.Deadline`'s counters, and for the same reason: a shared
  mutable object needs no message passing and no second source of truth. The
  Coordinator also knows the agent count, but it is observational by design —
  control flow stays in the loop.

  ## Limit

  `config :ex_athena, max_agents_per_run: 24`, or per-run via
  `assigns[:max_agents_per_run]`, mirroring `max_agent_depth`. The default is
  deliberately generous: this is a runaway backstop, not a planning budget,
  and a refused spawn tells the orchestrator to finish with what it has rather
  than failing the run.

  Concurrent spawns in different branches can both pass the check and overshoot
  the limit by however many were racing. That is acceptable for a backstop —
  the alternative is serialising every spawn through a process — and on a
  single-slot local provider they serialise at the queue anyway.
  """

  @quota_key :agent_quota
  @limit_key :max_agents_per_run
  @default_limit 24

  @doc """
  Seed the run's worker counter, keeping one a subagent already inherited.
  """
  @spec install(map()) :: map()
  def install(assigns),
    do: Map.put_new_lazy(assigns, @quota_key, fn -> :counters.new(1, [:write_concurrency]) end)

  @doc "Workers this run has spawned so far."
  @spec spawned(map()) :: non_neg_integer()
  def spawned(assigns) do
    case Map.get(assigns, @quota_key) do
      nil -> 0
      counter -> :counters.get(counter, 1)
    end
  end

  @doc "The run's worker allowance."
  @spec limit(map()) :: pos_integer()
  def limit(assigns \\ %{}) do
    Map.get(assigns, @limit_key) ||
      Application.get_env(:ex_athena, @limit_key, @default_limit)
  end

  @doc """
  Claim one worker against the run's allowance.

  Returns `{:ok, spawned_so_far}`, or `:exhausted` when the allowance is spent
  — a refusal costs nothing, so a model that repeats the call does not inflate
  the count. A run with no counter installed is unbounded, as it was before
  this rail existed.
  """
  @spec claim(map()) :: {:ok, non_neg_integer()} | :exhausted
  def claim(assigns) do
    case Map.get(assigns, @quota_key) do
      nil ->
        {:ok, 0}

      counter ->
        if :counters.get(counter, 1) >= limit(assigns) do
          :exhausted
        else
          :counters.add(counter, 1, 1)
          {:ok, :counters.get(counter, 1)}
        end
    end
  end
end
