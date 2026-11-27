defmodule ExAthena.Orchestrator.WorkerLiveStreamTest do
  @moduledoc """
  A worker's reply reaches the coordinator while the model is still writing it,
  not once its turn ends (issue 311).
  """
  use ExUnit.Case, async: false

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Orchestrator.{AgentInfo, Coordinator}
  alias ExAthena.Streaming.Event

  setup do
    dir = Path.join(System.tmp_dir!(), "live_stream_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "the worker's text is in the coordinator before its turn ends", %{dir: dir} do
    sid = "live-#{System.unique_integer([:positive])}"
    {:ok, coord} = Coordinator.start_for(sid)
    test_pid = self()

    parent = fn _request ->
      n = Process.get(:parent_calls, 0)
      Process.put(:parent_calls, n + 1)

      if n == 0 do
        %Response{
          text: "Delegating.",
          tool_calls: [%ToolCall{id: "t1", name: "spawn_agent", arguments: %{"prompt" => "go"}}],
          finish_reason: :tool_calls,
          provider: :mock
        }
      else
        %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    end

    # The mock streams its events first, then calls the responder: the
    # responder blocks, so the worker's turn has not ended while we look.
    calls = :counters.new(1, [])

    worker = fn _request ->
      :counters.add(calls, 1, 1)

      # Only the worker's first model call holds its turn open; any extra
      # call (a retry, a helper call) answers at once.
      if :counters.get(calls, 1) == 1 do
        send(test_pid, {:turn_open, self()})

        receive do
          :finish_turn -> :ok
        end
      end

      %Response{text: "alpha beta gamma", tool_calls: [], finish_reason: :stop, provider: :mock}
    end

    run =
      Task.async(fn ->
        Loop.run("go",
          provider: :mock,
          mock: [responder: parent],
          cwd: dir,
          memory: false,
          tools: [ExAthena.Tools.SpawnAgent],
          coordinator: coord,
          assigns: %{
            spawn_agent_opts: [
              provider: :mock,
              mock: [responder: worker],
              mock_events: [
                %Event{type: :text_delta, data: "alpha "},
                %Event{type: :text_delta, data: "beta "},
                %Event{type: :text_delta, data: "gamma"}
              ],
              tools: [],
              memory: false
            ]
          }
        )
      end)

    assert_receive {:turn_open, worker_pid}, 5_000
    {:ok, snap} = Coordinator.snapshot(sid)
    assert [%{status: :running} = worker_info] = snap.agents
    assert AgentInfo.live_text(worker_info) == "alpha beta gamma"
    send(worker_pid, :finish_turn)
    assert {:ok, _} = Task.await(run, 10_000)
    GenServer.stop(coord)
  end
end
