defmodule ExAthena.Loop.SteerEventsTest.EmptyGrep do
  @moduledoc false
  @behaviour ExAthena.Tool
  def name, do: "grep"
  def description, do: "test grep that finds nothing"

  def schema,
    do: %{type: "object", properties: %{pattern: %{type: "string"}}, required: ["pattern"]}

  def parallel_safe?, do: true
  def execute(_args, _ctx), do: {:ok, "No matches found."}
end

defmodule ExAthena.Loop.SteerEventsTest do
  @moduledoc """
  Issue 351. The notes ExAthena adds to a model call, and the finish checks
  that send the chat back to work, were never recorded anywhere: they ride the
  request and vanish. Each one now goes out as a `{:steer, _}` event with the
  text the model got, and each provider call as a `{:model_call, _}` event
  with how long it took, so a trace can show what the model was told and when.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Loop.SteerEventsTest.EmptyGrep
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "steer_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "f.txt"), "contents")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp scripted(responses) do
    counter = :counters.new(1, [:atomics])

    fn _request ->
      :counters.add(counter, 1, 1)
      Enum.at(responses, :counters.get(counter, 1) - 1) || List.last(responses)
    end
  end

  defp call(id, name, args), do: %ToolCall{id: id, name: name, arguments: args}

  defp tool_turn(calls, text \\ ""),
    do: %Response{text: text, tool_calls: calls, finish_reason: :tool_calls, provider: :mock}

  defp says(text), do: %Response{text: text, finish_reason: :stop, provider: :mock}

  defp run(script, dir, opts) do
    test_pid = self()

    Loop.run(
      Keyword.get(opts, :prompt, "find the thing"),
      Keyword.merge(
        [
          provider: :mock,
          mock: [responder: scripted(script)],
          cwd: dir,
          memory: false,
          max_iterations: 12,
          on_event: fn event -> send(test_pid, {:event, event}) end
        ],
        Keyword.delete(opts, :prompt)
      )
    )
  end

  defp events do
    receive do
      {:event, event} -> [event | events()]
    after
      0 -> []
    end
  end

  defp steers(events, kind), do: for({:steer, %{kind: ^kind} = s} <- events, do: s)

  test "a research note the model got is recorded once, with its text", %{dir: dir} do
    script = [
      tool_turn([call("c1", "grep", %{"pattern" => "zzz"})], "CONCLUSION: there is no blog dir."),
      says("done\nCONCLUSION: done."),
      says("done\nCONCLUSION: done.")
    ]

    assert {:ok, _} = run(script, dir, tools: [EmptyGrep, ExAthena.Tools.WebSearch])

    assert [%{text: text}] = steers(events(), :research)
    assert text =~ "[runtime] Local context looks insufficient"
  end

  test "a finish check that fired is recorded once, naming the check", %{dir: dir} do
    script = [
      tool_turn([
        call("w1", "write", %{"path" => "lib/a.ex", "content" => "defmodule A do\nend\n"})
      ]),
      tool_turn([call("b1", "bash", %{"command" => "mkdir -p out"})]),
      says("Done.")
    ]

    assert {:ok, _} =
             run(script, dir,
               prompt: "add a doctor filter",
               tools: [ExAthena.Tools.Write, ExAthena.Tools.Bash]
             )

    checks = steers(events(), :finish_check)
    assert [%{text: text}] = Enum.filter(checks, &(&1.check == "test"))
    assert String.starts_with?(text, "[chat runtime: test check]")
  end

  test "a chat that stops with open steps records the open-steps note", %{dir: dir} do
    todos = [%{"content" => "write the report", "status" => "pending"}]

    script = [
      tool_turn([call("t1", "todo_write", %{"todos" => todos})]),
      says("Next I will write the report."),
      says("Done.")
    ]

    assert {:ok, _} = run(script, dir, tools: [ExAthena.Tools.TodoWrite])

    assert [%{text: text}] = steers(events(), :open_steps)
    assert text =~ "write the report"
  end

  test "the wrap-up note near the end of a budget is recorded with its text", %{dir: dir} do
    read = fn n -> tool_turn([call("r#{n}", "read", %{"path" => "f.txt", "offset" => n})]) end

    assert {:ok, _} =
             run(Enum.map(1..4, read) ++ [says("done")], dir,
               tools: [ExAthena.Tools.Read],
               max_iterations: 4,
               max_unproductive_iterations: 10_000
             )

    assert [%{text: text} | _] = steers(events(), :wrap_up)
    assert is_binary(text) and text != ""
  end

  test "the handback turn records the note that replaced the tools", %{dir: dir} do
    now = System.monotonic_time(:millisecond)

    assigns = %{
      agent_deadline_from: now - 900,
      agent_deadline_at: now + 100,
      agent_wait_counters: [ExAthena.Agents.Deadline.new_counter()]
    }

    assert {:ok, _} =
             run([says("Here is my report.")], dir,
               tools: [ExAthena.Tools.Read],
               assigns: assigns
             )

    assert [%{text: text}] = steers(events(), :handback)
    assert String.starts_with?(text, "[runtime] Your time budget is nearly spent")
  end

  test "a repeating ledger records the note that tells the model to change course",
       %{dir: dir} do
    same = "CONCLUSION: the handler is still unclear."
    grep = fn id -> tool_turn([call(id, "grep", %{"pattern" => "zzz"})], same) end

    assert {:ok, _} = run([grep.("c1"), grep.("c2"), says("done")], dir, tools: [EmptyGrep])

    assert [%{text: text} | _] = steers(events(), :ledger_repeat)
    assert text =~ "You are repeating yourself"
  end

  test "a note on a request a hook stopped is not recorded, since the model never got it",
       %{dir: dir} do
    now = System.monotonic_time(:millisecond)

    assigns = %{
      agent_deadline_from: now - 900,
      agent_deadline_at: now + 100,
      agent_wait_counters: [ExAthena.Agents.Deadline.new_counter()]
    }

    assert {:ok, %{finish_reason: :error_halted}} =
             run([says("Here is my report.")], dir,
               tools: [ExAthena.Tools.Read],
               assigns: assigns,
               hooks: %{ChatParams: [fn _payload, _ -> {:halt, :stopped_by_hook} end]}
             )

    assert steers(events(), :handback) == []
  end

  test "every model call is recorded with how long it took", %{dir: dir} do
    script = [tool_turn([call("r1", "read", %{"path" => "f.txt"})]), says("done")]

    assert {:ok, _} = run(script, dir, tools: [ExAthena.Tools.Read])

    calls = for {:model_call, data} <- events(), data.purpose == :turn, do: data
    assert length(calls) == 2
    assert Enum.all?(calls, &(is_integer(&1.duration_ms) and &1.duration_ms >= 0))
  end
end
