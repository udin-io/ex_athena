defmodule ExAthena.Tools.SpawnAgentUncountedTest do
  @moduledoc """
  A worker that runs out of budget is a fact about the worker, not a mistake by
  the parent — but a worker that went in circles or hallucinated its way to its
  own mistake ceiling IS the parent's problem, because re-delegating the same
  brief will do it again.

  Session 5906635b743d ran 3h36m over 17 workers, then died on
  `error_consecutive_mistakes` with all four deliverables complete on disk. The
  orchestrator was killed by a counter whose job is catching a model that
  hallucinates tool calls. Orchestrate mode sets `max_iterations: :infinity`, so
  that counter is its only turn-based guard — which makes this the binding
  failure mode rather than an edge case.

  The parent must still READ the failure (it has to re-plan), so the tool result
  keeps `is_error: true`; only the loop's accounting changes.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "spawn_uncounted_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Spawns a worker on each of the first `n` turns, then reports and stops.
  defp parent_responder(n) do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)
      turn = :counters.get(counter, 1)

      if turn <= n do
        %Response{
          text: "delegating step #{turn}",
          tool_calls: [
            %ToolCall{
              id: "c#{turn}",
              name: "spawn_agent",
              arguments: %{"prompt" => "do step #{turn}"}
            }
          ],
          finish_reason: :tool_calls,
          provider: :mock
        }
      else
        %Response{text: "finished with what I have", finish_reason: :stop, provider: :mock}
      end
    end
  end

  # Never stops on its own: with `max_iterations: 1` the worker terminates on
  # `error_max_turns` — a budget subtype.
  defp budget_starved_worker do
    fn _req ->
      %Response{
        text: "still working",
        tool_calls: [%ToolCall{id: "w1", name: "todo_write", arguments: %{"todos" => []}}],
        finish_reason: :tool_calls,
        provider: :mock
      }
    end
  end

  # Calls a tool that does not exist, every turn: each turn is a mistake, so the
  # worker dies on `error_consecutive_mistakes` — NOT a budget fact.
  defp hallucinating_worker do
    fn _req ->
      %Response{
        text: "calling a tool I invented",
        tool_calls: [%ToolCall{id: "w1", name: "definitely_not_a_tool", arguments: %{}}],
        finish_reason: :tool_calls,
        provider: :mock
      }
    end
  end

  defp run(dir, spawns, worker_responder, worker_opts) do
    Loop.run("coordinate the work",
      provider: :mock,
      mock: [responder: parent_responder(spawns)],
      tools: [ExAthena.Tools.SpawnAgent],
      cwd: dir,
      memory: false,
      max_iterations: 20,
      max_consecutive_mistakes: 3,
      assigns: %{
        spawn_agent_opts:
          Keyword.merge(
            [
              provider: :mock,
              mock: [responder: worker_responder],
              tools: [ExAthena.Tools.TodoWrite],
              memory: false
            ],
            worker_opts
          )
      }
    )
  end

  defp spawn_results(result) do
    result.messages
    |> Enum.filter(&match?(%{role: :tool}, &1))
    |> Enum.flat_map(& &1.tool_results)
  end

  test "three consecutive budget terminations leave the orchestrator running", %{dir: dir} do
    assert {:ok, result} = run(dir, 3, budget_starved_worker(), max_iterations: 1)

    # This is the session that failed: the parent survived to plan around the
    # workers it lost, instead of being killed by its own counter.
    refute result.finish_reason == :error_consecutive_mistakes
    assert result.finish_reason == :stop

    results = spawn_results(result)
    assert length(results) == 3

    # It must still READ as a failure — the parent has to know and re-plan.
    for tr <- results do
      assert tr.is_error == true
      assert tr.content =~ "error_max_turns"
    end
  end

  # A worker killed at its deadline is the same fact as one killed at its token
  # cap: it ran out of room, and the parent did nothing wrong. The timeout
  # returns from its own branch, so it needs its own guard.
  test "three consecutive worker timeouts leave the orchestrator running", %{dir: dir} do
    blocked = fn _req -> receive do: (:never -> :never) end

    assert {:ok, result} =
             run(dir, 3, blocked, timeout_ms: 1, max_iterations: 1)

    refute result.finish_reason == :error_consecutive_mistakes
    assert result.finish_reason == :stop

    for tr <- spawn_results(result) do
      assert tr.is_error == true
      assert tr.content =~ ~r/timed out|timeout/i
    end
  end

  test "three workers that died on their OWN mistake counter still kill the parent", %{dir: dir} do
    assert {:ok, result} = run(dir, 5, hallucinating_worker(), max_iterations: 10)

    # A worker looping on tool calls it invented is not a budget fact: repeating
    # the brief repeats the failure, and that is what the counter is for.
    assert result.finish_reason == :error_consecutive_mistakes
  end
end
