defmodule ExAthena.Tools.GhTest do
  use ExUnit.Case, async: true

  alias ExAthena.Messages.ToolCall
  alias ExAthena.Permissions
  alias ExAthena.ToolContext
  alias ExAthena.Tools
  alias ExAthena.Tools.Gh

  # A fake `gh` executable so the execution path is hermetic — no real CLI or
  # network needed. The `ctx.assigns[:gh_binary]` seam injects it (same pattern
  # as the `sandbox_finder` seam in `Bash` tests).
  setup do
    dir = Path.join(System.tmp_dir!(), "gh_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    fake = Path.join(dir, "fake_gh")
    File.write!(fake, "#!/bin/sh\necho \"fake gh: $@\"\n")
    File.chmod!(fake, 0o755)

    on_exit(fn -> File.rm_rf!(dir) end)

    ctx = ToolContext.new(cwd: dir, assigns: %{gh_binary: fake})
    {:ok, dir: dir, fake: fake, ctx: ctx}
  end

  describe "metadata" do
    test "name/0 returns gh" do
      assert Gh.name() == "gh"
    end

    test "Gh is in the builtins registry" do
      assert ExAthena.Tools.Gh in ExAthena.Tools.builtins()
    end

    test "find/2 resolves \"gh\" to the Gh module" do
      assert ExAthena.Tools.find(Tools.builtins(), "gh") == Gh
    end

    test "parallel_safe?/0 is true" do
      assert Gh.parallel_safe?() == true
    end

    test "read_only?/0 is true" do
      assert Gh.read_only?() == true
    end

    test "\"gh\" is allowed under :plan mode" do
      tc = %ToolCall{id: "c1", name: "gh", arguments: %{}}
      ctx = ToolContext.new(cwd: "/tmp", phase: :plan)
      assert :allow = Permissions.check(tc, ctx, %{})
    end

    test "\"gh\" appears in Permissions.readonly_tools/0" do
      assert "gh" in Permissions.readonly_tools()
    end
  end

  describe "read-only enforcement" do
    test "accepts view/list/status/search read commands", %{ctx: ctx} do
      for cmd <- [
            "issue view 123",
            "pr list --state open",
            "repo view --json name,description",
            "release view v1.2",
            "run view 42 --log",
            "status",
            "search issues ex_athena"
          ] do
        assert {:ok, _out, _ui} = Gh.execute(%{"command" => cmd}, ctx)
      end
    end

    test "rejects mutating commands", %{ctx: ctx} do
      assert {:error, {:not_read_only, msg}} =
               Gh.execute(%{"command" => "pr create --title hi --body there"}, ctx)

      assert msg =~ "read-only"
    end

    test "rejects `gh api` (can POST)", %{ctx: ctx} do
      assert {:error, {:not_read_only, _}} = Gh.execute(%{"command" => "api /repos"}, ctx)
    end

    test "rejects `gh issue edit` (verb not in the read-only set)", %{ctx: ctx} do
      assert {:error, {:not_read_only, _}} = Gh.execute(%{"command" => "issue edit 123"}, ctx)
    end

    test "missing command rejected", %{ctx: ctx} do
      assert {:error, :missing_command} = Gh.execute(%{}, ctx)
      assert {:error, :missing_command} = Gh.execute(%{"command" => "   "}, ctx)
    end
  end

  describe "execution" do
    test "runs a read-only command and captures output", %{ctx: ctx} do
      assert {:ok, out, ui} = Gh.execute(%{"command" => "issue view 123"}, ctx)

      assert out =~ "exit 0"
      assert out =~ "fake gh: issue view 123"

      # Reuses the `:process` UI kind so the TUI/web renderers work unchanged.
      assert ui.kind == :process
      assert ui.payload.command == "gh issue view 123"
      assert ui.payload.exit_code == 0
      assert ui.payload.stdout =~ "fake gh: issue view 123"
      assert is_integer(ui.payload.duration_ms)
    end

    test "surfaces a non-zero exit with gh's own message", %{dir: dir} do
      fail_gh = Path.join(dir, "fail_gh")
      File.write!(fail_gh, "#!/bin/sh\necho 'gh: Not logged in' >&2\nexit 1\n")
      File.chmod!(fail_gh, 0o755)

      ctx = ToolContext.new(cwd: dir, assigns: %{gh_binary: fail_gh})

      assert {:ok, out, ui} = Gh.execute(%{"command" => "issue view 123"}, ctx)
      assert out =~ "exit 1"
      assert out =~ "Not logged in"
      assert ui.payload.exit_code == 1
    end

    test "a missing binary yields a descriptive error, not a crash", %{dir: dir} do
      ctx = ToolContext.new(cwd: dir, assigns: %{gh_binary: "/nonexistent/no_such_gh_xyz"})

      assert {:error, msg} = Gh.execute(%{"command" => "issue view 123"}, ctx)
      assert to_string(msg) =~ "GitHub CLI"
    end
  end
end
