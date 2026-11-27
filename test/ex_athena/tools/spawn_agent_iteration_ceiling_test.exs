defmodule ExAthena.Tools.SpawnAgentIterationCeilingTest do
  @moduledoc """
  A model picks `max_iterations` for the worker it spawns. With the token total
  off by default (#310), that number is the only turn guard a worker has besides
  its clock, so the setting `agents.max_requested_iterations` caps what a model
  may ask for. A host's own `max_iterations` in `spawn_agent_opts` is not a model
  request and stays as set.
  """
  use ExUnit.Case, async: false

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  # Counts worker calls. Never finishes on its own; the safety stop at 400
  # calls only keeps a broken ceiling from hanging the suite.
  defp never_finishing_worker(counter) do
    fn _req ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) > 400 do
        %Response{text: "safety stop", finish_reason: :stop, provider: :mock}
      else
        %Response{
          text: "still working",
          tool_calls: [%ToolCall{id: "w1", name: "todo_write", arguments: %{"todos" => []}}],
          finish_reason: :tool_calls,
          provider: :mock
        }
      end
    end
  end

  defp parent_responder(requested) do
    parent_calls = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(parent_calls, 1, 1)

      if :counters.get(parent_calls, 1) == 1 do
        %Response{
          text: "delegating",
          tool_calls: [
            %ToolCall{
              id: "c1",
              name: "spawn_agent",
              arguments: %{"prompt" => "do the work", "max_iterations" => requested}
            }
          ],
          finish_reason: :tool_calls,
          provider: :mock
        }
      else
        %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "spawn_ceiling_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:ex_athena, :agents)

    on_exit(fn ->
      File.rm_rf!(dir)

      if previous,
        do: Application.put_env(:ex_athena, :agents, previous),
        else: Application.delete_env(:ex_athena, :agents)
    end)

    {:ok, dir: dir}
  end

  defp worker_turns(dir, requested, worker_opts \\ []) do
    counter = :counters.new(1, [:atomics])

    {:ok, _} =
      Loop.run("coordinate",
        provider: :mock,
        mock: [responder: parent_responder(requested)],
        tools: [ExAthena.Tools.SpawnAgent],
        cwd: dir,
        memory: false,
        max_iterations: 5,
        assigns: %{
          spawn_agent_opts:
            Keyword.merge(
              [
                provider: :mock,
                mock: [responder: never_finishing_worker(counter)],
                tools: [ExAthena.Tools.TodoWrite],
                memory: false,
                max_unproductive_iterations: 10_000,
                max_consecutive_mistakes: 10_000
              ],
              worker_opts
            )
        }
      )

    :counters.get(counter, 1)
  end

  test "a model asking for 10,000 turns gets the default ceiling of 200", %{dir: dir} do
    assert worker_turns(dir, 10_000) == 200
  end

  test "a host can raise the ceiling", %{dir: dir} do
    Application.put_env(:ex_athena, :agents, max_requested_iterations: 300)
    assert worker_turns(dir, 10_000) == 300
  end

  test "0 switches the ceiling off", %{dir: dir} do
    Application.put_env(:ex_athena, :agents, max_requested_iterations: 0)
    # the mock's safety stop ends the run at 401 calls
    assert worker_turns(dir, 10_000) > 400
  end

  test "a request under the ceiling is kept, floored up to the default", %{dir: dir} do
    assert worker_turns(dir, 120) == 120
    assert worker_turns(dir, 5) == 50
  end

  test "a ceiling under the floor never takes a worker below the floor", %{dir: dir} do
    Application.put_env(:ex_athena, :agents, max_requested_iterations: 20)
    assert worker_turns(dir, 5) == 50
    assert worker_turns(dir, 10_000) == 50
  end

  test "a bad ceiling value falls back to the default, only 0 switches it off", %{dir: dir} do
    for bad <- [-1, 200.0, "200", nil] do
      Application.put_env(:ex_athena, :agents, max_requested_iterations: bad)
      assert worker_turns(dir, 10_000) == 200, "#{inspect(bad)} should fall back to 200"
    end
  end

  test "a host's own max_iterations is not a model request", %{dir: dir} do
    assert worker_turns(dir, 10_000, max_iterations: 250) == 250
  end
end
