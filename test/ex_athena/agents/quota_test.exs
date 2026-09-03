defmodule ExAthena.Agents.QuotaTest do
  @moduledoc """
  How many workers one run may spawn, across the whole tree.

  There was a depth rail but no count rail: nothing stopped a run from
  spawning workers forever as long as each stayed under the nesting cap. One
  live "review pr 490" turn spawned 39 agents and ran for two hours.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Agents.Quota

  describe "install/1" do
    test "seeds a counter for a run that has none" do
      assigns = Quota.install(%{})
      assert Quota.spawned(assigns) == 0
    end

    # Subagent assigns arrive carrying the run's counter; re-seeding here
    # would give every branch its own allowance and cap nothing.
    test "keeps the counter a subagent inherited" do
      run = Quota.install(%{})
      {:ok, _} = Quota.claim(run)

      inherited = Quota.install(run)

      assert inherited.agent_quota == run.agent_quota
      assert Quota.spawned(inherited) == 1
    end
  end

  describe "claim/1" do
    test "counts each worker against the run's allowance" do
      assigns = Quota.install(%{max_agents_per_run: 3})

      assert {:ok, 1} = Quota.claim(assigns)
      assert {:ok, 2} = Quota.claim(assigns)
      assert {:ok, 3} = Quota.claim(assigns)
      assert Quota.spawned(assigns) == 3
    end

    test "refuses once the allowance is spent" do
      assigns = Quota.install(%{max_agents_per_run: 2})

      assert {:ok, 1} = Quota.claim(assigns)
      assert {:ok, 2} = Quota.claim(assigns)
      assert :exhausted = Quota.claim(assigns)
    end

    # Small models repeat a refused call; a refusal must not itself consume
    # allowance or the reported count runs away from reality.
    test "a refused claim does not consume anything" do
      assigns = Quota.install(%{max_agents_per_run: 1})

      assert {:ok, 1} = Quota.claim(assigns)
      assert :exhausted = Quota.claim(assigns)
      assert :exhausted = Quota.claim(assigns)
      assert Quota.spawned(assigns) == 1
    end

    # A bare Loop.run with hand-built assigns has no counter. The rail is a
    # runaway backstop, not a security boundary — absent means unbounded,
    # exactly as before it existed.
    test "a run with no quota installed is unbounded" do
      assert {:ok, 0} = Quota.claim(%{})
      assert Quota.spawned(%{}) == 0
    end
  end

  describe "limit/1" do
    test "per-run assigns win over application config" do
      assert Quota.limit(%{max_agents_per_run: 7}) == 7
    end

    test "falls back to the configured default" do
      assert Quota.limit(%{}) == Application.get_env(:ex_athena, :max_agents_per_run, 24)
    end
  end
end
