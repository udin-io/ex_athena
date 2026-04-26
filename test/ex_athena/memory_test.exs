defmodule ExAthena.MemoryTest do
  use ExUnit.Case, async: true

  alias ExAthena.Memory
  alias ExAthena.Messages.Message

  setup do
    cwd = Path.join(System.tmp_dir!(), "mem_#{System.unique_integer([:positive])}")
    user = Path.join(System.tmp_dir!(), "mem_user_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    File.mkdir_p!(user)

    on_exit(fn ->
      File.rm_rf!(cwd)
      File.rm_rf!(user)
    end)

    {:ok, cwd: cwd, user: user}
  end

  describe "discover/2" do
    test "returns [] when no memory files exist", %{cwd: cwd, user: user} do
      assert Memory.discover(cwd, user_dir: user) == []
    end

    test "loads project AGENTS.md", %{cwd: cwd, user: user} do
      File.write!(Path.join(cwd, "AGENTS.md"), "Use TDD.")

      assert [%Message{role: :user, name: "memory", content: content}] =
               Memory.discover(cwd, user_dir: user)

      assert content =~ "Use TDD."
      assert content =~ "memory: project"
    end

    test "skips empty memory files", %{cwd: cwd, user: user} do
      File.write!(Path.join(cwd, "AGENTS.md"), "   \n  \n")
      assert Memory.discover(cwd, user_dir: user) == []
    end

    test "AGENTS.md wins over CLAUDE.md at the same level", %{cwd: cwd, user: user} do
      File.write!(Path.join(cwd, "AGENTS.md"), "agents content")
      File.write!(Path.join(cwd, "CLAUDE.md"), "claude content")

      assert [%Message{content: c}] = Memory.discover(cwd, user_dir: user)
      assert c =~ "agents content"
      refute c =~ "claude content"
    end

    test "falls back to CLAUDE.md when AGENTS.md is missing", %{cwd: cwd, user: user} do
      File.write!(Path.join(cwd, "CLAUDE.md"), "claude only")

      assert [%Message{content: c}] = Memory.discover(cwd, user_dir: user)
      assert c =~ "claude only"
    end

    test "load order is user → project → local", %{cwd: cwd, user: user} do
      File.write!(Path.join(user, "AGENTS.md"), "user-level rule")
      File.write!(Path.join(cwd, "AGENTS.md"), "project-level rule")
      File.write!(Path.join(cwd, "AGENTS.local.md"), "local override")

      assert [u, p, l] = Memory.discover(cwd, user_dir: user)
      assert u.content =~ "user-level rule"
      assert p.content =~ "project-level rule"
      assert l.content =~ "local override"

      # Each carries the level marker so the model knows which is which.
      assert u.content =~ "memory: user"
      assert p.content =~ "memory: project"
      assert l.content =~ "memory: local"
    end
  end

  describe "pinned_count/1 + memory_message?/1" do
    test "counts only memory messages" do
      assert Memory.pinned_count([
               %Message{role: :user, content: "hello"},
               %Message{role: :user, content: "memory", name: "memory"},
               %Message{role: :system, content: "sp"}
             ]) == 1

      assert Memory.memory_message?(%Message{role: :user, name: "memory", content: "x"})
      refute Memory.memory_message?(%Message{role: :user, content: "x"})
    end
  end
end
