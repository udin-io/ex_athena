defmodule ExAthena.StructuredTest do
  use ExUnit.Case, async: true

  alias ExAthena.{Response, Structured}

  test "extracts JSON when provider is in JSON mode" do
    responder = fn _req ->
      %Response{text: ~s({"name": "Ada", "age": 36}), provider: :mock, finish_reason: :stop}
    end

    schema = %{
      "type" => "object",
      "required" => ["name", "age"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "age" => %{"type" => "integer"}
      }
    }

    assert {:ok, %{"name" => "Ada", "age" => 36}} =
             Structured.extract("tell me about Ada", schema: schema, provider: :mock,
               mock: [responder: responder])
  end

  test "extracts JSON from a fenced block when not in JSON mode" do
    body = """
    Sure, here you go:

    ~~~json
    {"status": "ok", "count": 3}
    ~~~
    """

    responder = fn _req -> %Response{text: body, provider: :mock, finish_reason: :stop} end

    schema = %{
      "type" => "object",
      "required" => ["status", "count"],
      "properties" => %{
        "status" => %{"type" => "string"},
        "count" => %{"type" => "integer"}
      }
    }

    assert {:ok, %{"status" => "ok", "count" => 3}} =
             Structured.extract("hi", schema: schema, provider: :mock,
               mock: [responder: responder])
  end

  test "validates required keys" do
    responder = fn _req -> %Response{text: ~s({"name": "x"}), provider: :mock} end

    schema = %{"type" => "object", "required" => ["name", "age"]}

    # max_retries: 0 short-circuits the repair loop so the raw validation
    # error propagates directly. The default (2) wraps it in
    # :error_max_structured_output_retries after retries exhaust.
    assert {:error, {:error_max_structured_output_retries, {:missing_required_keys, ["age"]}}} =
             Structured.extract("x",
               schema: schema,
               provider: :mock,
               mock: [responder: responder]
             )
  end

  test "validates top-level type" do
    responder = fn _req -> %Response{text: ~s([1,2,3]), provider: :mock} end

    schema = %{"type" => "object"}

    # When a JSON array arrives but the schema expected an object, extraction
    # treats it as 'no valid JSON' (the fence path decodes, validate_basic
    # checks the type).
    result =
      Structured.extract("x", schema: schema, provider: :mock, mock: [responder: responder])

    assert match?({:error, _}, result)
  end

  test "validates property types" do
    responder = fn _req -> %Response{text: ~s({"age": "not a number"}), provider: :mock} end

    schema = %{
      "type" => "object",
      "properties" => %{"age" => %{"type" => "integer"}}
    }

    assert {:error, {:error_max_structured_output_retries, {:property_invalid, "age"}}} =
             Structured.extract("x",
               schema: schema,
               provider: :mock,
               mock: [responder: responder]
             )
  end

  test "validator opt overrides the default validator" do
    responder = fn _req -> %Response{text: ~s({"k": "v"}), provider: :mock} end

    strict = fn _json, _schema -> {:error, :always_fails} end

    assert {:error, {:error_max_structured_output_retries, :always_fails}} =
             Structured.extract("x",
               provider: :mock,
               mock: [responder: responder],
               schema: %{"type" => "object"},
               validator: strict
             )
  end

  describe "repair loop" do
    test "retries once and succeeds when the second response is valid" do
      counter = :counters.new(1, [:atomics])

      # First response: invalid (missing :age). Second: valid.
      responder = fn _req ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 -> %Response{text: ~s({"name": "Ada"}), provider: :mock, finish_reason: :stop}
          _ -> %Response{text: ~s({"name": "Ada", "age": 36}), provider: :mock, finish_reason: :stop}
        end
      end

      schema = %{
        "type" => "object",
        "required" => ["name", "age"],
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer"}
        }
      }

      assert {:ok, %{"name" => "Ada", "age" => 36}} =
               Structured.extract("tell me",
                 provider: :mock,
                 mock: [responder: responder],
                 schema: schema
               )

      assert :counters.get(counter, 1) == 2
    end

    test "exhausts :max_retries and wraps the final validation error" do
      responder = fn _req -> %Response{text: ~s({}), provider: :mock} end

      schema = %{"type" => "object", "required" => ["k"]}

      assert {:error, {:error_max_structured_output_retries, _}} =
               Structured.extract("x",
                 provider: :mock,
                 mock: [responder: responder],
                 schema: schema,
                 max_retries: 1
               )
    end

    test "emits {:structured_retry, …} events on each retry" do
      test_pid = self()

      responder = fn _req -> %Response{text: ~s({}), provider: :mock} end

      _ =
        Structured.extract("x",
          provider: :mock,
          mock: [responder: responder],
          schema: %{"type" => "object", "required" => ["k"]},
          max_retries: 2,
          on_event: fn e -> send(test_pid, {:evt, e}) end
        )

      assert_receive {:evt, {:structured_retry, %{attempt: 1}}}
      assert_receive {:evt, {:structured_retry, %{attempt: 2}}}
    end
  end
end
