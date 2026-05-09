defmodule ExAthena.Lsp.ManagerTest do
  use ExUnit.Case, async: false

  alias ExAthena.Lsp.Manager

  @fake_server_script Path.expand("../../support/fake_lsp_server.exs", __DIR__)
  @elixir_bin System.find_executable("elixir")

  # Override :lsp_servers so Manager resolves to our fake server binary
  # instead of the real elixir-ls binary (which may not be installed).
  defp setup_lsp_override do
    Application.put_env(:ex_athena, :lsp_servers, %{
      # --erl "-noinput" prevents the Erlang :user group leader from competing
      # with our Port.open({:fd, 0, 1}) reads in the fake server's VM.
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

  describe "ensure_started/2" do
    setup do
      setup_lsp_override()
      start_lsp_supervisor()
      :ok
    end

    test "returns {:ok, pid} and spawns a client" do
      root = unique_root()
      assert {:ok, pid} = Manager.ensure_started(root, :elixir)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "second call for same (root, language) returns the same pid" do
      handler_id = "test-lsp-spawn-#{System.unique_integer()}"

      spawn_events = :ets.new(:spawn_events, [:bag, :public])

      :telemetry.attach(
        handler_id,
        [:ex_athena, :lsp, :spawn],
        fn _event, _measurements, metadata, table ->
          :ets.insert(table, {:event, metadata})
        end,
        spawn_events
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      root = unique_root()
      {:ok, pid1} = Manager.ensure_started(root, :elixir)
      {:ok, pid2} = Manager.ensure_started(root, :elixir)

      assert pid1 == pid2

      # Only one :started spawn event for this root (the second call was a registry hit)
      # Give a moment for any stray events
      Process.sleep(100)
      events = :ets.lookup(spawn_events, :event)

      started_count =
        Enum.count(events, fn {:event, meta} -> meta.phase == :started and meta.root == root end)

      assert started_count == 1
    end

    test "different roots spawn different pids" do
      root1 = unique_root()
      root2 = unique_root()

      {:ok, pid1} = Manager.ensure_started(root1, :elixir)
      {:ok, pid2} = Manager.ensure_started(root2, :elixir)

      assert pid1 != pid2
    end

    test "returns {:error, {:no_server, language}} for unknown language" do
      # :unknown_lang has no override and no real binary
      root = unique_root()
      assert {:error, {:no_server, :unknown_lang}} = Manager.ensure_started(root, :unknown_lang)
    end
  end

  describe "client_for_file/2" do
    setup do
      setup_lsp_override()
      start_lsp_supervisor()
      :ok
    end

    test "returns {:ok, pid} for a known extension" do
      root = unique_root()
      assert {:ok, pid} = Manager.client_for_file(root, "foo.ex")
      assert is_pid(pid)
    end

    test "returns {:error, :unsupported_language} for unknown extension" do
      root = unique_root()
      assert {:error, :unsupported_language} = Manager.client_for_file(root, "foo.unknown")
    end
  end

  describe "stop/2" do
    setup do
      setup_lsp_override()
      start_lsp_supervisor()
      :ok
    end

    test "terminates the client and allows a fresh spawn" do
      root = unique_root()
      {:ok, pid1} = Manager.ensure_started(root, :elixir)
      ref = Process.monitor(pid1)

      :ok = Manager.stop(root, :elixir)
      assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 3_000

      # A new ensure_started should spawn a fresh pid.
      {:ok, pid2} = Manager.ensure_started(root, :elixir)
      assert pid2 != pid1
      assert Process.alive?(pid2)
    end

    test "stop/2 on non-existent client returns :ok" do
      root = unique_root()
      assert :ok = Manager.stop(root, :elixir)
    end
  end

  describe "list/0" do
    setup do
      setup_lsp_override()
      start_lsp_supervisor()
      :ok
    end

    test "includes running clients" do
      root = unique_root()
      {:ok, pid} = Manager.ensure_started(root, :elixir)

      entries = Manager.list()

      assert Enum.any?(entries, fn e ->
               e.root == root and e.language == :elixir and e.pid == pid
             end)
    end
  end

  # --- helpers ---

  defp unique_root do
    # Each test calls this AFTER `start_supervised!` runs in setup, so an
    # `on_exit` cleanup here would fire BEFORE the supervisor stops the spawned
    # LSP VM (LIFO order) — the VM would then see a missing cwd and emit
    # "Runtime terminating during boot" noise. Leave the empty dir in /tmp;
    # the OS reaps it. The point of this fix is just to make `cd:` succeed.
    root = Path.join(System.tmp_dir!(), "lsp_manager_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end
end
