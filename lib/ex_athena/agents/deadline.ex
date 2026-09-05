defmodule ExAthena.Agents.Deadline do
  @moduledoc """
  A worker's time budget, measured in working time rather than wall clock.

  `ExAthena.Tools.SpawnAgent` gives every worker a deadline and kills it when
  that deadline passes. The loop, meanwhile, gates every provider call on
  `ExAthena.RequestQueue` with `queue_timeout: :infinity`, on the stated
  grounds that "a queued subagent legitimately waits minutes for a slot" — and
  on a local provider serving one request at a time, most of a busy subtree's
  elapsed time is exactly that wait.

  Charging it to the worker killed workers for being unlucky in the queue.
  Live, an explore worker was killed at its 30 minute mark having managed 19
  iterations and 555k input tokens while a sibling subtree monopolised the
  slot; its findings were dropped and the orchestrator re-explored the same
  ground twice.

  A wait is therefore accounted for twice, because the length of a wait is
  only known once it ends but the budget must survive the wait itself:

    * `begin_wait/1` **pauses** the budget — `remaining/3` reports `:paused`
      and the worker cannot be killed while it is sitting in the queue;
    * `end_wait/2` resumes it and credits the elapsed time, so the arithmetic
      afterwards is as if the wait had never happened.

  Both apply to the agent that waited and to every ancestor blocked waiting on
  it, so one wait extends every budget it actually delayed.

  ## Assigns

    * `:agent_deadline_at` — monotonic ms at which this worker's budget runs
      out, before any credit.
    * `:agent_deadline_from` — monotonic ms at which it began, so the share
      of the budget spent can be reported (see `ExAthena.Loop.BudgetPressure`).
    * `:agent_wait_counters` — `:counters` refs, nearest first. The head is
      this worker's own subtree counter; the tail belongs to its ancestors.

  Counters are shared mutable objects, so a worker updates its ancestors
  without any message passing on the hot path. Slot 1 accumulates credited
  wait; slot 2 counts the waits currently in flight anywhere in the subtree.
  """

  @deadline_key :agent_deadline_at
  @started_key :agent_deadline_from
  @counters_key :agent_wait_counters

  @credited 1
  @in_flight 2

  @doc "A fresh wait counter, owning one worker's subtree."
  @spec new_counter() :: :counters.counters_ref()
  def new_counter, do: :counters.new(2, [:write_concurrency])

  @doc "Queue time credited to this agent's own subtree, in ms."
  @spec waited(map()) :: non_neg_integer()
  def waited(assigns) do
    case Map.get(assigns, @counters_key) do
      [own | _] -> :counters.get(own, @credited)
      _ -> 0
    end
  end

  @doc """
  Pause this agent's budget, and its ancestors', for a wait that is starting.

  Paired with `end_wait/2`. `ExAthena.RequestQueue` guarantees exactly one
  close-out per `:waiting`, so the pause cannot outlive the wait.
  """
  @spec begin_wait(map()) :: :ok
  def begin_wait(assigns), do: each_counter(assigns, &:counters.add(&1, @in_flight, 1))

  @doc "Resume the budget and credit the `ms` just spent queued."
  @spec end_wait(map(), non_neg_integer()) :: :ok
  def end_wait(assigns, ms) do
    each_counter(assigns, fn counter ->
      :counters.add(counter, @in_flight, -1)
      if is_integer(ms) and ms > 0, do: :counters.add(counter, @credited, ms)
    end)
  end

  # A no-op for the top-level run, which has no budget to extend.
  defp each_counter(assigns, fun) do
    case Map.get(assigns, @counters_key) do
      counters when is_list(counters) -> Enum.each(counters, fun)
      _ -> :ok
    end

    :ok
  end

  @doc """
  The deadline for a worker spawned at `now` with a budget of `configured_ms`.

  The worker gets whichever of its own budget and its parent's remaining time
  runs out first, so a nested worker can never outlive the root waiting on it.
  The parent's remaining time is read on the parent's *working* clock: queue
  time already credited to it is time it still has to give away.

  Returns `:exhausted` when there is nothing left to give, so the caller can
  refuse the spawn rather than start a worker that cannot finish.
  """
  @spec for_child(map(), pos_integer(), integer()) :: {:ok, integer()} | :exhausted
  def for_child(assigns, configured_ms, now) do
    own = now + configured_ms

    deadline =
      case Map.get(assigns, @deadline_key) do
        inherited when is_integer(inherited) -> min(inherited + waited(assigns), own)
        _ -> own
      end

    if deadline > now, do: {:ok, deadline}, else: :exhausted
  end

  @doc """
  Milliseconds of budget left at `now` for a worker watched by `counter`.

  Zero or negative means the budget is spent. `:paused` means the subtree is
  currently queued for a provider slot: the wait's length is not known until
  it ends, so the budget stops rather than draining through it. Credited waits
  push the moment of expiry back by exactly as long as the subtree spent
  queued.
  """
  @spec remaining(integer(), :counters.counters_ref(), integer()) :: integer() | :paused
  def remaining(deadline, counter, now) do
    if :counters.get(counter, @in_flight) > 0 do
      :paused
    else
      deadline + :counters.get(counter, @credited) - now
    end
  end

  @doc """
  Put `deadline`, the worker's own `counter`, and the moment its budget began
  into the assigns it inherits.

  The counter goes at the head of the chain the parent already carried, so a
  wait deep in the tree credits every level above it. `started_at` is what
  lets `ExAthena.Loop.BudgetPressure` express time as a fraction of the
  budget rather than a bare "ms left".
  """
  @spec install(map(), integer(), :counters.counters_ref(), integer()) :: map()
  def install(assigns, deadline, counter, started_at) do
    assigns
    |> Map.put(@started_key, started_at)
    |> Map.put(@deadline_key, deadline)
    |> Map.update(@counters_key, [counter], fn
      inherited when is_list(inherited) -> [counter | inherited]
      _ -> [counter]
    end)
  end
end
