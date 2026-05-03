defmodule ExAthena.Agents.WorktreeTest do
  @moduledoc """
  These tests are tagged `:git` so suites can skip them in environments
  without a git binary. They exercise the safety-check fallbacks.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Agents.{Definition, Worktree}

  setup do
    dir = Path.join(System.tmp_dir!(), "worktree_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp def_isolated(isolation) do
    %Definition{name: "explore", description: "x", isolation: isolation}
  end

  test "isolation: :in_process never tries to create a worktree", %{dir: dir} do
    assert {:in_process, :requested} =
             Worktree.resolve(def_isolated(:in_process), dir, "session-id")
  end

  @tag :git
  test "isolation: :worktree falls back to :in_process when cwd isn't a git repo", %{
    dir: dir
  } do
    if System.find_executable("git") do
      assert {:in_process, :not_a_repo} =
               Worktree.resolve(def_isolated(:worktree), dir, "session-id")
    end
  end

  @tag :git
  test "isolation: :worktree falls back to :in_process when the tree is dirty", %{
    dir: dir
  } do
    if System.find_executable("git") do
      _ = System.cmd("git", ["init", "-q"], cd: dir)
      _ = System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      _ = System.cmd("git", ["config", "user.name", "test"], cd: dir)
      File.write!(Path.join(dir, "README.md"), "hello")
      _ = System.cmd("git", ["add", "."], cd: dir)
      _ = System.cmd("git", ["commit", "-q", "-m", "init"], cd: dir)

      # Now dirty the tree.
      File.write!(Path.join(dir, "README.md"), "hello world")

      assert {:in_process, :dirty_tree} =
               Worktree.resolve(def_isolated(:worktree), dir, "session-id")
    end
  end

  @tag :git
  test "isolation: :worktree creates a worktree when conditions are met", %{dir: dir} do
    if System.find_executable("git") do
      _ = System.cmd("git", ["init", "-q"], cd: dir)
      _ = System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      _ = System.cmd("git", ["config", "user.name", "test"], cd: dir)
      File.write!(Path.join(dir, "README.md"), "hello")
      _ = System.cmd("git", ["add", "."], cd: dir)
      _ = System.cmd("git", ["commit", "-q", "-m", "init"], cd: dir)

      assert {:worktree, info} =
               Worktree.resolve(
                 def_isolated(:worktree),
                 dir,
                 "session-test-#{System.unique_integer([:positive])}"
               )

      assert File.dir?(info.path)
      assert info.branch =~ "ex_athena/session-test-"

      # And we can finalise it cleanly when the worktree has no changes.
      assert {:removed, _} = Worktree.finalize(info)
      refute File.dir?(info.path)
    end
  end
end
