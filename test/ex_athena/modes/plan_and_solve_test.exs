defmodule ExAthena.Modes.PlanAndSolveTest do
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "pas_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "first iteration is planning-only (no tools, plain text)", %{dir: dir} do
    counter = :counters.new(1, [:atomics])

    responder = fn request ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          # Planning turn. Assert the system prompt carries the planning
          # addendum, and tools have been cleared.
          sp = request.system_prompt || ""
          assert sp =~ "Planning phase"
          refute request.tools
          %Response{text: "plan: do the thing", finish_reason: :stop, provider: :mock}

        _ ->
          # Execution turn.
          %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end

    assert {:ok, %Result{finish_reason: :stop} = r} =
             Loop.run("analyse the repo",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [],
               mode: :plan_and_solve,
               max_iterations: 5
             )

    # Messages should contain both the plan turn and the execution turn.
    contents =
      r.messages
      |> Enum.filter(&match?(%{role: :assistant, content: c} when is_binary(c), &1))
      |> Enum.map(& &1.content)

    assert "plan: do the thing" in contents
    assert "done" in contents
  end

  test "execution phase behaves like ReAct (can call tools)", %{dir: dir} do
    File.write!(Path.join(dir, "x.txt"), "x-contents")

    counter = :counters.new(1, [:atomics])

    responder = fn _req ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{text: "plan", finish_reason: :stop, provider: :mock}

        2 ->
          %Response{
            text: "",
            tool_calls: [%ToolCall{id: "t", name: "read", arguments: %{"path" => "x.txt"}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end

    assert {:ok, %Result{finish_reason: :stop, tool_calls_made: 1}} =
             Loop.run("do it",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [ExAthena.Tools.Read],
               mode: :plan_and_solve,
               max_iterations: 10
             )
  end
end
