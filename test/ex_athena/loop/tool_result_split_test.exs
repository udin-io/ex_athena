defmodule ExAthena.Loop.ToolResultSplitTest do
  @moduledoc """
  PR3b — verifies that tools returning the `{:ok, llm, ui}` 3-tuple
  produce a `ToolResult` with `ui_payload` set, and that the loop
  emits a `:tool_ui` event for each such result.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.{Message, ToolCall, ToolResult}

  setup do
    dir = Path.join(System.tmp_dir!(), "tools_ui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp tool_then_stop(tool_name, args) do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "calling",
            tool_calls: [%ToolCall{id: "c1", name: tool_name, arguments: args}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end
  end

  test "Read populates a :file UI payload and the loop emits :tool_ui", %{dir: dir} do
    File.write!(Path.join(dir, "hello.txt"), "hi")

    ref = make_ref()
    parent = self()

    on_event = fn
      {:tool_ui, _} = ev -> send(parent, {ref, ev})
      _ -> :ok
    end

    {:ok, result} =
      Loop.run("hi",
        provider: :mock,
        mock: [responder: tool_then_stop("read", %{"path" => "hello.txt"})],
        tools: [ExAthena.Tools.Read],
        cwd: dir,
        memory: false,
        on_event: on_event
      )

    # ToolResult carries the structured payload.
    [tool_msg] = Enum.filter(result.messages, &match?(%Message{role: :tool}, &1))

    assert [%ToolResult{ui_payload: %{kind: :file, payload: payload}}] =
             tool_msg.tool_results

    assert payload.path =~ "hello.txt"
    assert payload.content == "hi"

    # Loop emitted the matching :tool_ui event.
    assert_receive {^ref, {:tool_ui, %{tool_call_id: "c1", kind: :file, payload: ^payload}}}
  end

  test "Bash populates a :process UI payload", %{dir: dir} do
    ref = make_ref()
    parent = self()

    on_event = fn
      {:tool_ui, _} = ev -> send(parent, {ref, ev})
      _ -> :ok
    end

    {:ok, _result} =
      Loop.run("hi",
        provider: :mock,
        mock: [responder: tool_then_stop("bash", %{"command" => "echo hi"})],
        tools: [ExAthena.Tools.Bash],
        cwd: dir,
        memory: false,
        on_event: on_event
      )

    assert_receive {^ref,
                    {:tool_ui, %{tool_call_id: "c1", kind: :process, payload: %{exit_code: 0}}}}
  end

  test "tools that return plain {:ok, text} produce no :tool_ui event", %{dir: dir} do
    # TodoWrite returns a plain string — no UI payload.
    ref = make_ref()
    parent = self()

    on_event = fn
      {:tool_ui, _} = ev -> send(parent, {ref, ev})
      _ -> :ok
    end

    {:ok, _result} =
      Loop.run("hi",
        provider: :mock,
        mock: [
          responder:
            tool_then_stop("todo_write", %{
              "todos" => [%{"content" => "do thing", "status" => "pending"}]
            })
        ],
        tools: [ExAthena.Tools.TodoWrite],
        cwd: dir,
        memory: false,
        on_event: on_event
      )

    refute_received {^ref, {:tool_ui, _}}
  end
end
