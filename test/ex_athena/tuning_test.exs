defmodule ExAthena.TuningTest do
  @moduledoc """
  The rails added for local models shipped as hardcoded module attributes, so
  tuning them for a different model meant editing source. `Tuning` gives each
  one a config key while keeping the attribute as the default.
  """
  use ExUnit.Case, async: false

  alias ExAthena.Tuning

  setup do
    on_exit(fn -> Application.delete_env(:ex_athena, :orchestrate) end)
  end

  test "falls back to the caller's default when nothing is configured" do
    Application.delete_env(:ex_athena, :orchestrate)
    assert Tuning.get(:orchestrate, :max_planning_turns, 8) == 8
  end

  test "reads a keyword list, the shape config.exs produces" do
    Application.put_env(:ex_athena, :orchestrate, max_planning_turns: 20)
    assert Tuning.get(:orchestrate, :max_planning_turns, 8) == 20
  end

  test "reads a map, the shape a runtime-assembled config produces" do
    Application.put_env(:ex_athena, :orchestrate, %{max_planning_turns: 20})
    assert Tuning.get(:orchestrate, :max_planning_turns, 8) == 20
  end

  test "an unrelated key in the namespace does not shadow the default" do
    Application.put_env(:ex_athena, :orchestrate, max_same_objective: 9)
    assert Tuning.get(:orchestrate, :max_planning_turns, 8) == 8
  end

  # Compactor.Config resolves with `||`, so a configured 0 or false silently
  # falls through to the default. These are counts and caps where 0 is a
  # meaningful setting ("never auto-delegate"), so they must survive.
  test "keeps a configured zero instead of treating it as unset" do
    Application.put_env(:ex_athena, :orchestrate, max_turns_without_spawn: 0)
    assert Tuning.get(:orchestrate, :max_turns_without_spawn, 2) == 0
  end

  test "keeps a configured false" do
    Application.put_env(:ex_athena, :orchestrate, audit_enabled: false)
    assert Tuning.get(:orchestrate, :audit_enabled, true) == false
  end

  test "a malformed namespace value degrades to the default rather than raising" do
    Application.put_env(:ex_athena, :orchestrate, "not a config")
    assert Tuning.get(:orchestrate, :max_planning_turns, 8) == 8
  end
end
