defmodule ExAthena.Web.RunServerTest do
  # Not async: the registry/supervisor are globally named (mirroring how
  # `mix athena.web` starts them), so the module owns those names alone.
  use ExUnit.Case, async: false

  alias ExAthena.Messages
  alias ExAthena.Web.RunServer

  setup do
    start_supervised!({Registry, keys: :unique, name: ExAthena.Web.RunRegistry})

    start_supervised!(
      {DynamicSupervisor, name: ExAthena.Web.RunSupervisor, strategy: :one_for_one}
    )

    :ok
  end

  # A run whose provider blocks until the test sends `:finish`, so the run is
  # deterministically "in flight" while we attach/inspect. The responder runs
  # inside the run Task, so `self()` there is the task pid we unblock.
  defp blocking_run(session_id, assistant_msg_id \\ "amsg") do
    test_pid = self()

    responder = fn _request ->
      send(test_pid, {:run_task, self()})

      receive do
        :finish ->
          %ExAthena.Response{
            text: "final answer",
            tool_calls: [],
            finish_reason: :stop,
            provider: :mock
          }
      end
    end

    {:ok, _pid} =
      RunServer.start_run(session_id, %{
        run_opts: [
          provider: :mock,
          mock: [responder: responder],
          messages: [Messages.user("hi")]
        ],
        assistant_msg_id: assistant_msg_id,
        run_sid: "#{session_id}-run-#{assistant_msg_id}"
      })

    assert_receive {:run_task, task}, 2_000
    task
  end

  test "attaching mid-run returns a live snapshot scoped to the run" do
    sid = "s-snapshot"
    task = blocking_run(sid)

    assert RunServer.running?(sid)
    assert {:ok, snap} = RunServer.attach(sid, self())
    assert snap.streaming
    assert snap.pending_assistant_msg_id == "amsg"
    assert snap.run_sid == "s-snapshot-run-amsg"

    send(task, :finish)
    assert_receive {:athena_done, %{text: "final answer"}}, 2_000
  end

  test "a finished run is no longer attachable (caller loads the saved session)" do
    sid = "s-finished"
    task = blocking_run(sid)
    {:ok, _} = RunServer.attach(sid, self())

    send(task, :finish)
    assert_receive {:athena_done, _result}, 2_000

    refute RunServer.running?(sid)
    assert {:error, :not_running} = RunServer.attach(sid, self())
  end

  test "the run survives the original subscriber dying and a reconnect re-attaches" do
    sid = "s-reconnect"
    task = blocking_run(sid)

    # The original "LiveView" attaches, then dies (websocket drop).
    original =
      spawn(fn ->
        RunServer.attach(sid, self())
        receive do: (:never -> :ok)
      end)

    ref = Process.monitor(original)
    Process.exit(original, :kill)
    assert_receive {:DOWN, ^ref, :process, ^original, :killed}, 1_000

    # The run is still in flight despite no UI attached.
    assert RunServer.running?(sid)

    # The reconnecting LiveView (this test pid) re-attaches and receives the
    # completion it would otherwise have missed.
    assert {:ok, %{streaming: true}} = RunServer.attach(sid, self())
    send(task, :finish)
    assert_receive {:athena_done, %{text: "final answer"}}, 2_000
  end

  # Structural events were fanned out to whoever was subscribed at that instant
  # and then dropped (`accumulate/2` ended in a catch-all that discarded them).
  # A user who reloaded the page mid-run lost every spawn/result/iteration from
  # the disconnected window — permanently, and with no gap marker, so a spawn
  # from before the drop rendered directly against a result from after it.
  describe "event retention across a disconnect" do
    defp emit(sid, event), do: send(RunServer.whereis(sid), {:run_event, event})

    defp tool_call(id, name), do: %{id: id, name: name, arguments: %{}}

    test "a reattaching subscriber receives the events it missed" do
      sid = "s-retain"
      task = blocking_run(sid)

      {:ok, _} = RunServer.attach(sid, self())
      emit(sid, {:iteration, 1})
      assert_receive {:athena, {:iteration, 1}}, 1_000

      # The UI goes away (reload) and misses the whole middle of the run.
      RunServer.detach(sid, self())
      emit(sid, {:subagent_spawn, %{id: "sub_a", prompt: "explore"}})
      emit(sid, {:subagent_result, %{id: "sub_a", text: "found it"}})
      emit(sid, {:iteration, 2})

      assert {:ok, snap} = RunServer.attach(sid, self())

      # The live run emits its own events too, so assert on the relative order
      # of ours rather than the whole list.
      assert [
               {:iteration, 1},
               {:subagent_spawn, %{id: "sub_a", prompt: "explore"}},
               {:subagent_result, %{id: "sub_a", text: "found it"}},
               {:iteration, 2}
             ] ==
               Enum.filter(snap.events, fn
                 {:iteration, n} -> n in [1, 2]
                 {kind, _} -> kind in [:subagent_spawn, :subagent_result]
               end)

      send(task, :finish)
      assert_receive {:athena_done, _}, 2_000
    end

    # Token deltas already fold into `stream_text`, and retaining every one of
    # them would swamp the history with the least structural event types.
    test "content and thinking deltas are not retained (stream_text carries them)" do
      sid = "s-retain-deltas"
      task = blocking_run(sid)

      emit(sid, {:content, "hel"})
      emit(sid, {:content, "lo"})
      emit(sid, {:thinking, "hmm"})
      emit(sid, {:tool_call, tool_call("c1", "read")})

      assert {:ok, snap} = RunServer.attach(sid, self())

      refute Enum.any?(snap.events, &match?({:content, _}, &1))
      refute Enum.any?(snap.events, &match?({:thinking, _}, &1))
      assert Enum.any?(snap.events, &match?({:tool_call, %{id: "c1"}}, &1))
      assert snap.stream_text == "hello"

      send(task, :finish)
      assert_receive {:athena_done, _}, 2_000
    end

    test "history is capped so a long run cannot grow without bound" do
      sid = "s-retain-cap"
      task = blocking_run(sid)

      for n <- 1..(RunServer.max_retained_events() + 25), do: emit(sid, {:iteration, n})

      assert {:ok, snap} = RunServer.attach(sid, self())

      assert length(snap.events) == RunServer.max_retained_events()
      # The cap drops the OLDEST events — the recent past is what a
      # reattaching client needs to rebuild its view.
      assert List.last(snap.events) == {:iteration, RunServer.max_retained_events() + 25}

      send(task, :finish)
      assert_receive {:athena_done, _}, 2_000
    end
  end

  test "stop_run kills the in-flight run and retires the server" do
    sid = "s-stop"
    server = RunServer.whereis(sid)
    assert is_nil(server)

    _task = blocking_run(sid)
    server = RunServer.whereis(sid)
    sref = Process.monitor(server)

    :ok = RunServer.stop_run(sid)
    assert_receive {:DOWN, ^sref, :process, ^server, :normal}, 5_000
    refute RunServer.running?(sid)
  end
end
