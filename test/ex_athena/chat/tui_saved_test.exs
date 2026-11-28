defmodule ExAthena.Chat.TuiSavedTest do
  @moduledoc """
  The terminal chat saves each turn and opens saved chats: `--resume`,
  `/resume`, `/fork` and `/rewind` (issue 358).
  """
  # Not async: the chat folder comes from app config.
  use ExUnit.Case, async: false

  alias ExAthena.Chat.{Session, Tui}
  alias ExAthena.Chat.Tui.{Runner, State}
  alias ExAthena.Chats
  alias ExAthena.Messages
  alias ExAthena.Result
  alias ExRatatui.Event

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.get_env(:ex_athena, :chats_dir)
    Application.put_env(:ex_athena, :chats_dir, Path.join(tmp, "chats"))
    on_exit(fn -> Application.put_env(:ex_athena, :chats_dir, previous) end)
    {:ok, cwd: tmp}
  end

  defp key(code), do: %Event.Key{kind: "press", code: code, modifiers: []}

  defp fresh(cwd) do
    [provider: :ollama, model: "qwen", cwd: cwd]
    |> Session.new()
    |> State.new()
    |> Map.put(:input_ref, ExRatatui.textarea_new())
  end

  # A finished turn, as the runner reports it.
  defp finish_turn(state, text, reply) do
    state = %{state | session: Session.append_user(state.session, text)}
    result = %Result{messages: state.session.messages ++ [Messages.assistant(reply)], text: reply}
    {:noreply, state} = Tui.handle_info({:athena_done, result}, state)
    state
  end

  defp type(state, text) do
    ExRatatui.textarea_set_value(state.input_ref, text)
    {:noreply, state} = Tui.handle_event(key("enter"), state)
    state
  end

  defp infos(state), do: for({kind, text} <- state.events, kind in [:info, :warning], do: text)

  test "a finished turn is saved, and a new terminal chat opened with --resume shows it", %{
    cwd: cwd
  } do
    state = cwd |> fresh() |> finish_turn("add rate limiting", "Done: lib/auth.ex")
    id = state.session.chat_id

    reopened = Tui.build_state(resume: id)

    assert reopened.session.chat_id == id
    assert reopened.session.messages == state.session.messages
    assert {:user, "add rate limiting"} in reopened.events
    assert {:assistant, "Done: lib/auth.ex"} in reopened.events
  end

  test "--resume with a chat that is not saved starts a new chat and says why" do
    state = Tui.build_state(resume: "nope123")
    assert state.session.messages == []
    assert Enum.any?(infos(state), &(&1 =~ "nope123"))
  end

  test "/resume lists this folder's chats, and Enter opens the one picked", %{cwd: cwd} do
    first = cwd |> fresh() |> finish_turn("first chat", "1")
    _elsewhere = Path.join(cwd, "other") |> fresh() |> finish_turn("other folder", "2")

    state = cwd |> fresh() |> type("/resume")
    assert {:resume, [{id, label}], 0} = state.popup
    assert id == first.session.chat_id
    assert label =~ "first chat"

    {:noreply, state} = Tui.handle_event(key("enter"), state)
    assert state.popup == nil
    assert state.session.chat_id == first.session.chat_id
    assert {:user, "first chat"} in state.events
  end

  test "/resume <id> opens that chat", %{cwd: cwd} do
    saved = cwd |> fresh() |> finish_turn("named", "ok")
    state = cwd |> fresh() |> type("/resume " <> saved.session.chat_id)
    assert state.session.chat_id == saved.session.chat_id
  end

  test "/fork 1 copies step 1 into a new chat and switches to it", %{cwd: cwd} do
    state = cwd |> fresh() |> finish_turn("one", "two")
    original = state.session.chat_id

    state = type(state, "/fork 1")

    assert state.session.chat_id != original
    assert [%{content: "one"}] = state.session.messages
    assert {:ok, %{forked_from: %{chat: ^original}}} = Chats.load(state.session.chat_id)
  end

  test "/rewind lists the steps, and /rewind 1 goes back to step 1", %{cwd: cwd} do
    state = cwd |> fresh() |> finish_turn("one", "two")

    listed = type(state, "/rewind")
    assert Enum.any?(infos(listed), &(&1 =~ "1. you: one"))
    assert Enum.any?(infos(listed), &(&1 =~ "2. model: two"))

    state = type(listed, "/rewind 1")
    assert [%{content: "one"}] = state.session.messages
    assert {:ok, %{messages: [%{content: "one"}]}} = Chats.load(state.session.chat_id)
  end

  test "/rewind refuses while another front end runs a turn in the chat", %{cwd: cwd} do
    state = cwd |> fresh() |> finish_turn("one", "two")
    id = state.session.chat_id
    test_pid = self()

    spawn(fn ->
      :ok = Chats.hold(id)
      send(test_pid, :held)
      receive do: (:stop -> :ok)
    end)

    assert_receive :held
    state = type(state, "/rewind 1")
    assert length(state.session.messages) == 2
    assert Enum.any?(infos(state), &(&1 =~ "reply to finish"))
  end

  test "a sent message holds the chat until its reply ends", %{cwd: cwd} do
    state = cwd |> fresh() |> finish_turn("one", "two")
    id = state.session.chat_id
    test_pid = self()

    state = type(state, "next please")
    assert is_pid(state.run_task)

    spawn(fn -> send(test_pid, {:other, Chats.fork(id)}) end)
    assert_receive {:other, {:error, :busy}}

    {:noreply, _state} = Tui.handle_info({:athena_error, :stopped}, state)
    spawn(fn -> send(test_pid, {:other, Chats.fork(id)}) end)
    assert_receive {:other, {:ok, _}}
  end

  test "a message is not sent while another window runs a reply in the chat", %{cwd: cwd} do
    state = cwd |> fresh() |> finish_turn("one", "two")
    id = state.session.chat_id
    test_pid = self()

    spawn(fn ->
      :ok = Chats.hold(id)
      send(test_pid, :held)
      receive do: (:stop -> :ok)
    end)

    assert_receive :held
    state = type(state, "next please")
    assert state.run_task == nil
    assert Enum.any?(infos(state), &(&1 =~ "Another window"))
  end

  test "a reply finished on a copy another window moved on is saved as a new chat", %{cwd: cwd} do
    state = cwd |> fresh() |> finish_turn("one", "two")
    id = state.session.chat_id

    # The web UI adds a turn meanwhile.
    :ok =
      Chats.sync(
        id,
        state.session.messages ++ [Messages.user("web turn"), Messages.assistant("web reply")]
      )

    state = finish_turn(state, "terminal turn", "terminal reply")

    assert state.session.chat_id != id
    assert {:ok, %{messages: web}} = Chats.load(id)
    assert List.last(web).content == "web reply"
    assert {:ok, %{messages: mine, forked_from: %{chat: ^id}}} = Chats.load(state.session.chat_id)
    assert List.last(mine).content == "terminal reply"
    assert Enum.any?(infos(state), &(&1 =~ "saved as a new chat"))
  end

  test "rewind keeps the permission picked since the last save", %{cwd: cwd} do
    state = cwd |> fresh() |> State.set_permission(:trusted) |> finish_turn("one", "two")
    state = state |> State.set_permission(:read_only) |> type("/rewind 1")

    assert [%{content: "one"}] = state.session.messages
    assert state.session.permission == :read_only
  end

  test "Ctrl+C saves the chat before leaving", %{cwd: cwd} do
    state = %{fresh(cwd) | session: Session.append_user(fresh(cwd).session, "unsent reply")}

    {:stop, state} =
      Tui.handle_event(%Event.Key{kind: "press", code: "c", modifiers: ["ctrl"]}, state)

    assert {:ok, %{messages: [%{content: "unsent reply"}]}} = Chats.load(state.session.chat_id)
  end

  test "quitting an idle window whose chat moved on elsewhere saves nothing", %{cwd: cwd} do
    state = cwd |> fresh() |> finish_turn("one", "two")
    id = state.session.chat_id

    :ok =
      Chats.sync(
        id,
        state.session.messages ++ [Messages.user("web"), Messages.assistant("web reply")]
      )

    {:stop, state} =
      Tui.handle_event(%Event.Key{kind: "press", code: "c", modifiers: ["ctrl"]}, state)

    assert state.session.chat_id == id
    assert [%{id: ^id}] = Chats.list(cwd: cwd)
  end

  test "quitting after only a setting changed records it without forking", %{cwd: cwd} do
    state = cwd |> fresh() |> finish_turn("one", "two")
    id = state.session.chat_id

    :ok =
      Chats.sync(
        id,
        state.session.messages ++ [Messages.user("web"), Messages.assistant("web reply")]
      )

    state = State.set_model(state, "llama")

    {:stop, state} =
      Tui.handle_event(%Event.Key{kind: "press", code: "c", modifiers: ["ctrl"]}, state)

    assert state.session.chat_id == id
    assert [%{id: ^id, model: "llama"}] = Chats.list(cwd: cwd)
  end

  test "a message sent on a copy another window went on with runs in a new chat", %{cwd: cwd} do
    state = cwd |> fresh() |> finish_turn("one", "two")
    id = state.session.chat_id

    :ok =
      Chats.sync(
        id,
        state.session.messages ++ [Messages.user("web"), Messages.assistant("web reply")]
      )

    state = type(state, "next please")

    assert state.session.chat_id != id
    assert {:ok, %{forked_from: %{chat: ^id}}} = Chats.load(state.session.chat_id)

    assert Runner.build_run_opts(state.session, fn _ -> :ok end)[:session_id] ==
             state.session.chat_id

    {:noreply, _} = Tui.handle_info({:athena_error, :stopped}, state)
  end
end
