defmodule ExAthena.Agents.DeadlineTest do
  @moduledoc """
  A worker's budget is working time, not wall clock.

  The loop queues every provider call with `queue_timeout: :infinity` because
  "a queued subagent legitimately waits minutes for a slot" — but the spawn
  timeout was wall clock, so those minutes were charged to the worker anyway.
  On a one-slot local provider that is most of a busy subtree's elapsed time.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Agents.Deadline

  # A counter carrying `ms` of already-completed queue wait.
  defp counter(ms \\ 0) do
    c = Deadline.new_counter()
    if ms > 0, do: complete_wait(%{agent_wait_counters: [c]}, ms)
    c
  end

  defp complete_wait(assigns, ms) do
    Deadline.begin_wait(assigns)
    Deadline.end_wait(assigns, ms)
  end

  describe "for_child/3" do
    test "with no inherited deadline the worker gets its own budget" do
      assert {:ok, 30_000} = Deadline.for_child(%{}, 30_000, 0)
    end

    test "a nearer parent deadline wins" do
      assigns = %{agent_deadline_at: 5_000}
      assert {:ok, 5_000} = Deadline.for_child(assigns, 30_000, 0)
    end

    test "a parent deadline further out does not extend the worker's own budget" do
      assigns = %{agent_deadline_at: 90_000}
      assert {:ok, 30_000} = Deadline.for_child(assigns, 30_000, 0)
    end

    # The parent's own budget has been pushed back by the time it spent
    # queued, so it has more left to hand down than its raw deadline says.
    test "queue-wait already credited to the parent extends what it can pass on" do
      assigns = %{agent_deadline_at: 5_000, agent_wait_counters: [counter(10_000)]}

      assert {:ok, 15_000} = Deadline.for_child(assigns, 30_000, 0)
    end

    test "the worker's own budget still caps a generously credited parent" do
      assigns = %{agent_deadline_at: 5_000, agent_wait_counters: [counter(600_000)]}

      assert {:ok, 30_000} = Deadline.for_child(assigns, 30_000, 0)
    end

    test "no time left is refused rather than rounded up" do
      assert :exhausted = Deadline.for_child(%{agent_deadline_at: 0}, 30_000, 0)
      assert :exhausted = Deadline.for_child(%{agent_deadline_at: -1}, 30_000, 0)
    end
  end

  describe "begin_wait/1 and end_wait/2" do
    test "one wait extends every budget it delayed, not just the waiter's" do
      mine = Deadline.new_counter()
      parent = Deadline.new_counter()
      grandparent = Deadline.new_counter()
      chain = %{agent_wait_counters: [mine, parent, grandparent]}

      complete_wait(chain, 1_500)

      for c <- [mine, parent, grandparent] do
        assert Deadline.waited(%{agent_wait_counters: [c]}) == 1_500
      end
    end

    test "waits accumulate" do
      assigns = %{agent_wait_counters: [Deadline.new_counter()]}

      complete_wait(assigns, 400)
      complete_wait(assigns, 600)

      assert Deadline.waited(assigns) == 1_000
    end

    test "an agent with no counters (the top-level run) is a no-op" do
      assert Deadline.begin_wait(%{}) == :ok
      assert Deadline.end_wait(%{}, 1_000) == :ok
      assert Deadline.waited(%{}) == 0
    end
  end

  describe "remaining/3" do
    test "counts down as wall clock passes" do
      assert Deadline.remaining(10_000, counter(), 0) == 10_000
      assert Deadline.remaining(10_000, counter(), 9_000) == 1_000
      assert Deadline.remaining(10_000, counter(), 10_000) == 0
      assert Deadline.remaining(10_000, counter(), 12_000) == -2_000
    end

    test "time spent queued does not count against the budget" do
      # 12s of wall clock has passed against a 10s budget, but 5s of it was
      # spent waiting for a provider slot — 3s of working time remain.
      assert Deadline.remaining(10_000, counter(5_000), 12_000) == 3_000
    end

    # A wait's length is unknown until it ends, so the budget cannot simply
    # drain through it: an in-flight wait pauses the clock instead. Without
    # this the worker is killed while queued and the credit lands too late.
    test "the budget is paused while the subtree is queued" do
      c = Deadline.new_counter()
      assigns = %{agent_wait_counters: [c]}

      Deadline.begin_wait(assigns)
      assert Deadline.remaining(10_000, c, 999_999) == :paused

      Deadline.end_wait(assigns, 990_000)
      assert Deadline.remaining(10_000, c, 999_999) == 1
    end

    test "the pause lifts only when every wait in the subtree has closed out" do
      c = Deadline.new_counter()
      assigns = %{agent_wait_counters: [c]}

      Deadline.begin_wait(assigns)
      Deadline.begin_wait(assigns)
      Deadline.end_wait(assigns, 100)

      assert Deadline.remaining(10_000, c, 0) == :paused

      Deadline.end_wait(assigns, 100)
      assert Deadline.remaining(10_000, c, 0) == 10_200
    end
  end

  describe "install/4" do
    test "puts the child's own counter at the head of the inherited chain" do
      parent = counter()
      mine = counter()

      assigns = Deadline.install(%{agent_wait_counters: [parent]}, 42, mine, 10)

      assert assigns.agent_deadline_at == 42
      assert assigns.agent_wait_counters == [mine, parent]
    end

    test "starts a chain for a worker whose parent had none" do
      mine = counter()
      assert %{agent_wait_counters: [^mine]} = Deadline.install(%{}, 42, mine, 10)
    end

    # BudgetPressure needs the start to express time as a share of the budget
    # rather than a bare "ms left", which says nothing to a model.
    test "records when the budget began" do
      assert %{agent_deadline_from: 10} = Deadline.install(%{}, 42, counter(), 10)
    end
  end
end
