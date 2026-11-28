defmodule ExAthena.SessionChatStoreTest do
  @moduledoc "A library session saved with `store: :chat` opens in the terminal chat (issue 360)."
  # Not async: the chat folder comes from app config.
  use ExUnit.Case, async: false

  alias ExAthena.{Chats, Response, Session}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.get_env(:ex_athena, :chats_dir)
    Application.put_env(:ex_athena, :chats_dir, Path.join(tmp, "chats"))
    on_exit(fn -> Application.put_env(:ex_athena, :chats_dir, previous) end)
    {:ok, cwd: tmp}
  end

  defp start(cwd, id) do
    responder = fn _ -> %Response{text: "hello back", finish_reason: :stop, provider: :mock} end

    {:ok, pid} =
      Session.start_link(
        provider: :mock,
        mock: [responder: responder],
        cwd: cwd,
        memory: false,
        tools: [],
        store: :chat,
        session_id: id
      )

    pid
  end

  test "a library session saved to the chat record resumes in the terminal chat", %{cwd: cwd} do
    pid = start(cwd, "libchat000001")
    {:ok, _} = Session.send_message(pid, "hi there")
    Session.stop(pid)

    assert {:ok, opened} = ExAthena.Chat.Session.open("libchat000001")

    assert [%{role: :user, content: "hi there"}, %{role: :assistant, content: "hello back"}] =
             opened.messages

    assert opened.cwd == cwd

    assert {:ok, [%{content: "hi there"}, %{content: "hello back"}]} =
             Session.resume("libchat000001", store: :chat)
  end

  test "fork and rewind go through the chat record", %{cwd: cwd} do
    pid = start(cwd, "libchat000002")
    {:ok, _} = Session.send_message(pid, "one")
    Session.stop(pid)
    {:ok, %{steps: [first | _]}} = Chats.load("libchat000002")

    assert {:ok, %{session_id: fork_id}} =
             Session.fork("libchat000002", store: :chat, step: first.uuid)

    assert {:ok, %{forked_from: %{chat: "libchat000002"}}} = Chats.load(fork_id)

    assert {:ok, %{steps_dropped: 1}} =
             Session.rewind("libchat000002", {:step, first.uuid}, store: :chat)

    assert {:ok, [%{content: "one"}]} = Session.resume("libchat000002", store: :chat)
  end

  test "a turn waits while another front end runs a reply in the chat", %{cwd: cwd} do
    pid = start(cwd, "libchat000003")
    test_pid = self()

    holder =
      spawn(fn ->
        :ok = Chats.hold("libchat000003")
        send(test_pid, :held)
        receive do: (:stop -> :ok)
      end)

    assert_receive :held
    assert {:error, :busy} = Session.send_message(pid, "hi")
    Process.exit(holder, :kill)
    Session.stop(pid)
  end

  test "a session whose chat moved on elsewhere saves its turn as a new chat", %{cwd: cwd} do
    pid = start(cwd, "libchat000004")
    {:ok, _} = Session.send_message(pid, "one")
    {:ok, %{messages: msgs}} = Chats.load("libchat000004")
    :ok = Chats.sync("libchat000004", msgs ++ [ExAthena.Messages.user("terminal turn")])

    {:ok, _} = Session.send_message(pid, "two")
    new_id = Session.session_id(pid)
    Session.stop(pid)

    assert new_id != "libchat000004"
    assert {:ok, %{forked_from: %{chat: "libchat000004"}}} = Chats.load(new_id)
    assert {:ok, %{messages: theirs}} = Chats.load("libchat000004")
    assert List.last(theirs).content == "terminal turn"
  end
end
