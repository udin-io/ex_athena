defmodule ExAthena.Lsp.ImplicitDiagnosticsTest do
  use ExUnit.Case, async: false

  alias ExAthena.Lsp.{Client, ImplicitDiagnostics, Manager}

  @fake_server_script Path.expand("../../support/fake_lsp_server.exs", __DIR__)
  @elixir_bin System.find_executable("elixir")

  defp setup_lsp_override do
    Application.put_env(:ex_athena, :lsp_servers, %{
      elixir: %{binary: @elixir_bin, args: ["--erl", "-noinput", @fake_server_script]}
    })

    on_exit(fn -> Application.delete_env(:ex_athena, :lsp_servers) end)
  end

  defp start_lsp_supervisor do
    start_supervised!({Registry, keys: :unique, name: ExAthena.Lsp.Registry})

    start_supervised!(
      {DynamicSupervisor, name: ExAthena.Lsp.ClientSupervisor, strategy: :one_for_one}
    )

    start_supervised!(Manager)
  end

  defp enable_implicit_diagnostics do
    Application.put_env(:ex_athena, :lsp_implicit_diagnostics_enabled, true)
    on_exit(fn -> Application.put_env(:ex_athena, :lsp_implicit_diagnostics_enabled, false) end)
  end

  defp unique_dir do
    dir = Path.join(System.tmp_dir!(), "impl_diag_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_elixir_file(dir, name \\ "test.ex") do
    path = Path.join(dir, name)
    File.write!(path, "defmodule Test do\nend\n")
    path
  end

  # ── Disabled config ───────────────────────────────────────────────

  test "returns :ok when lsp_implicit_diagnostics_enabled is false" do
    # test.exs sets this to false globally; no LSP setup needed
    dir = unique_dir()
    path = write_elixir_file(dir)

    payload = %{arguments: %{"path" => path}, cwd: dir, tool_name: "Edit"}
    assert :ok = ImplicitDiagnostics.post_tool_use_hook(payload, "c1")
  end

  # ── No path in arguments ──────────────────────────────────────────

  test "returns :ok when arguments map has no 'path' key" do
    enable_implicit_diagnostics()
    dir = unique_dir()

    payload = %{arguments: %{}, cwd: dir, tool_name: "Edit"}
    assert :ok = ImplicitDiagnostics.post_tool_use_hook(payload, "c1")
  end

  test "returns :ok when arguments is nil" do
    enable_implicit_diagnostics()
    dir = unique_dir()

    payload = %{arguments: nil, cwd: dir, tool_name: "Edit"}
    assert :ok = ImplicitDiagnostics.post_tool_use_hook(payload, "c1")
  end

  # ── Unknown extension ────────────────────────────────────────────

  test "returns :ok for files with unsupported extensions" do
    enable_implicit_diagnostics()
    dir = unique_dir()
    path = Path.join(dir, "notes.txt")
    File.write!(path, "hello")

    payload = %{arguments: %{"path" => path}, cwd: dir, tool_name: "Edit"}
    assert :ok = ImplicitDiagnostics.post_tool_use_hook(payload, "c1")
  end

  test "returns :ok for markdown files" do
    enable_implicit_diagnostics()
    dir = unique_dir()
    path = Path.join(dir, "README.md")
    File.write!(path, "# heading")

    payload = %{arguments: %{"path" => path}, cwd: dir, tool_name: "Edit"}
    assert :ok = ImplicitDiagnostics.post_tool_use_hook(payload, "c1")
  end

  # ── Manager unavailable ──────────────────────────────────────────

  test "returns :ok when no LSP manager is running" do
    enable_implicit_diagnostics()
    dir = unique_dir()
    path = write_elixir_file(dir)

    payload = %{arguments: %{"path" => path}, cwd: dir, tool_name: "Edit"}
    assert :ok = ImplicitDiagnostics.post_tool_use_hook(payload, "c1")
  end

  # ── Diagnostics returned ─────────────────────────────────────────

  describe "with LSP running" do
    setup do
      setup_lsp_override()
      start_lsp_supervisor()
      enable_implicit_diagnostics()
      dir = unique_dir()
      {:ok, dir: dir}
    end

    test "returns {:augment, text} containing error when fake server emits diagnostic", %{
      dir: dir
    } do
      path = write_elixir_file(dir)
      payload = %{arguments: %{"path" => path}, cwd: dir, tool_name: "Edit"}

      assert {:augment, text} = ImplicitDiagnostics.post_tool_use_hook(payload, "c1")
      assert text =~ "[lsp diagnostics]"
      assert text =~ "error"
      assert text =~ Path.basename(path)
    end

    test "returned text includes the file's relative path from cwd", %{dir: dir} do
      path = write_elixir_file(dir, "mymodule.ex")
      payload = %{arguments: %{"path" => path}, cwd: dir, tool_name: "Edit"}

      assert {:augment, text} = ImplicitDiagnostics.post_tool_use_hook(payload, "c1")
      assert text =~ "mymodule.ex"
    end

    test "returns :ok when diagnostics are filtered out by severity config", %{dir: dir} do
      Application.put_env(:ex_athena, :lsp_implicit_diagnostics_severities, [:warning])
      on_exit(fn -> Application.delete_env(:ex_athena, :lsp_implicit_diagnostics_severities) end)

      path = write_elixir_file(dir)
      payload = %{arguments: %{"path" => path}, cwd: dir, tool_name: "Edit"}

      assert :ok = ImplicitDiagnostics.post_tool_use_hook(payload, "c1")
    end

    test "returns :ok within timeout_ms when server emits no diagnostics", %{dir: dir} do
      path = write_elixir_file(dir)

      {:ok, pid} = Manager.client_for_file(dir, path)
      Client.notify(pid, "notif/suppress_next_diag", %{})

      Application.put_env(:ex_athena, :lsp_implicit_diagnostics_timeout_ms, 200)
      on_exit(fn -> Application.delete_env(:ex_athena, :lsp_implicit_diagnostics_timeout_ms) end)

      payload = %{arguments: %{"path" => path}, cwd: dir, tool_name: "Edit"}

      before_ms = System.monotonic_time(:millisecond)
      assert :ok = ImplicitDiagnostics.post_tool_use_hook(payload, "c1")
      elapsed = System.monotonic_time(:millisecond) - before_ms

      assert elapsed < 500, "Expected hook to complete within 500ms, took #{elapsed}ms"
    end

    test "telemetry :stop event fires with count and had_errors measurements", %{dir: dir} do
      test_pid = self()

      :telemetry.attach(
        "test-implicit-diag-#{System.unique_integer()}",
        [:ex_athena, :lsp, :implicit_diagnostics, :stop],
        fn _name, measurements, meta, _cfg ->
          send(test_pid, {:telemetry_stop, measurements, meta})
        end,
        nil
      )

      path = write_elixir_file(dir)
      payload = %{arguments: %{"path" => path}, cwd: dir, tool_name: "Edit"}

      ImplicitDiagnostics.post_tool_use_hook(payload, "c1")

      assert_receive {:telemetry_stop, measurements, meta}, 5_000
      assert is_integer(measurements.count)
      assert is_boolean(measurements.had_errors)
      assert meta.tool_name == "Edit"
    end

    test "path relative to cwd is resolved correctly for subdirectory files", %{dir: dir} do
      sub = Path.join(dir, "sub")
      File.mkdir_p!(sub)
      path = Path.join(sub, "mod.ex")
      File.write!(path, "defmodule Mod do\nend\n")

      payload = %{arguments: %{"path" => "sub/mod.ex"}, cwd: dir, tool_name: "Edit"}

      assert {:augment, _text} = ImplicitDiagnostics.post_tool_use_hook(payload, "c1")
    end
  end

  # ── default_hooks_entry/0 ─────────────────────────────────────────

  test "default_hooks_entry/0 returns a matcher group matching Edit and Write" do
    entry = ImplicitDiagnostics.default_hooks_entry()

    assert %{matcher: matcher, hooks: hooks} = entry
    assert is_binary(matcher)
    assert Regex.match?(Regex.compile!(matcher), "Edit")
    assert Regex.match?(Regex.compile!(matcher), "Write")
    refute Regex.match?(Regex.compile!(matcher), "Read")
    assert is_list(hooks)
    assert length(hooks) == 1
    assert is_function(hd(hooks), 2)
  end

  # ── maybe_merge/1 ─────────────────────────────────────────────────

  test "maybe_merge/1 returns hooks unchanged when diagnostics disabled" do
    # test.exs disables it globally
    hooks = %{PostToolUse: [%{hooks: [fn _, _ -> :ok end]}]}
    assert ImplicitDiagnostics.maybe_merge(hooks) == hooks
  end

  test "maybe_merge/1 prepends implicit hook when diagnostics enabled" do
    Application.put_env(:ex_athena, :lsp_implicit_diagnostics_enabled, true)
    on_exit(fn -> Application.put_env(:ex_athena, :lsp_implicit_diagnostics_enabled, false) end)

    user_hook = fn _, _ -> :ok end
    hooks = %{PostToolUse: [%{hooks: [user_hook]}]}

    merged = ImplicitDiagnostics.maybe_merge(hooks)
    assert [first | rest] = merged[:PostToolUse]
    assert first.hooks == [&ImplicitDiagnostics.post_tool_use_hook/2]
    assert [%{hooks: [^user_hook]}] = rest
  end

  test "maybe_merge/1 initialises PostToolUse key when absent" do
    Application.put_env(:ex_athena, :lsp_implicit_diagnostics_enabled, true)
    on_exit(fn -> Application.put_env(:ex_athena, :lsp_implicit_diagnostics_enabled, false) end)

    merged = ImplicitDiagnostics.maybe_merge(%{})
    assert [entry] = merged[:PostToolUse]
    assert %{matcher: _, hooks: _} = entry
  end
end
