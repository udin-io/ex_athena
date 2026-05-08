defmodule ExAthena.Modes.ReactPostHookTest do
  @moduledoc """
  Verifies that `after_post_hook/3` in ReAct mode correctly applies the
  `{:augment, text}` return from PostToolUse hooks by appending the extra
  text to the tool result content.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall

  # Minimal tool that returns a fixed string.
  defmodule FakeEchoTool do
    @behaviour ExAthena.Tool
    def name, do: "echo"
    def description, do: "echo"
    def parallel_safe?, do: true
    def schema, do: %{type: "object", properties: %{}, required: []}
    def execute(_args, _ctx), do: {:ok, "tool-output"}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "react_hook_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "PostToolUse {:augment, text} appends to tool result content", %{dir: dir} do
    augment_hook = fn _payload, _id -> {:augment, "[lsp] error: bad syntax"} end

    # Provider: turn 1 calls the echo tool; turn 2 returns plain text (stop).
    counter = :counters.new(1, [:atomics])

    responder = fn _request ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "",
            tool_calls: [%ToolCall{id: "t1", name: "echo", arguments: %{}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end

    assert {:ok, %Result{} = result} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [FakeEchoTool],
               hooks: %{
                 PostToolUse: [
                   %{matcher: "^echo$", hooks: [augment_hook]}
                 ]
               }
             )

    tool_msgs = Enum.filter(result.messages, &(&1.role == :tool))
    assert length(tool_msgs) == 1
    [tool_msg] = tool_msgs
    [tr] = tool_msg.tool_results
    assert tr.content =~ "tool-output"
    assert tr.content =~ "[lsp] error: bad syntax"
  end

  test "PostToolUse :ok hook leaves tool result content unchanged", %{dir: dir} do
    ok_hook = fn _payload, _id -> :ok end

    counter = :counters.new(1, [:atomics])

    responder = fn _request ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "",
            tool_calls: [%ToolCall{id: "t1", name: "echo", arguments: %{}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end

    assert {:ok, %Result{} = result} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [FakeEchoTool],
               hooks: %{PostToolUse: [%{hooks: [ok_hook]}]}
             )

    [tool_msg] = Enum.filter(result.messages, &(&1.role == :tool))
    [tr] = tool_msg.tool_results
    assert tr.content == "tool-output"
  end

  test "PostToolUse augment payload includes arguments and cwd", %{dir: dir} do
    test_pid = self()

    capture_hook = fn payload, _id ->
      send(test_pid, {:payload, payload})
      :ok
    end

    counter = :counters.new(1, [:atomics])

    responder = fn _request ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "",
            tool_calls: [
              %ToolCall{id: "t1", name: "echo", arguments: %{"key" => "val"}}
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end

    Loop.run("go",
      provider: :mock,
      mock: [responder: responder],
      cwd: dir,
      tools: [FakeEchoTool],
      hooks: %{PostToolUse: [%{hooks: [capture_hook]}]}
    )

    assert_receive {:payload, payload}
    assert payload.arguments == %{"key" => "val"}
    assert payload.cwd == dir
    assert payload.tool_name == "echo"
  end
end
