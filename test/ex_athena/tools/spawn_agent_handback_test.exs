defmodule ExAthena.Tools.SpawnAgentHandbackTest do
  @moduledoc """
  Issue 237. A worker that reaches the handback stage writes its report on a
  tool-free final turn and terminates `:budget_handback`, which is a SUCCESS —
  that is the whole point, because the parent must read the worker's own words
  instead of a digest rebuilt from the Coordinator's observations.

  Routing it as a success creates a second problem. Anything counting
  successful spawns — the orchestrate evidence gates, `any_tool_success?`, the
  Coordinator — would read a worker that ran out of time as one that finished.
  So the runtime prefixes the returned text with a line saying it did not. The
  RUNTIME writes that line, not the worker: the model's own compliance is
  exactly what is not dependable here, which is why the stage exists at all.

  The threshold is set to 0 rather than waiting for a clock, so the stage fires
  on the worker's first turn with its 30 minute budget untouched and the hard
  kill nowhere near.
  """
  use ExUnit.Case, async: false

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "spawn_handback_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "f.txt"), "contents")

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.delete_env(:ex_athena, :loop)
    end)

    {:ok, dir: dir}
  end

  defp handback_now, do: Application.put_env(:ex_athena, :loop, handback_at_percent: 0)

  # Spawns one worker, then reports what it was told.
  defp parent_responder do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1 do
        %Response{
          text: "delegating the console screen",
          tool_calls: [
            %ToolCall{
              id: "c1",
              name: "spawn_agent",
              arguments: %{"prompt" => "build the console screen"}
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

  # Reports when it has no tools, works otherwise.
  defp worker_responder(report) do
    fn request ->
      if request.tools in [nil, []] do
        %Response{text: report, tool_calls: [], finish_reason: :stop, provider: :mock}
      else
        %Response{
          text: "reading the conventions",
          tool_calls: [%ToolCall{id: "w1", name: "read", arguments: %{"path" => "f.txt"}}],
          finish_reason: :tool_calls,
          provider: :mock
        }
      end
    end
  end

  defp run(dir, worker) do
    Loop.run("coordinate the work",
      provider: :mock,
      mock: [responder: parent_responder()],
      tools: [ExAthena.Tools.SpawnAgent],
      cwd: dir,
      memory: false,
      max_iterations: 10,
      max_consecutive_mistakes: 3,
      assigns: %{
        spawn_agent_opts: [
          provider: :mock,
          mock: [responder: worker],
          tools: [ExAthena.Tools.Read],
          memory: false,
          max_iterations: 5
        ]
      }
    )
  end

  defp spawn_result(result) do
    result.messages
    |> Enum.filter(&match?(%{role: :tool}, &1))
    |> Enum.flat_map(& &1.tool_results)
    |> List.first()
  end

  test "the parent receives the worker's own words, not a rebuilt digest", %{dir: dir} do
    handback_now()

    report =
      "PRODUCED: lib/web/console.ex and its three components. " <>
        "UNVERIFIED: never compiled. REMAINS: the LiveView tests."

    assert {:ok, result} = run(dir, worker_responder(report))

    tr = spawn_result(result)
    assert tr.content =~ "PRODUCED: lib/web/console.ex"
    assert tr.content =~ "REMAINS: the LiveView tests"
    refute tr.content =~ "did not finish"
  end

  test "it is not a tool error, so the parent's mistake counter never sees it", %{dir: dir} do
    handback_now()

    assert {:ok, result} = run(dir, worker_responder("PRODUCED: nothing yet."))

    assert spawn_result(result).is_error != true
    assert result.finish_reason == :stop
  end

  # Without this line a partial worker reads as a finished one to everything
  # that counts successful spawns.
  test "the runtime says the worker stopped on its clock rather than finishing", %{dir: dir} do
    handback_now()

    assert {:ok, result} = run(dir, worker_responder("PRODUCED: nothing yet."))

    content = spawn_result(result).content
    assert content =~ "[runtime]"
    assert content =~ ~r/time budget/i
    assert content =~ ~r/not because it finished|did not finish/i
    assert content =~ ~r/re-delegate/i
  end

  # The worker cannot earn its way out of the notice by claiming success, and
  # cannot fake its way into one either: the runtime writes it from the
  # termination, and the model never sees the decision.
  test "a worker claiming it finished still carries the notice", %{dir: dir} do
    handback_now()

    assert {:ok, result} = run(dir, worker_responder("Task complete. Everything works."))

    content = spawn_result(result).content
    assert content =~ "Task complete."
    assert content =~ ~r/time budget/i
  end

  test "a worker that finished on its own gets no notice", %{dir: dir} do
    finisher = fn _req ->
      %Response{
        text: "All four files written and compiled.",
        finish_reason: :stop,
        provider: :mock
      }
    end

    assert {:ok, result} = run(dir, finisher)

    content = spawn_result(result).content
    assert content =~ "All four files written"
    refute content =~ ~r/time budget/i
  end

  # The orchestrator's own budget is out of scope, and this is what keeps it
  # there: a top-level run carries no deadline assigns, so even a threshold of
  # zero cannot reach it.
  test "a threshold of zero does not hand back the orchestrator", %{dir: dir} do
    handback_now()

    assert {:ok, result} = run(dir, worker_responder("PRODUCED: nothing yet."))

    assert result.finish_reason == :stop
    refute result.finish_reason == :budget_handback
  end
end
