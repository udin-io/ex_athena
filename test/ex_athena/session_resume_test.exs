defmodule ExAthena.SessionResumeTest do
  @moduledoc """
  PR5 — verifies that Session events flow through a Store and that
  `Session.resume/2` reconstructs the message list from them.
  """
  use ExUnit.Case, async: false

  alias ExAthena.{Response, Session}
  alias ExAthena.Sessions.Stores.InMemory

  setup do
    InMemory.reset()
    :ok
  end

  defp single_text(text) do
    fn _req -> %Response{text: text, finish_reason: :stop, provider: :mock} end
  end

  test "Session persists user + assistant messages to the InMemory store" do
    {:ok, pid} =
      Session.start_link(
        provider: :mock,
        mock: [responder: single_text("ack")],
        tools: [],
        memory: false
      )

    sid = Session.session_id(pid)
    {:ok, _} = Session.send_message(pid, "hello world")
    Session.stop(pid)

    {:ok, events} = InMemory.read(sid)
    kinds = Enum.map(events, & &1.event)

    assert :session_start in kinds
    assert :user_message in kinds
    assert :assistant_message in kinds

    user_event = Enum.find(events, &(&1.event == :user_message))
    assert user_event.data.message[:content] == "hello world"
  end

  test "Session.resume/2 reconstructs prior messages from a store" do
    {:ok, pid} =
      Session.start_link(
        provider: :mock,
        mock: [responder: single_text("ack")],
        tools: [],
        memory: false
      )

    sid = Session.session_id(pid)
    {:ok, _} = Session.send_message(pid, "what is 2+2?")
    {:ok, _} = Session.send_message(pid, "and 3+3?")
    Session.stop(pid)

    assert {:ok, messages} = Session.resume(sid)
    user_messages = Enum.filter(messages, &(&1.role == :user))
    assistant_messages = Enum.filter(messages, &(&1.role == :assistant))

    assert length(user_messages) == 2
    assert length(assistant_messages) == 2
    assert hd(user_messages).content == "what is 2+2?"
  end

  test "resuming an unknown session id yields an empty message list" do
    assert {:ok, []} = Session.resume("nonexistent-session")
  end
end
