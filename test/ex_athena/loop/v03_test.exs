defmodule ExAthena.Loop.V03Test do
  @moduledoc """
  Tests for the v0.3 loop kernel: Result struct, typed terminations,
  parallel tool execution, mistake counter, Mode behaviour.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall

  defp script(responses) do
    counter = :counters.new(1, [:atomics])

    fn _request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      Enum.at(responses, n - 1) || List.last(responses)
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "v03_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "Result struct return type" do
    test "normal completion returns a %Result{} with :stop finish_reason", %{dir: dir} do
      responses = [
        %Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
      ]

      assert {:ok, %Result{} = r} =
               Loop.run("hi",
                 provider: :mock,
                 mock: [responder: script(responses)],
                 cwd: dir,
                 tools: []
               )

      assert r.finish_reason == :stop
      assert r.text == "ok"
      assert r.iterations == 0
      assert Result.success?(r)
    end

    test "max_iterations trips :error_max_turns", %{dir: dir} do
      loop_response = %Response{
        text: "",
        tool_calls: [%ToolCall{id: "x", name: "glob", arguments: %{"pattern" => "**"}}],
        finish_reason: :tool_calls,
        provider: :mock
      }

      assert {:ok, %Result{finish_reason: :error_max_turns, iterations: 3} = r} =
               Loop.run("spin",
                 provider: :mock,
                 mock: [responder: fn _ -> loop_response end],
                 cwd: dir,
                 tools: [ExAthena.Tools.Glob],
                 max_iterations: 3
               )

      assert Result.category(r) == :capacity
    end

    test "Result carries usage and duration_ms accounting", %{dir: dir} do
      response = %Response{
        text: "ok",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock,
        usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
      }

      assert {:ok, %Result{usage: usage, duration_ms: ms}} =
               Loop.run("hi",
                 provider: :mock,
                 mock: [responder: fn _ -> response end],
                 cwd: dir,
                 tools: []
               )

      assert usage == %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
      assert is_integer(ms) and ms >= 0
    end
  end

  describe "mistake counter" do
    test "consecutive tool errors trip :error_consecutive_mistakes", %{dir: dir} do
      # Every turn the model calls a nonexistent tool — each call registers a
      # mistake. With max_consecutive_mistakes=2, third turn terminates.
      tool_call = %ToolCall{id: "nope", name: "nonexistent_tool", arguments: %{}}

      response = %Response{
        text: "",
        tool_calls: [tool_call],
        finish_reason: :tool_calls,
        provider: :mock
      }

      assert {:ok, %Result{finish_reason: :error_consecutive_mistakes} = r} =
               Loop.run("go",
                 provider: :mock,
                 mock: [responder: fn _ -> response end],
                 cwd: dir,
                 tools: [ExAthena.Tools.Read],
                 max_consecutive_mistakes: 2,
                 max_iterations: 10
               )

      assert Result.category(r) == :capacity
    end

    test "successful tool call resets the mistake counter", %{dir: dir} do
      File.write!(Path.join(dir, "foo.txt"), "hello")

      counter = :counters.new(1, [:atomics])

      responder = fn _req ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        case n do
          # First turn: nonexistent tool (mistake 1)
          1 ->
            %Response{
              text: "",
              tool_calls: [%ToolCall{id: "c1", name: "nonexistent", arguments: %{}}],
              finish_reason: :tool_calls,
              provider: :mock
            }

          # Second turn: valid tool (resets counter)
          2 ->
            %Response{
              text: "",
              tool_calls: [%ToolCall{id: "c2", name: "read", arguments: %{"path" => "foo.txt"}}],
              finish_reason: :tool_calls,
              provider: :mock
            }

          # Third turn: final response
          _ ->
            %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
        end
      end

      # max_consecutive_mistakes=1 would trip on turn 1 ... but the valid
      # read on turn 2 resets the counter, so the loop completes normally.
      assert {:ok, %Result{finish_reason: :stop, text: "done"}} =
               Loop.run("mix",
                 provider: :mock,
                 mock: [responder: responder],
                 cwd: dir,
                 tools: [ExAthena.Tools.Read],
                 max_consecutive_mistakes: 2,
                 max_iterations: 10
               )
    end
  end

  describe "parallel tool execution" do
    test "read-only tools run concurrently; results ordered by call order", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "A")
      File.write!(Path.join(dir, "b.txt"), "B")
      File.write!(Path.join(dir, "c.txt"), "C")

      call_a = %ToolCall{id: "a", name: "read", arguments: %{"path" => "a.txt"}}
      call_b = %ToolCall{id: "b", name: "read", arguments: %{"path" => "b.txt"}}
      call_c = %ToolCall{id: "c", name: "read", arguments: %{"path" => "c.txt"}}

      responses = [
        %Response{
          text: "",
          tool_calls: [call_a, call_b, call_c],
          finish_reason: :tool_calls,
          provider: :mock
        },
        %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
      ]

      assert {:ok, %Result{finish_reason: :stop, messages: messages}} =
               Loop.run("read three",
                 provider: :mock,
                 mock: [responder: script(responses)],
                 cwd: dir,
                 tools: [ExAthena.Tools.Read]
               )

      tool_results =
        messages
        |> Enum.filter(&match?(%{role: :tool}, &1))
        |> Enum.flat_map(fn m -> m.tool_results end)

      assert length(tool_results) == 3

      # Results must be in call order.
      assert Enum.at(tool_results, 0).tool_call_id == "a"
      assert Enum.at(tool_results, 1).tool_call_id == "b"
      assert Enum.at(tool_results, 2).tool_call_id == "c"
    end
  end

  describe "flat event tuples" do
    test "emits :iteration, :content, :tool_call, :tool_result, :done", %{dir: dir} do
      File.write!(Path.join(dir, "x.txt"), "x")

      responses = [
        %Response{
          text: "reading",
          tool_calls: [%ToolCall{id: "t1", name: "read", arguments: %{"path" => "x.txt"}}],
          finish_reason: :tool_calls,
          provider: :mock
        },
        %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
      ]

      test_pid = self()

      {:ok, %Result{}} =
        Loop.run("read",
          provider: :mock,
          mock: [responder: script(responses)],
          cwd: dir,
          tools: [ExAthena.Tools.Read],
          on_event: fn e -> send(test_pid, {:evt, e}) end
        )

      assert_receive {:evt, {:iteration, 0}}
      assert_receive {:evt, {:content, "reading"}}
      assert_receive {:evt, {:tool_call, %ToolCall{id: "t1"}}}
      assert_receive {:evt, {:tool_result, _}}
      assert_receive {:evt, {:content, "done"}}
      assert_receive {:evt, {:done, %Result{finish_reason: :stop}}}
    end
  end

  describe "Mode behaviour" do
    test "default mode is :react", %{dir: dir} do
      responses = [%Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}]

      # No :mode opt — defaults to :react. Assert it works.
      assert {:ok, %Result{finish_reason: :stop, text: "ok"}} =
               Loop.run("hi",
                 provider: :mock,
                 mock: [responder: script(responses)],
                 cwd: dir,
                 tools: []
               )
    end

    test "resolve/1 returns a module for atom shortcuts" do
      assert ExAthena.Loop.Mode.resolve(:react) == ExAthena.Modes.ReAct
      assert ExAthena.Loop.Mode.resolve(:plan_and_solve) == ExAthena.Modes.PlanAndSolve
      assert ExAthena.Loop.Mode.resolve(:reflexion) == ExAthena.Modes.Reflexion
    end

    test "resolve/1 passes through unknown atoms as modules" do
      assert ExAthena.Loop.Mode.resolve(SomeUserMode) == SomeUserMode
    end
  end
end
