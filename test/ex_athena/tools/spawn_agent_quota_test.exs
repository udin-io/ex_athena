defmodule ExAthena.Tools.SpawnAgentQuotaTest do
  @moduledoc """
  What a run learns about its worker allowance, and what happens when it is
  spent.

  Session 227f7f480afa hit its cap of 10 workers. Nothing had told the
  orchestrator how many were left, so it spent two of them on 30-minute
  retries of one bug. The refusal then bumped its mistake counter and told a
  model holding no read or write tools to "do the remaining work yourself".
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "spawn_quota_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Spawns a worker on each of the first `n` turns, then stops.
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
        %Response{text: "finishing with what I have", finish_reason: :stop, provider: :mock}
      end
    end
  end

  defp worker do
    fn _req -> %Response{text: "step done", finish_reason: :stop, provider: :mock} end
  end

  defp run(dir, spawns, assigns) do
    Loop.run("coordinate the work",
      provider: :mock,
      mock: [responder: parent_responder(spawns)],
      tools: [ExAthena.Tools.SpawnAgent],
      cwd: dir,
      memory: false,
      max_iterations: 20,
      max_consecutive_mistakes: 1,
      assigns:
        Map.merge(
          %{
            spawn_agent_opts: [
              provider: :mock,
              mock: [responder: worker()],
              tools: [ExAthena.Tools.TodoWrite],
              memory: false
            ]
          },
          assigns
        )
    )
  end

  defp spawn_results(result) do
    result.messages
    |> Enum.filter(&match?(%{role: :tool}, &1))
    |> Enum.flat_map(& &1.tool_results)
  end

  describe "the refusal" do
    test "the first one does not count as a mistake", %{dir: dir} do
      assert {:ok, result} = run(dir, 2, %{max_agents_per_run: 1})

      refute result.finish_reason == :error_consecutive_mistakes

      [_spawned, refused] = spawn_results(result)
      assert refused.is_error == true
      assert refused.content =~ "allowance"
    end

    # With orchestrate's `max_iterations: :infinity`, the mistake counter is
    # the only turn-based guard left once every slot is spent. Asking again
    # after being told no is what it is for.
    test "asking again after being refused does count", %{dir: dir} do
      assert {:ok, result} = run(dir, 3, %{max_agents_per_run: 1})

      assert result.finish_reason == :error_consecutive_mistakes
    end

    test "tells a delegate-only caller to finish, never to do the work itself",
         %{dir: dir} do
      assert {:ok, result} = run(dir, 2, %{max_agents_per_run: 1, delegate_only: true})

      [_spawned, refused] = spawn_results(result)

      assert refused.content =~ "finish now"
      assert refused.content =~ "unverified"
      refute refused.content =~ "yourself"
    end

    test "tells a caller with its own tools to do the work itself", %{dir: dir} do
      assert {:ok, result} = run(dir, 2, %{max_agents_per_run: 1})

      [_spawned, refused] = spawn_results(result)

      assert refused.content =~ "Do the remaining work yourself"
    end
  end

  # `delegate_only` describes the CALLER, so it must not ride down to a worker
  # that holds read, write and bash tools. (`strict_spawn` cannot carry this:
  # workers inherit it.)
  test "a worker does not inherit the caller's delegate-only wording", %{dir: dir} do
    # Turn 1: delegate (refused, the parent took the only slot).
    # Turn 2: report the refusal verbatim, so the parent can see it.
    worker_that_delegates = fn req ->
      last_result =
        req.messages
        |> Enum.flat_map(fn
          %{role: :tool, tool_results: trs} when is_list(trs) -> trs
          _ -> []
        end)
        |> List.last()

      case last_result do
        nil ->
          %Response{
            text: "delegating my own step",
            tool_calls: [
              %ToolCall{id: "w1", name: "spawn_agent", arguments: %{"prompt" => "sub-step"}}
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }

        result ->
          %Response{text: to_string(result.content), finish_reason: :stop, provider: :mock}
      end
    end

    assert {:ok, result} =
             Loop.run("coordinate the work",
               provider: :mock,
               mock: [responder: parent_responder(1)],
               tools: [ExAthena.Tools.SpawnAgent],
               cwd: dir,
               memory: false,
               max_iterations: 20,
               assigns: %{
                 max_agents_per_run: 1,
                 delegate_only: true,
                 spawn_agent_opts: [
                   provider: :mock,
                   mock: [responder: worker_that_delegates],
                   memory: false
                 ]
               }
             )

    [spawned] = spawn_results(result)

    assert spawned.content =~ "Do the remaining work yourself"
  end

  describe "the allowance in every result" do
    test "each spawn result names the worker and what is left", %{dir: dir} do
      assert {:ok, result} = run(dir, 2, %{max_agents_per_run: 3})

      [first, second] = spawn_results(result)

      assert first.content =~ "worker 1 of 3 this run; 2 left"
      assert second.content =~ "worker 2 of 3 this run; 1 left"
    end

    test "says plainly when one slot is left", %{dir: dir} do
      assert {:ok, result} = run(dir, 1, %{max_agents_per_run: 2})

      [first] = spawn_results(result)

      assert first.content =~ "this is your LAST worker"
    end

    test "the refusal names the spent allowance too", %{dir: dir} do
      assert {:ok, result} = run(dir, 2, %{max_agents_per_run: 1})

      [_spawned, refused] = spawn_results(result)

      assert refused.content =~ "worker 1 of 1 this run; none left"
    end

    # A bare run with no counter installed is unbounded, as it was before the
    # rail existed — there is no count to report.
    test "a run with no allowance says nothing about one", %{dir: dir} do
      assert {:ok, result} =
               Loop.run("coordinate the work",
                 provider: :mock,
                 mock: [responder: parent_responder(1)],
                 tools: [ExAthena.Tools.SpawnAgent],
                 cwd: dir,
                 memory: false,
                 max_iterations: 20,
                 assigns: %{
                   agent_quota: nil,
                   spawn_agent_opts: [
                     provider: :mock,
                     mock: [responder: worker()],
                     tools: [ExAthena.Tools.TodoWrite],
                     memory: false
                   ]
                 }
               )

      [first] = spawn_results(result)
      refute first.content =~ "this run;"
    end
  end
end
