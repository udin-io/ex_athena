defmodule ExAthena.Chats.CodecTest do
  use ExUnit.Case, async: true

  alias ExAthena.Chats.Codec
  alias ExAthena.Messages
  alias ExAthena.Messages.{ContentPart, Message, ToolCall, ToolResult}

  # Through JSON text and back, the way a saved chat line travels.
  defp round_trip(term),
    do: term |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()

  test "a message with every part reads back unchanged" do
    msg = %Message{
      role: :assistant,
      content: [
        ContentPart.text("look at this"),
        ContentPart.image(<<137, 80, 78, 71, 0, 255>>, "image/png"),
        %ContentPart{type: :file, data: "x", filename: "a.txt", media_type: "text/plain"}
      ],
      tool_calls: [
        %ToolCall{id: "c1", name: "read", arguments: %{"path" => "lib/a.ex", "limit" => 10}},
        %ToolCall{id: "c2", name: "edit", arguments: %{path: "lib/b.ex"}}
      ],
      reasoning: "thinking",
      name: "orchestrator",
      pin: true
    }

    assert round_trip(msg) == msg
  end

  test "a tool result keeps is_error false and its panel" do
    msg = %Message{
      role: :tool,
      tool_results: [
        %ToolResult{
          tool_call_id: "c1",
          content: "ok",
          is_error: false,
          ui_payload: %{kind: :diff, payload: %{path: "a.ex", hunks: [{1, "+x"}], status: :ok}}
        }
      ]
    }

    assert round_trip(msg) == msg
  end

  test "plain JSON values and string-keyed maps stay readable" do
    assert Codec.encode(%{"a" => [1, 2.5, "s", nil, true]}) == %{"a" => [1, 2.5, "s", nil, true]}
    assert round_trip(%{"$a" => 1}) == %{"$a" => 1}
  end

  test "a name the system does not know stays text and makes no atom" do
    name = "never_an_atom_#{System.unique_integer([:positive])}"
    decoded = Codec.decode(%{"$a" => name})
    assert decoded == name
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "a struct whose module does not exist reads back as a plain map" do
    decoded = Codec.decode(%{"$s" => "Elixir.NoSuch.Module.Here", "$k" => %{"a" => 1}})
    assert decoded == %{a: 1}
  end

  test "Messages.user/1 output survives too" do
    msg = Messages.user("hi")
    assert round_trip(msg) == msg
  end
end
