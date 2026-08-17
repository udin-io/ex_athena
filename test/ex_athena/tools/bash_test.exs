defmodule ExAthena.Tools.BashTest do
  use ExUnit.Case, async: true

  alias ExAthena.ToolContext
  alias ExAthena.Tools.Bash

  setup do
    dir = Path.join(System.tmp_dir!(), "bash_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, ctx: ToolContext.new(cwd: dir)}
  end

  test "runs a command and captures output", %{ctx: ctx} do
    assert {:ok, output, ui} = Bash.execute(%{"command" => "echo hello"}, ctx)
    assert output =~ "exit 0"
    assert output =~ "hello"

    assert ui.kind == :process
    assert ui.payload.exit_code == 0
    assert ui.payload.command == "echo hello"
    assert is_integer(ui.payload.duration_ms)
  end

  test "captures non-zero exit codes", %{ctx: ctx} do
    assert {:ok, output, ui} = Bash.execute(%{"command" => "exit 7"}, ctx)
    assert output =~ "exit 7"
    assert ui.payload.exit_code == 7
  end

  test "huge output is capped (head + tail) instead of flooding the context", %{ctx: ctx} do
    # ~1.2 MB of output — observed live: `find .` dumps blew a worker's
    # context to 204k tokens and starved it to error_max_turns.
    assert {:ok, output, _ui} = Bash.execute(%{"command" => "seq 1 200000"}, ctx)

    assert String.length(output) <= 17_000
    assert output =~ "exit 0"
    # Head survives…
    assert output =~ "\n1\n2\n"
    # …the tail survives (exit-adjacent lines often carry the signal)…
    assert output =~ "200000"
    # …and the cut is explicit so the model narrows the command.
    assert output =~ "truncated"
  end

  test "runs in the context's cwd", %{dir: dir, ctx: ctx} do
    assert {:ok, output, _ui} = Bash.execute(%{"command" => "pwd"}, ctx)
    # macOS symlinks /tmp → /private/tmp; compare the resolved path.
    resolved = File.cwd!() |> Path.expand() && dir |> Path.expand() |> Path.relative_to("/")
    assert output =~ resolved
  end

  test "times out", %{ctx: ctx} do
    assert {:error, :timeout} =
             Bash.execute(%{"command" => "sleep 2", "timeout_ms" => 100}, ctx)
  end

  test "missing command rejected", %{ctx: ctx} do
    assert {:error, :missing_command} = Bash.execute(%{}, ctx)
  end

  describe "confinement (allowed_roots)" do
    setup do
      # Use dirs under the repo (NOT system temp, which the sandbox keeps
      # writable) so an out-of-root write is genuinely outside the boundary.
      base = Path.join(File.cwd!(), "tmp")
      uniq = System.unique_integer([:positive])
      root = Path.join(base, "sbx_root_#{uniq}")
      outside = Path.join(base, "sbx_out_#{uniq}")
      File.mkdir_p!(root)
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(root) && File.rm_rf!(outside) end)
      {:ok, root: root, outside: outside, ctx: ToolContext.new(cwd: root, allowed_roots: [root])}
    end

    test "writes inside a root succeed", %{root: root, ctx: ctx} do
      inside = Path.join(root, "ok.txt")
      assert {:ok, _out, _ui} = Bash.execute(%{"command" => "echo hi > #{inside}"}, ctx)
      assert File.read!(inside) =~ "hi"
    end

    test "writes outside the roots are blocked when an OS sandbox is available",
         %{outside: outside, ctx: ctx} do
      target = Path.join(outside, "escape.txt")
      Bash.execute(%{"command" => "echo leaked > #{target}"}, ctx)

      if ExAthena.Sandbox.available?() do
        refute File.exists?(target), "sandbox should have denied the out-of-root write"
      end
    end
  end

  describe "sandbox unavailable (fail-closed — issue #135)" do
    # `ctx.assigns[:sandbox_finder]` is the executable-lookup seam: a finder
    # that always returns nil simulates a host with no sandbox-exec/bwrap,
    # independent of what this machine actually has installed.
    defp no_helper, do: %{sandbox_finder: fn _bin -> nil end}

    setup %{dir: dir} do
      confined =
        ToolContext.new(cwd: dir, allowed_roots: [dir], assigns: no_helper())

      best_effort =
        ToolContext.new(
          cwd: dir,
          allowed_roots: [dir],
          confine_mode: :best_effort,
          assigns: no_helper()
        )

      {:ok, confined: confined, best_effort: best_effort}
    end

    test "confinement requested + no helper → typed refusal naming the helper, command NOT run",
         %{dir: dir, confined: ctx} do
      marker = Path.join(dir, "ran.txt")
      helper = ExAthena.Sandbox.required_helper()

      assert {:error, {:sandbox_unavailable, ^helper}} =
               Bash.execute(%{"command" => "echo leaked > #{marker}"}, ctx)

      refute File.exists?(marker), "fail-closed: the command must not run unconfined"
    end

    test "refusal emits a telemetry event", %{confined: ctx} do
      handler = "sbx-deny-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:ex_athena, :sandbox, :unavailable],
        fn _event, _measurements, meta, _cfg -> send(parent, {:sandbox_unavailable, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, {:sandbox_unavailable, _helper}} =
               Bash.execute(%{"command" => "true"}, ctx)

      assert_receive {:sandbox_unavailable, meta}
      assert meta.outcome == :denied
      assert meta.helper == ExAthena.Sandbox.required_helper()
    end

    test "confine_mode :best_effort + no helper → runs unconfined with a warning",
         %{dir: dir, best_effort: ctx} do
      marker = Path.join(dir, "ran.txt")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, output, _ui} =
                   Bash.execute(%{"command" => "echo hi > #{marker} && cat #{marker}"}, ctx)

          assert output =~ "exit 0"
          assert output =~ "hi"
        end)

      assert File.exists?(marker)
      assert log =~ "UNCONFINED"
    end

    test "best-effort degrade emits a telemetry event", %{best_effort: ctx} do
      handler = "sbx-degrade-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:ex_athena, :sandbox, :unavailable],
        fn _event, _measurements, meta, _cfg -> send(parent, {:sandbox_unavailable, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _output, _ui} = Bash.execute(%{"command" => "true"}, ctx)
      end)

      assert_receive {:sandbox_unavailable, meta}
      assert meta.outcome == :ran_unconfined
    end

    test "unconfined runs are unaffected by a missing helper", %{dir: dir} do
      ctx = ToolContext.new(cwd: dir, assigns: no_helper())
      assert {:ok, output, _ui} = Bash.execute(%{"command" => "echo free"}, ctx)
      assert output =~ "free"
    end

    test "helper present → wrapped exactly as before (no refusal)", %{dir: dir} do
      # A finder that reports every binary as present. `wrap/4` (pure argv
      # building) must choose the sandboxed form; Bash-level end-to-end
      # coverage with a REAL helper lives in the confinement describe above.
      finder = fn bin -> "/fake/bin/#{bin}" end

      assert {:ok, {exe, _args}} =
               ExAthena.Sandbox.wrap("echo hi", [dir], dir, finder: finder)

      assert exe in ["/fake/bin/sandbox-exec", "/fake/bin/bwrap"]
    end
  end
end
