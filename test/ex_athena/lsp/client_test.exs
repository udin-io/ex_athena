defmodule ExAthena.Lsp.ClientTest do
  use ExUnit.Case, async: false

  alias ExAthena.Lsp.Client

  @fake_server_script Path.expand("../../support/fake_lsp_server.exs", __DIR__)
  @elixir_bin System.find_executable("elixir")
  @root System.tmp_dir!()

  defp start_client(opts \\ []) do
    default = [
      binary: @elixir_bin,
      # --erl "-noinput" prevents the Erlang :user group leader from competing
      # with our Port.open({:fd, 0, 1}) reads in the fake server's VM.
      args: ["--erl", "-noinput", @fake_server_script],
      root_uri: "file://#{@root}",
      root: @root,
      language: :test
    ]

    start_supervised!({Client, Keyword.merge(default, opts)})
  end

  # Waits until the client completes initialization by making a simple
  # request that requires the server to be ready.
  defp await_initialized(pid) do
    assert {:ok, _} = Client.request(pid, "textDocument/echo", %{"ping" => true}, 10_000)
  end

  describe "initialize handshake" do
    test "client starts successfully and completes initialize" do
      pid = start_client()
      # Initialization is async; wait for it by issuing a test request.
      assert {:ok, %{"ping" => true}} =
               Client.request(pid, "textDocument/echo", %{"ping" => true}, 10_000)

      assert Process.alive?(pid)
    end
  end

  describe "request/4" do
    test "textDocument/echo returns params verbatim" do
      pid = start_client()
      params = %{"x" => 1, "y" => "hello"}
      assert {:ok, result} = Client.request(pid, "textDocument/echo", params, 10_000)
      assert result["x"] == 1
      assert result["y"] == "hello"
    end

    test "unknown method returns error response" do
      pid = start_client()
      # Wait for initialization first.
      await_initialized(pid)
      assert {:error, _reason} = Client.request(pid, "unknown/method", %{}, 5_000)
    end

    test "ten concurrent requests each get the right reply" do
      pid = start_client()
      # Ensure initialized before issuing concurrent requests.
      await_initialized(pid)

      tasks =
        Enum.map(1..10, fn i ->
          Task.async(fn ->
            Client.request(pid, "textDocument/echo", %{"i" => i}, 10_000)
          end)
        end)

      results = Task.await_many(tasks, 15_000)

      Enum.each(Enum.zip(1..10, results), fn {i, result} ->
        assert {:ok, body} = result
        assert body["i"] == i
      end)
    end

    test "requests made before initialization are queued and completed after" do
      # Start client - initialization is async but requests queued before
      # initialization completes are replayed once initialized.
      pid =
        start_supervised!(
          {Client,
           [
             binary: @elixir_bin,
             args: ["--erl", "-noinput", @fake_server_script],
             root_uri: "file://#{@root}",
             root: @root,
             language: :test
           ]}
        )

      # This request is issued immediately and may arrive before initialization.
      # It should still succeed (either immediately or after initialization).
      assert {:ok, %{"queued" => true}} =
               Client.request(pid, "textDocument/echo", %{"queued" => true}, 15_000)
    end
  end

  describe "notify/3" do
    test "notif/trigger causes publishDiagnostics to be cached" do
      pid = start_client()
      await_initialized(pid)

      :ok = Client.notify(pid, "notif/trigger", %{})

      # Give the server time to push the notification back.
      # The diagnostics state is updated when handle_info processes the notification.
      assert_diagnostics(pid, "file:///test/foo.ex", 500)
    end
  end

  describe "diagnostics/2" do
    test "returns empty list for unknown uri" do
      pid = start_client()
      await_initialized(pid)
      assert Client.diagnostics(pid, "file:///nonexistent.ex") == []
    end
  end

  describe "telemetry" do
    setup do
      handler_id = "test-lsp-request-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:ex_athena, :lsp, :request, :stop],
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, {:telemetry_stop, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "[:ex_athena, :lsp, :request, :stop] fires with method metadata" do
      pid = start_client()
      {:ok, _} = Client.request(pid, "textDocument/echo", %{"k" => 1}, 10_000)

      assert_receive {:telemetry_stop, meta}, 3_000
      assert meta.method == "textDocument/echo"
      assert meta.language == :test
    end
  end

  describe "spawn telemetry" do
    test "[:ex_athena, :lsp, :spawn] fires with phase: :started on init" do
      handler_id = "test-lsp-spawn-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:ex_athena, :lsp, :spawn],
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, {:telemetry_spawn, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      _pid = start_client()

      assert_receive {:telemetry_spawn, %{phase: :started}}, 3_000
    end
  end

  describe "stop/2" do
    test "stop/2 shuts down cleanly" do
      pid = start_client()
      await_initialized(pid)

      ref = Process.monitor(pid)
      assert :ok = Client.stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 3_000
    end
  end

  # --- helpers ---

  defp assert_diagnostics(pid, uri, max_wait_ms, attempts \\ 20) do
    case Client.diagnostics(pid, uri) do
      [] when attempts > 0 ->
        Process.sleep(div(max_wait_ms, 20))
        assert_diagnostics(pid, uri, max_wait_ms, attempts - 1)

      [] ->
        flunk("No diagnostics for #{uri} after #{max_wait_ms}ms")

      diags ->
        diags
    end
  end
end
