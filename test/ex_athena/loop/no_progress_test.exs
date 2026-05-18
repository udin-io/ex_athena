defmodule ExAthena.Loop.NoProgressTest do
  @moduledoc """
  Verifies :max_unproductive_iterations trips :error_no_progress before
  :error_max_turns, and that no_progress_snapshot is populated.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "no_progress_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "halts with :error_no_progress after 3 identical denied calls (before :error_max_turns)",
       %{dir: dir} do
    stuck_response = %Response{
      text: "",
      tool_calls: [
        %ToolCall{id: "c1", name: "bash", arguments: %{"command" => "echo stuck"}}
      ],
      finish_reason: :tool_calls,
      provider: :mock,
      usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
    }

    assert {:ok, %Result{finish_reason: :error_no_progress} = r} =
             Loop.run("do the thing",
               provider: :mock,
               mock: [responder: fn _ -> stuck_response end],
               cwd: dir,
               tools: [ExAthena.Tools.Bash],
               max_iterations: 25,
               max_unproductive_iterations: 3,
               max_consecutive_mistakes: 100,
               disallowed_tools: ["bash"]
             )

    assert Result.category(r) == :capacity
    assert r.iterations < 10
    assert is_list(r.no_progress_snapshot) and length(r.no_progress_snapshot) > 0
  end

  test "does NOT trip when each iteration uses a different tool call", %{dir: dir} do
    counter = :counters.new(1, [])

    responder = fn _ ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      if n >= 2 do
        %Response{
          text: "done",
          tool_calls: [],
          finish_reason: :stop,
          provider: :mock,
          usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
        }
      else
        %Response{
          text: "",
          tool_calls: [
            %ToolCall{id: "c#{n}", name: "glob", arguments: %{"pattern" => "*.#{n}"}}
          ],
          finish_reason: :tool_calls,
          provider: :mock,
          usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
        }
      end
    end

    assert {:ok, %Result{finish_reason: :stop}} =
             Loop.run("search files",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [ExAthena.Tools.Glob],
               max_unproductive_iterations: 3
             )
  end

  test "respects custom max_unproductive_iterations: 1", %{dir: dir} do
    stuck_response = %Response{
      text: "",
      tool_calls: [
        %ToolCall{id: "c1", name: "bash", arguments: %{"command" => "whoami"}}
      ],
      finish_reason: :tool_calls,
      provider: :mock,
      usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
    }

    assert {:ok, %Result{finish_reason: :error_no_progress, iterations: iters}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: fn _ -> stuck_response end],
               cwd: dir,
               tools: [ExAthena.Tools.Bash],
               max_unproductive_iterations: 1,
               max_consecutive_mistakes: 100,
               disallowed_tools: ["bash"]
             )

    assert iters <= 3
  end

  test "no_progress_snapshot is nil when loop ends normally", %{dir: dir} do
    response = %Response{
      text: "done",
      tool_calls: [],
      finish_reason: :stop,
      provider: :mock,
      usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
    }

    assert {:ok, %Result{finish_reason: :stop, no_progress_snapshot: nil}} =
             Loop.run("hi",
               provider: :mock,
               mock: [responder: fn _ -> response end],
               cwd: dir,
               tools: []
             )
  end
end
