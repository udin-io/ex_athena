defmodule ExAthena.MessagesTest do
  use ExUnit.Case, async: true

  alias ExAthena.Messages
  alias ExAthena.Messages.{Message, ToolCall, ToolResult}

  describe "constructors" do
    test "user/1" do
      assert %Message{role: :user, content: "hi"} = Messages.user("hi")
    end

    test "assistant/2 with and without tool calls" do
      assert %Message{role: :assistant, content: "ok", tool_calls: nil} =
               Messages.assistant("ok")

      assert %Message{tool_calls: [%ToolCall{name: "t"}]} =
               Messages.assistant("need tool", [
                 %ToolCall{id: "1", name: "t", arguments: %{}}
               ])
    end

    test "tool_result/3" do
      assert %Message{
               role: :tool,
               tool_results: [%ToolResult{tool_call_id: "c1", content: "done"}]
             } = Messages.tool_result("c1", "done")
    end
  end

  describe "from_map/1" do
    test "accepts a Message struct unchanged" do
      msg = Messages.user("hi")
      assert ^msg = Messages.from_map(msg)
    end

    test "accepts string-keyed map" do
      assert %Message{role: :user, content: "hi"} =
               Messages.from_map(%{"role" => "user", "content" => "hi"})
    end

    test "accepts atom-keyed map" do
      assert %Message{role: :assistant, content: "ok"} =
               Messages.from_map(%{role: :assistant, content: "ok"})
    end

    test "normalises nested tool_calls" do
      raw = %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [%{"id" => "1", "name" => "t", "arguments" => %{"x" => 1}}]
      }

      assert %Message{tool_calls: [%ToolCall{id: "1", name: "t", arguments: %{"x" => 1}}]} =
               Messages.from_map(raw)
    end

    test "raises when role is missing" do
      assert_raise ArgumentError, fn -> Messages.from_map(%{"content" => "hi"}) end
    end
  end
end
