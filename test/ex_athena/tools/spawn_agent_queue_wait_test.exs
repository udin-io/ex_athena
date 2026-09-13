defmodule ExAthena.Tools.SpawnAgentQueueWaitTest do
  @moduledoc """
  A worker must not be killed for time it spent queued behind another agent.

  `ExAthena.RequestQueue` gates every provider call, and local backends serve
  one request at a time (`Config` defaults ollama/llamacpp/exo to a single
  slot). The loop enters that queue with `timeout: :infinity` precisely
  because "a queued subagent legitimately waits minutes for a slot" — but the
  spawn timeout was wall clock, so those minutes were charged to the worker
  and it was killed mid-task with its findings discarded.
  """
  # Not async: the request queue and its per-provider depth are global.
  use ExUnit.Case, async: false

  alias ExAthena.{RequestQueue, Response, ToolContext}
  alias ExAthena.Tools.SpawnAgent

  @provider :mock

  setup do
    previous_queue = Application.get_env(:ex_athena, :request_queue)
    previous_mock = Application.get_env(:ex_athena, @provider)

    # One slot, so a single held slot is enough to block the worker.
    Application.put_env(:ex_athena, :request_queue, enabled: true)
    Application.put_env(:ex_athena, @provider, request_queue: [max_depth: 1])

    on_exit(fn ->
      restore(:request_queue, previous_queue)
      restore(@provider, previous_mock)
    end)

    start_supervised!(RequestQueue)

    dir = Path.join(System.tmp_dir!(), "queue_wait_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  defp restore(key, nil), do: Application.delete_env(:ex_athena, key)
  defp restore(key, value), do: Application.put_env(:ex_athena, key, value)

  # Holds the provider's only slot from a separate process until told to let
  # go, so the worker under test blocks in the queue rather than on the model.
  defp hog_the_slot do
    test_pid = self()

    hog =
      spawn_link(fn ->
        RequestQueue.with_slot(@provider, fn ->
          send(test_pid, :slot_held)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :slot_held, 5_000
    hog
  end

  test "queue time is credited back instead of counting against the budget", %{dir: dir} do
    hog = hog_the_slot()

    # The worker answers the instant it gets a slot; all of its elapsed time
    # is queue wait.
    responder = fn _request ->
      %Response{text: "worked", finish_reason: :stop, provider: :mock}
    end

    ctx =
      ToolContext.new(
        cwd: dir,
        assigns: %{
          spawn_agent_opts: [
            provider: @provider,
            mock: [responder: responder],
            memory: false,
            # Far less than the time it will spend queued below.
            timeout_ms: 1_000
          ]
        }
      )

    spawn_result =
      Task.async(fn -> SpawnAgent.execute(%{"prompt" => "work"}, ctx) end)

    # Comfortably past the worker's whole budget, with it still queued.
    Process.sleep(2_500)
    send(hog, :release)

    assert {:ok, text, _ui} = Task.await(spawn_result, 15_000)
    assert text =~ "worked"
  end

  test "the budget still runs out on time once the worker is actually working", %{dir: dir} do
    responder = fn _request -> Process.sleep(:infinity) end

    ctx =
      ToolContext.new(
        cwd: dir,
        assigns: %{
          spawn_agent_opts: [
            provider: @provider,
            mock: [responder: responder],
            memory: false,
            timeout_ms: 1_000
          ]
        }
      )

    {elapsed_us, result} = :timer.tc(fn -> SpawnAgent.execute(%{"prompt" => "work"}, ctx) end)

    assert {:error, :uncounted, message} = result
    assert message =~ "timed out after 1000ms"
    assert div(elapsed_us, 1_000) < 10_000
  end
end
