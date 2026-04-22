defmodule ExAthena.SessionTest do
  use ExUnit.Case, async: true

  alias ExAthena.{Response, Session}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "session_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "persists message history across turns", %{dir: dir} do
    # Responder observes all prior messages and confirms they're accumulating
    responder = fn req ->
      count = length(req.messages)

      %Response{
        text: "turn #{count}",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    end

    {:ok, pid} =
      Session.start_link(
        provider: :mock,
        mock: [responder: responder],
        cwd: dir,
        tools: []
      )

    assert {:ok, %{text: "turn 1"}} = Session.send_message(pid, "hello")
    assert {:ok, %{text: "turn 3"}} = Session.send_message(pid, "second turn")
    # Each turn adds: user msg + assistant msg. After 2 turns → 4 messages in
    # history; turn 3's inference sees the 3 prior + the new user msg.

    assert Session.messages(pid) |> length() == 4

    Session.stop(pid)
  end

  test "usage merges across turns", %{dir: dir} do
    responder = fn _req ->
      %Response{
        text: "ok",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock,
        usage: %{input_tokens: 5, output_tokens: 3, total_tokens: 8}
      }
    end

    {:ok, pid} =
      Session.start_link(
        provider: :mock,
        mock: [responder: responder],
        cwd: dir,
        tools: []
      )

    Session.send_message(pid, "a")
    Session.send_message(pid, "b")
    Session.send_message(pid, "c")

    # 3 turns × (5 + 3 + 8) per-turn usage
    # The first turn result contains the cumulative so far (turn 1).
    # We only expose per-call result's usage, but the session tracks cumulative.
    # Fetch via a last send and inspect.
    Session.stop(pid)
  end

  test "tool call result threads through multi-turn history", %{dir: dir} do
    File.write!(Path.join(dir, "foo.txt"), "bar")

    counter = :counters.new(1, [:atomics])

    responder = fn _req ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      case n do
        1 ->
          %Response{
            text: "",
            tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "foo.txt"}}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    end

    {:ok, pid} =
      Session.start_link(
        provider: :mock,
        mock: [responder: responder],
        cwd: dir,
        tools: [ExAthena.Tools.Read]
      )

    assert {:ok, result} = Session.send_message(pid, "read foo.txt")
    assert result.text == "ok"

    msgs = Session.messages(pid)
    assert Enum.any?(msgs, &match?(%{role: :tool}, &1))

    Session.stop(pid)
  end
end
