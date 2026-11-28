defmodule ExAthena.Chat.SessionSavedTest do
  @moduledoc "The terminal chat's session saves to, and opens from, the chat record (issue 358)."
  # Not async: the chat folder comes from app config.
  use ExUnit.Case, async: false

  alias ExAthena.Chat.Session
  alias ExAthena.Chats
  alias ExAthena.Messages
  alias ExAthena.Result

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.get_env(:ex_athena, :chats_dir)
    Application.put_env(:ex_athena, :chats_dir, Path.join(tmp, "chats"))
    on_exit(fn -> Application.put_env(:ex_athena, :chats_dir, previous) end)
    {:ok, cwd: tmp}
  end

  defp turn(session, text, reply) do
    session = Session.append_user(session, text)
    result = %Result{messages: session.messages ++ [Messages.assistant(reply)], text: reply}
    Session.apply_result(session, result)
  end

  defp new_session(cwd),
    do: Session.new(provider: :ollama, model: "qwen", permission: :edit, cwd: cwd)

  test "a saved chat opens with its messages, model, permission and folder", %{cwd: cwd} do
    session = cwd |> new_session() |> turn("add rate limiting to login", "done")
    assert {:ok, saved} = Session.save(session)

    assert {:ok, opened} = Session.open(saved.chat_id)
    assert opened.messages == session.messages
    assert opened.model == "qwen"
    assert opened.provider == :ollama
    assert opened.permission == :edit
    assert opened.cwd == cwd
    assert opened.chat_id == saved.chat_id
    assert {:ok, %{title: "add rate limiting to login"}} = Chats.load(saved.chat_id)
  end

  test "each save adds only the new turn and records a changed model", %{cwd: cwd} do
    {:ok, s1} = cwd |> new_session() |> turn("one", "1") |> Session.save()
    {:ok, s2} = s1 |> Session.set_model("llama") |> turn("two", "2") |> Session.save()

    assert {:ok, chat} = Chats.load(s2.chat_id)
    assert length(chat.steps) == 4
    assert chat.model == "llama"
  end

  test "a chat with no messages is not saved", %{cwd: cwd} do
    assert {:ok, session} = cwd |> new_session() |> Session.save()
    assert {:error, :not_found} = Chats.load(session.chat_id)
  end

  test "the loop runs under the chat's id, so rewind finds its file history", %{cwd: cwd} do
    session = new_session(cwd)
    opts = ExAthena.Chat.Tui.Runner.build_run_opts(session, fn _ -> :ok end)
    assert opts[:session_id] == session.chat_id
    assert Chats.valid_id?(session.chat_id)
  end

  test "clearing the chat starts a new one", %{cwd: cwd} do
    {:ok, saved} = cwd |> new_session() |> turn("one", "1") |> Session.save()
    cleared = Session.clear_messages(saved)
    assert cleared.chat_id != saved.chat_id
  end

  test "latest/1 names the newest chat of a folder", %{cwd: cwd} do
    {:ok, older} = cwd |> new_session() |> turn("old", "1") |> Session.save()
    {:ok, newer} = cwd |> new_session() |> turn("new", "2") |> Session.save()
    File.touch!(Chats.path(newer.chat_id), System.os_time(:second) + 60)
    {:ok, _other} = Path.join(cwd, "x") |> new_session() |> turn("x", "3") |> Session.save()

    assert Session.latest(cwd) == newer.chat_id
    refute Session.latest(cwd) == older.chat_id
    assert Session.latest(Path.join(cwd, "none")) == nil
  end

  describe "mix athena.chat --continue and --resume" do
    test "--continue opens the newest chat of the folder", %{cwd: cwd} do
      {:ok, saved} = cwd |> new_session() |> turn("one", "1") |> Session.save()
      opts = Mix.Tasks.Athena.Chat.put_resume([cwd: cwd], continue: true)
      assert opts[:resume] == saved.chat_id
    end

    test "--continue in a folder with no chat starts a new one", %{cwd: cwd} do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      opts = Mix.Tasks.Athena.Chat.put_resume([cwd: cwd], continue: true)
      refute Keyword.has_key?(opts, :resume)
      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "No saved chat"
    end

    test "--resume names the chat to open" do
      assert Mix.Tasks.Athena.Chat.put_resume([], resume: "abc")[:resume] == "abc"
    end
  end

  test "an explicit option wins over the saved one when opening", %{cwd: cwd} do
    {:ok, saved} = cwd |> new_session() |> turn("one", "1") |> Session.save()
    assert {:ok, opened} = Session.open(saved.chat_id, model: "other")
    assert opened.model == "other"
  end
end
