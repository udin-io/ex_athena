defmodule ExAthena.Tools.SpawnAgentPromptTest do
  @moduledoc """
  `spawn_agent` must not hard-fail when the model omits `prompt`.

  The orchestration protocol asks for a four-field brief (objective /
  expected_output / tool_guidance / boundaries) and never names `prompt`, so
  models routinely emit a complete, well-formed brief with no `prompt` key.
  Rejecting that was the one wall in a module whose stated design is "every
  missing field gets a runtime default, never a wall" — and small models
  respond to a rejection by repeating the identical call.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "spawn_prompt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Parent: spawn on turn 1, stop on turn 2.
  defp parent_responder(args) do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "delegating",
            tool_calls: [%ToolCall{id: "c1", name: "spawn_agent", arguments: args}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "all done", finish_reason: :stop, provider: :mock}
      end
    end
  end

  # The worker runs its own loop with its own responder (subagents don't
  # inherit the parent's mock) — report its opening task back to the test.
  defp worker_responder do
    parent = self()

    fn req ->
      task =
        req.messages
        |> Enum.filter(&(&1.role == :user))
        |> List.first()
        |> case do
          nil -> nil
          msg -> msg.content
        end

      send(parent, {:worker_task, task})
      %Response{text: "worker report", finish_reason: :stop, provider: :mock}
    end
  end

  defp run(args, dir) do
    Loop.run("do the task",
      provider: :mock,
      mock: [responder: parent_responder(args)],
      tools: [ExAthena.Tools.SpawnAgent],
      cwd: dir,
      memory: false,
      assigns: %{
        spawn_agent_opts: [provider: :mock, mock: [responder: worker_responder()], memory: false]
      },
      max_iterations: 5
    )
  end

  defp spawn_result(result) do
    result.messages
    |> Enum.filter(&match?(%{role: :tool}, &1))
    |> Enum.flat_map(& &1.tool_results)
    |> List.first()
  end

  test "a brief with objective but no prompt delegates instead of failing", %{dir: dir} do
    args = %{
      "agent" => "explore",
      "objective" => "Explore the appointments calendar view and the for_week action",
      "expected_output" => "A report covering routes, templates and queries",
      "tool_guidance" => "Search lib/ and lib/*_web/",
      "boundaries" => "Read-only. Do not modify files.",
      "todo" => "Explore the calendar view"
    }

    assert {:ok, result} = run(args, dir)

    assert_receive {:worker_task, task}
    assert task =~ "Explore the appointments calendar view and the for_week action"

    refute spawn_result(result).is_error
    refute spawn_result(result).content =~ "missing_prompt"
  end

  test "falls back to the todo when prompt and objective are both absent", %{dir: dir} do
    args = %{
      "agent" => "explore",
      "expected_output" => "A short report",
      "todo" => "Check how Employee records are queried"
    }

    assert {:ok, _result} = run(args, dir)

    assert_receive {:worker_task, task}
    assert task =~ "Check how Employee records are queried"
  end

  test "an explicit prompt still wins over the brief fields", %{dir: dir} do
    args = %{
      "prompt" => "THE REAL INSTRUCTION",
      "objective" => "a summarised objective"
    }

    assert {:ok, _result} = run(args, dir)

    assert_receive {:worker_task, task}
    assert task =~ "THE REAL INSTRUCTION"
  end

  # The orchestrator is deliberately blind — it holds no read tools. In the
  # live failure it nonetheless dictated a full LiveView implementation into
  # the brief, and the worker typed it in verbatim, so nobody with eyes on the
  # file ever evaluated it. The dictated code assigned a tuple into a list of
  # maps two lines above the template that did `doctor.id`.
  describe "code dictated by a blind orchestrator" do
    defp code_prompt(lines) do
      body = Enum.map_join(1..lines, "\n", &"  line_#{&1} = :ok")
      "Apply this to lib/a.ex:\n\n```elixir\ndef run do\n#{body}\nend\n```"
    end

    test "a worker told to apply a code block is told to reconcile it first", %{dir: dir} do
      args = %{"prompt" => code_prompt(20), "objective" => "apply the edit"}

      assert {:ok, _} = run(args, dir)

      assert_receive {:worker_task, task}
      assert task =~ "has NOT read"
      assert task =~ ~r/read the (real|actual) file/i
      # It must be actionable: the worker has to say when the code didn't fit.
      assert task =~ ~r/report/i
    end

    test "a brief with only a small snippet is left alone", %{dir: dir} do
      args = %{
        "prompt" => "Rename the function. For reference: `def run do :ok end`",
        "objective" => "rename it"
      }

      assert {:ok, _} = run(args, dir)

      assert_receive {:worker_task, task}
      refute task =~ "has NOT read"
    end

    test "a prose-only brief is left alone", %{dir: dir} do
      args = %{"prompt" => "Add a doctor filter dropdown to the calendar view."}

      assert {:ok, _} = run(args, dir)

      assert_receive {:worker_task, task}
      refute task =~ "has NOT read"
    end
  end

  test "a spawn with nothing to act on is still rejected", %{dir: dir} do
    args = %{"agent" => "explore", "expected_output" => "something"}

    assert {:ok, result} = run(args, dir)

    tool_result = spawn_result(result)
    assert tool_result.is_error
    assert tool_result.content =~ "missing_prompt"
  end
end
