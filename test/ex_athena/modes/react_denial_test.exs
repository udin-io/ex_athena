defmodule ExAthena.Modes.ReactDenialTest do
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Permissions.Denial

  defmodule FakeEchoTool do
    @behaviour ExAthena.Tool
    def name, do: "echo"
    def description, do: "echo"
    def parallel_safe?, do: true
    def schema, do: %{type: "object", properties: %{}, required: []}
    def execute(_args, _ctx), do: {:ok, "tool-output"}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "react_denial_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp two_turn_responder do
    counter = :counters.new(1, [:atomics])

    fn _req ->
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
  end

  test ":ToolDenied hook receives Denial struct when tool is disallowed", %{dir: dir} do
    test_pid = self()

    assert {:ok, %Result{}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: two_turn_responder()],
               cwd: dir,
               tools: [FakeEchoTool],
               disallowed_tools: ["echo"],
               hooks: %{
                 ToolDenied: [
                   fn payload, _id ->
                     send(test_pid, {:denied, payload})
                     :ok
                   end
                 ]
               }
             )

    assert_receive {:denied, payload}
    assert %Denial{code: :user_denied} = payload.denial
    assert payload.denial.metadata.requested_tool == "echo"
    assert payload.tool_name == "echo"
  end

  test "tool result content uses denial.reason string, not inspect", %{dir: dir} do
    assert {:ok, %Result{} = result} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: two_turn_responder()],
               cwd: dir,
               tools: [FakeEchoTool],
               disallowed_tools: ["echo"]
             )

    [tool_msg] = Enum.filter(result.messages, &(&1.role == :tool))
    [tr] = tool_msg.tool_results
    refute tr.content =~ "%ExAthena.Permissions.Denial"
    refute tr.content =~ "{:disallowed"
    assert is_binary(tr.content)
    assert String.length(tr.content) > 0
  end

  test ":PermissionDenied still fires alongside :ToolDenied", %{dir: dir} do
    test_pid = self()

    assert {:ok, %Result{}} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: two_turn_responder()],
               cwd: dir,
               tools: [FakeEchoTool],
               disallowed_tools: ["echo"],
               hooks: %{
                 PermissionDenied: [
                   fn payload, _id ->
                     send(test_pid, {:permission_denied, payload})
                     :ok
                   end
                 ],
                 ToolDenied: [
                   fn payload, _id ->
                     send(test_pid, {:tool_denied, payload})
                     :ok
                   end
                 ]
               }
             )

    assert_receive {:permission_denied, _}
    assert_receive {:tool_denied, _}
  end
end
