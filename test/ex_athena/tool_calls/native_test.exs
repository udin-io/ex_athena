defmodule ExAthena.ToolCalls.NativeTest do
  use ExUnit.Case, async: true

  alias ExAthena.Messages.ToolCall
  alias ExAthena.ToolCalls.Native

  describe "parse/1 — ReqLLM.StreamChunk shapes" do
    test "parses StreamChunk with string-keyed id in metadata" do
      chunk = %ReqLLM.StreamChunk{
        type: :tool_call,
        name: "glob",
        arguments: %{"pattern" => "**/*.ex"},
        metadata: %{"id" => "call_123"}
      }

      assert {:ok,
              [%ToolCall{name: "glob", id: "call_123", arguments: %{"pattern" => "**/*.ex"}}]} =
               Native.parse([chunk])
    end

    test "parses StreamChunk with atom-keyed id in metadata" do
      chunk = %ReqLLM.StreamChunk{
        type: :tool_call,
        name: "glob",
        arguments: %{"pattern" => "**/*.ex"},
        metadata: %{id: "call_atom_456"}
      }

      assert {:ok, [%ToolCall{name: "glob", id: "call_atom_456"}]} = Native.parse([chunk])
    end

    test "parses StreamChunk without id — auto-generates one" do
      chunk = %ReqLLM.StreamChunk{
        type: :tool_call,
        name: "glob",
        arguments: %{"pattern" => "**/*.ex"},
        metadata: %{}
      }

      assert {:ok, [%ToolCall{name: "glob", id: id, arguments: %{"pattern" => "**/*.ex"}}]} =
               Native.parse([chunk])

      assert is_binary(id) and byte_size(id) > 0
    end

    test "returns error for StreamChunk with nil name" do
      chunk = %ReqLLM.StreamChunk{
        type: :tool_call,
        name: nil,
        arguments: %{},
        metadata: %{}
      }

      assert {:error, :missing_tool_name} = Native.parse([chunk])
    end
  end
end
