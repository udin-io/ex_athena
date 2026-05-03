defmodule ExAthena.ToolCalls.RawJsonTest do
  use ExUnit.Case, async: true

  alias ExAthena.Messages.ToolCall
  alias ExAthena.ToolCalls.RawJson

  describe "parse/1" do
    test "bare JSON tool call" do
      assert {:ok, [%ToolCall{name: "foo", arguments: %{}}]} =
               RawJson.parse(~s({"name":"foo","arguments":{}}))
    end

    test "markdown-fenced JSON tool call" do
      text = """
      ```json
      {"name":"read_file","arguments":{"path":"/tmp/foo"}}
      ```
      """

      assert {:ok, [%ToolCall{name: "read_file", arguments: %{"path" => "/tmp/foo"}}]} =
               RawJson.parse(text)
    end

    test "nested arguments are fully decoded" do
      json = ~s({"name":"x","arguments":{"path":"/tmp","opts":{"recursive":true}}})

      assert {:ok,
              [
                %ToolCall{
                  name: "x",
                  arguments: %{"path" => "/tmp", "opts" => %{"recursive" => true}}
                }
              ]} =
               RawJson.parse(json)
    end

    test "prose preamble before JSON is handled" do
      text = ~s(I will call the tool now.\n{"name":"ping","arguments":{}})

      assert {:ok, [%ToolCall{name: "ping"}]} = RawJson.parse(text)
    end

    test "text with no JSON returns empty list" do
      assert {:ok, []} = RawJson.parse("just some plain text with no JSON")
    end

    test "unclosed brace returns empty list without raising" do
      assert {:ok, []} = RawJson.parse(~s({"name":"foo","arguments":{))
    end

    test "non-tool-call JSON missing name returns empty list" do
      assert {:ok, []} = RawJson.parse(~s({"foo":"bar"}))
    end

    test "non-tool-call JSON missing arguments returns empty list" do
      assert {:ok, []} = RawJson.parse(~s({"name":"ping"}))
    end

    test "id field passed through when present" do
      assert {:ok, [%ToolCall{id: "my-id"}]} =
               RawJson.parse(~s({"id":"my-id","name":"t","arguments":{}}))
    end

    test "auto-generates a call_* id when id is absent" do
      assert {:ok, [%ToolCall{id: "call_" <> _}]} =
               RawJson.parse(~s({"name":"t","arguments":{}}))
    end

    test "nil arguments treated as empty map" do
      assert {:ok, [%ToolCall{name: "t", arguments: %{}}]} =
               RawJson.parse(~s({"name":"t","arguments":null}))
    end

    test "string-encoded arguments are decoded" do
      json = ~s({"name":"t","arguments":"{\\"x\\":1}"})

      assert {:ok, [%ToolCall{name: "t", arguments: %{"x" => 1}}]} = RawJson.parse(json)
    end

    test "markdown fence without json label" do
      text = "```\n{\"name\":\"ping\",\"arguments\":{}}\n```"
      assert {:ok, [%ToolCall{name: "ping"}]} = RawJson.parse(text)
    end

    test "empty string returns empty list" do
      assert {:ok, []} = RawJson.parse("")
    end

    test "multiple JSON objects extracts all valid tool calls" do
      text = """
      {"name":"first","arguments":{"a":1}}
      {"name":"second","arguments":{"b":2}}
      """

      assert {:ok, [%ToolCall{name: "first"}, %ToolCall{name: "second"}]} = RawJson.parse(text)
    end
  end
end
