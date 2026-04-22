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

    assert {:error, {:missing_required_keys, ["age"]}} =
             Structured.extract("x", schema: schema, provider: :mock,
               mock: [responder: responder])
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

    assert {:error, {:property_invalid, "age"}} =
             Structured.extract("x", schema: schema, provider: :mock,
               mock: [responder: responder])
  end

  test "validator opt overrides the default validator" do
    responder = fn _req -> %Response{text: ~s({"k": "v"}), provider: :mock} end

    strict = fn _json, _schema -> {:error, :always_fails} end

    assert {:error, :always_fails} =
             Structured.extract("x",
               provider: :mock,
               mock: [responder: responder],
               schema: %{"type" => "object"},
               validator: strict
             )
  end
end
