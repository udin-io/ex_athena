defmodule ExAthena.StructuredOutputTest.NoStructuredOutput do
  @behaviour ExAthena.Provider
  def capabilities, do: %{structured_output: false}
  def query(_req, _opts), do: {:ok, %ExAthena.Response{text: "{}", tool_calls: [], provider: :test}}
  def stream(_req, _cb, _opts), do: {:ok, %ExAthena.Response{text: ""}}
end

defmodule ExAthena.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias ExAthena.StructuredOutput

  @schema %{
    "type" => "object",
    "properties" => %{"action" => %{"type" => "string"}},
    "required" => ["action"]
  }

  describe "request/3 happy path" do
    test "returns decoded map when provider returns valid JSON text" do
      assert {:ok, %{"action" => "exit", "reason" => "done"}} =
               StructuredOutput.request(
                 "Pick action",
                 @schema,
                 provider: :mock,
                 mock: [text: ~s({"action":"exit","reason":"done"})]
               )
    end
  end

  describe "request/3 capability checks" do
    test "returns {:error, :no_structured_output} when provider caps lack structured_output" do
      assert {:error, :no_structured_output} =
               StructuredOutput.request(
                 "prompt",
                 @schema,
                 provider: ExAthena.StructuredOutputTest.NoStructuredOutput
               )
    end

    test "per-request capabilities override disables structured_output" do
      assert {:error, :no_structured_output} =
               StructuredOutput.request(
                 "prompt",
                 @schema,
                 provider: :mock,
                 capabilities: %{structured_output: false},
                 mock: [text: ~s({"action":"go"})]
               )
    end
  end

  describe "request/3 JSON decode failures" do
    test "returns {:error, :invalid_json} when provider returns non-JSON text" do
      assert {:error, :invalid_json} =
               StructuredOutput.request(
                 "prompt",
                 @schema,
                 provider: :mock,
                 mock: [text: "I cannot comply."]
               )
    end

    test "returns {:error, :invalid_json} when provider returns a JSON array instead of object" do
      assert {:error, :invalid_json} =
               StructuredOutput.request(
                 "prompt",
                 @schema,
                 provider: :mock,
                 mock: [text: "[1,2,3]"]
               )
    end

    test "returns {:error, :invalid_json} when provider returns nil text" do
      responder = fn _req ->
        %ExAthena.Response{text: nil, tool_calls: [], provider: :mock}
      end

      assert {:error, :invalid_json} =
               StructuredOutput.request(
                 "prompt",
                 @schema,
                 provider: :mock,
                 mock: [responder: responder]
               )
    end
  end

  describe "request/3 forwards response_format into the request" do
    test "schema map is encoded as json_schema response_format in the request" do
      test_pid = self()

      responder = fn req ->
        send(test_pid, {:request_seen, req})
        %ExAthena.Response{text: ~s({"action":"ok"}), tool_calls: [], provider: :mock}
      end

      {:ok, _} =
        StructuredOutput.request(
          "prompt",
          @schema,
          provider: :mock,
          mock: [responder: responder]
        )

      assert_received {:request_seen, req}

      assert %{type: "json_schema", json_schema: %{name: "response", strict: true}} =
               req.response_format
    end

    test ":json shorthand passes through as :json atom" do
      test_pid = self()

      responder = fn req ->
        send(test_pid, {:request_seen, req})
        %ExAthena.Response{text: ~s({"ok":true}), tool_calls: [], provider: :mock}
      end

      {:ok, _} =
        StructuredOutput.request("prompt", :json, provider: :mock, mock: [responder: responder])

      assert_received {:request_seen, req}
      assert req.response_format == :json
    end
  end

  describe "request/3 propagates provider errors" do
    test "passes through {:error, reason} from the provider unchanged" do
      assert {:error, :boom} =
               StructuredOutput.request(
                 "prompt",
                 @schema,
                 provider: :mock,
                 mock: [error: :boom]
               )
    end
  end
end
