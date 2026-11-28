defmodule ExAthena.ChatsTest do
  # Not async: the chat folder comes from app config, shared by every test here.
  use ExUnit.Case, async: false

  alias ExAthena.{Chats, Checkpoint}
  alias ExAthena.Messages
  alias ExAthena.Messages.{ContentPart, Message, ToolCall, ToolResult}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "chats")
    previous = Application.get_env(:ex_athena, :chats_dir)
    Application.put_env(:ex_athena, :chats_dir, root)
    on_exit(fn -> Application.put_env(:ex_athena, :chats_dir, previous) end)
    {:ok, root: root, cwd: tmp}
  end

  defp new_chat(cwd, attrs \\ %{}) do
    {:ok, chat} =
      Chats.create(
        Map.merge(%{cwd: cwd, provider: :ollama, model: "qwen", permission: :ask}, attrs)
      )

    chat
  end

  defp tool_turn(call_id, path) do
    [
      Messages.assistant(nil, [%ToolCall{id: call_id, name: "edit", arguments: %{"path" => path}}]),
      %Message{role: :tool, tool_results: [%ToolResult{tool_call_id: call_id, content: "edited"}]}
    ]
  end

  describe "create and load" do
    test "a new chat keeps its folder, model, permission and title", %{cwd: cwd} do
      chat = new_chat(cwd, %{title: "add rate limiting"})

      assert {:ok, loaded} = Chats.load(chat.id)
      assert loaded.cwd == cwd
      assert loaded.provider == :ollama
      assert loaded.model == "qwen"
      assert loaded.permission == :ask
      assert loaded.title == "add rate limiting"
      assert loaded.messages == []
    end

    test "the folder is 0700 and each chat file 0600", %{root: root, cwd: cwd} do
      chat = new_chat(cwd)
      {:ok, _} = Chats.fork(chat.id)

      assert mode(root) == 0o700

      files = File.ls!(root)
      assert length(files) == 2
      for f <- files, do: assert(mode(Path.join(root, f)) == 0o600)
    end

    test "an id that could name another path is refused" do
      for id <- ["../x", "a/b", "", String.duplicate("a", 65), "a.b", nil] do
        assert {:error, :invalid_id} = Chats.load(id)
        assert {:error, :invalid_id} = Chats.sync(id, [])
      end
    end

    test "loading a chat that was never saved says so" do
      assert {:error, :not_found} = Chats.load("abc123")
    end
  end

  describe "sync/2" do
    test "each turn's new messages are added and read back exactly", %{cwd: cwd} do
      chat = new_chat(cwd)
      picture = %Message{role: :user, content: [ContentPart.image(<<0, 1, 2>>, "image/png")]}
      turn1 = [Messages.user("hi"), Messages.assistant("hello")]
      turn2 = turn1 ++ [picture, %Message{role: :assistant, content: "nice", pin: true}]

      :ok = Chats.sync(chat.id, turn1)
      :ok = Chats.sync(chat.id, turn2)
      :ok = Chats.sync(chat.id, turn2)

      assert {:ok, %{messages: ^turn2, steps: steps}} = Chats.load(chat.id)
      assert length(steps) == 4
    end

    test "a compacted history replaces the active messages and keeps the log", %{
      root: root,
      cwd: cwd
    } do
      chat = new_chat(cwd)
      long = for i <- 1..5, do: Messages.user("m#{i}")
      :ok = Chats.sync(chat.id, long)

      summary = %Message{role: :user, content: "summary of m2-m4"}
      compacted = [hd(long), summary, List.last(long)]
      :ok = Chats.sync(chat.id, compacted)

      assert {:ok, %{messages: ^compacted}} = Chats.load(chat.id)
      body = File.read!(Path.join(root, "#{chat.id}.jsonl"))
      assert body =~ "m3"
    end

    test "a line a crash cut short is skipped, and the next line starts clean", %{
      root: root,
      cwd: cwd
    } do
      chat = new_chat(cwd)
      :ok = Chats.sync(chat.id, [Messages.user("one")])
      File.write!(Path.join(root, "#{chat.id}.jsonl"), ~s({"type":"message","uu), [:append])

      :ok = Chats.sync(chat.id, [Messages.user("one"), Messages.assistant("two")])

      assert {:ok, %{messages: [%{content: "one"}, %{content: "two"}]}} = Chats.load(chat.id)
    end
  end

  describe "list/1" do
    test "lists chats newest first, filtered by folder, with the latest title", %{cwd: cwd} do
      a = new_chat(cwd, %{title: "first"})
      b = new_chat(Path.join(cwd, "other"), %{title: "second"})
      :ok = Chats.update(a.id, %{title: "renamed"})
      touch_later(a.id)

      assert [%{id: id1, title: "renamed"}, %{id: id2}] = Chats.list()
      assert {id1, id2} == {a.id, b.id}
      assert [%{id: ^id1}] = Chats.list(cwd: cwd)
    end

    test "a helper's record stays out of the chat list", %{cwd: cwd} do
      parent = new_chat(cwd)
      _helper = new_chat(cwd, %{parent: %{chat: parent.id, step: "call-1"}})
      assert [%{id: id}] = Chats.list()
      assert id == parent.id
    end
  end

  describe "fork/2" do
    test "copies the steps up to the one picked into a new chat", %{cwd: cwd} do
      chat = new_chat(cwd, %{title: "t"})
      msgs = [Messages.user("1"), Messages.assistant("2"), Messages.user("3")]
      :ok = Chats.sync(chat.id, msgs)
      {:ok, %{steps: steps}} = Chats.load(chat.id)

      assert {:ok, fork} = Chats.fork(chat.id, step: Enum.at(steps, 1).uuid)
      assert {:ok, loaded} = Chats.load(fork.id)
      assert loaded.messages == Enum.take(msgs, 2)
      assert loaded.forked_from == %{chat: chat.id, step: Enum.at(steps, 1).uuid}
      assert loaded.cwd == cwd
      assert {:ok, %{messages: ^msgs}} = Chats.load(chat.id)
    end

    test "a step that is not in the chat is refused", %{cwd: cwd} do
      chat = new_chat(cwd)
      assert {:error, :not_found} = Chats.fork(chat.id, step: "nope")
    end
  end

  describe "rewind/3" do
    test "the chat goes on from the step, and the dropped steps stay in the log", %{
      root: root,
      cwd: cwd
    } do
      chat = new_chat(cwd)
      msgs = [Messages.user("1"), Messages.assistant("2"), Messages.user("three")]
      :ok = Chats.sync(chat.id, msgs)
      {:ok, %{steps: [_, two, _]}} = Chats.load(chat.id)

      assert {:ok, %{steps_dropped: 1}} = Chats.rewind(chat.id, two.uuid)
      assert {:ok, %{messages: [%{content: "1"}, %{content: "2"}]}} = Chats.load(chat.id)
      assert File.read!(Path.join(root, "#{chat.id}.jsonl")) =~ "three"

      # The next turn goes on from the rewound point.
      :ok = Chats.sync(chat.id, Enum.take(msgs, 2) ++ [Messages.user("four")])
      assert {:ok, %{messages: [_, _, %{content: "four"}]}} = Chats.load(chat.id)
    end

    test "puts back each file the dropped steps edited", %{cwd: cwd} do
      chat = new_chat(cwd)
      kept_file = Path.join(cwd, "kept.ex")
      edited = Path.join(cwd, "auth.ex")
      created = Path.join(cwd, "new.ex")
      File.write!(kept_file, "k0")
      File.write!(edited, "v0")

      # Step 2's call edits kept.ex and auth.ex; later calls edit auth.ex again
      # and create new.ex.
      {:ok, _} = Checkpoint.snapshot(cwd, chat.id, kept_file, "c1")
      File.write!(kept_file, "k1")
      {:ok, _} = Checkpoint.snapshot(cwd, chat.id, edited, "c1")
      File.write!(edited, "v1")
      {:ok, _} = Checkpoint.snapshot(cwd, chat.id, edited, "c2")
      File.write!(edited, "v2")
      {:ok, _} = Checkpoint.snapshot(cwd, chat.id, created, "c3")
      File.write!(created, "new")

      msgs =
        [Messages.user("go")] ++
          tool_turn("c1", "auth.ex") ++ tool_turn("c2", "auth.ex") ++ tool_turn("c3", "new.ex")

      :ok = Chats.sync(chat.id, msgs)
      {:ok, %{steps: steps}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 2}} = Chats.rewind(chat.id, Enum.at(steps, 2).uuid)
      assert File.read!(edited) == "v1"
      assert File.read!(kept_file) == "k1"
      refute File.exists?(created)
    end

    test "undoes what the edit, write and patch tools did in the dropped steps", %{cwd: cwd} do
      chat = new_chat(cwd)

      ctx = fn call ->
        ExAthena.ToolContext.new(cwd: cwd, session_id: chat.id, tool_call_id: call)
      end

      File.write!(Path.join(cwd, "a.ex"), "one\n")
      File.write!(Path.join(cwd, "p.ex"), "before\n")

      args = %{"path" => "a.ex", "old_string" => "one", "new_string" => "two"}
      assert :ok = elem(ExAthena.Tools.Edit.execute(args, ctx.("c1")), 0)

      assert :ok =
               elem(
                 ExAthena.Tools.Write.execute(%{"path" => "b.ex", "content" => "b"}, ctx.("c2")),
                 0
               )

      patch = "--- a/p.ex\n+++ b/p.ex\n@@ -1,1 +1,1 @@\n-before\n+after\n"
      assert :ok = elem(ExAthena.Tools.ApplyPatch.execute(%{"patch" => patch}, ctx.("c3")), 0)

      :ok =
        Chats.sync(
          chat.id,
          [Messages.user("go")] ++
            tool_turn("c1", "a.ex") ++ tool_turn("c2", "b.ex") ++ tool_turn("c3", "p.ex")
        )

      {:ok, %{steps: [first | _]}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 3}} = Chats.rewind(chat.id, first.uuid)
      assert File.read!(Path.join(cwd, "a.ex")) == "one\n"
      refute File.exists?(Path.join(cwd, "b.ex"))
      assert File.read!(Path.join(cwd, "p.ex")) == "before\n"
    end

    test "a file the same call snapshot twice still goes back", %{cwd: cwd} do
      chat = new_chat(cwd)
      path = Path.join(cwd, "a.ex")
      File.write!(path, "v0")
      {:ok, _} = Checkpoint.snapshot(cwd, chat.id, path, "c1")
      # c1 left the file as it was, so c2's snapshot reuses version 0.
      {:ok, _} = Checkpoint.snapshot(cwd, chat.id, path, "c2")
      File.write!(path, "v2")

      :ok =
        Chats.sync(
          chat.id,
          [Messages.user("go")] ++ tool_turn("c1", "a.ex") ++ tool_turn("c2", "a.ex")
        )

      {:ok, %{steps: steps}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 1}} = Chats.rewind(chat.id, Enum.at(steps, 2).uuid)
      assert File.read!(path) == "v0"
    end

    test "a file outside the chat's folder is left alone", %{cwd: cwd, tmp_dir: tmp} do
      chat = new_chat(Path.join(cwd, "project"))
      outside = Path.join(tmp, "outside.ex")
      File.write!(outside, "v0")
      {:ok, _} = Checkpoint.snapshot(Path.join(cwd, "project"), chat.id, outside, "c1")
      File.write!(outside, "v1")

      :ok = Chats.sync(chat.id, [Messages.user("go")] ++ tool_turn("c1", outside))
      {:ok, %{steps: [first | _]}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 0}} = Chats.rewind(chat.id, first.uuid)
      assert File.read!(outside) == "v1"
    end

    test "files stay as they are when asked", %{cwd: cwd} do
      chat = new_chat(cwd)
      path = Path.join(cwd, "a.ex")
      File.write!(path, "v0")
      {:ok, _} = Checkpoint.snapshot(cwd, chat.id, path, "c1")
      File.write!(path, "v1")
      :ok = Chats.sync(chat.id, [Messages.user("go")] ++ tool_turn("c1", "a.ex"))
      {:ok, %{steps: [first | _]}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 0}} = Chats.rewind(chat.id, first.uuid, restore_files: false)
      assert File.read!(path) == "v1"
    end
  end

  describe "a turn in progress" do
    test "rewind and fork wait for the turn to finish", %{cwd: cwd} do
      chat = new_chat(cwd)
      :ok = Chats.sync(chat.id, [Messages.user("1")])
      {:ok, %{steps: [step]}} = Chats.load(chat.id)
      test_pid = self()

      holder =
        spawn(fn ->
          :ok = Chats.hold(chat.id)
          send(test_pid, :held)
          receive do: (:stop -> :ok)
        end)

      assert_receive :held
      assert {:error, :busy} = Chats.rewind(chat.id, step.uuid)
      assert {:error, :busy} = Chats.fork(chat.id)
      assert {:error, :busy} = Chats.hold(chat.id)

      ref = Process.monitor(holder)
      send(holder, :stop)
      assert_receive {:DOWN, ^ref, _, _, _}

      assert {:ok, _} = Chats.fork(chat.id)
      assert {:ok, _} = Chats.rewind(chat.id, step.uuid)
    end

    test "the holder can hold again and release", %{cwd: cwd} do
      chat = new_chat(cwd)
      assert :ok = Chats.hold(chat.id)
      assert :ok = Chats.hold(chat.id)
      assert :ok = Chats.release(chat.id)
      assert {:ok, _} = Chats.fork(chat.id)
    end
  end

  describe "cleanup" do
    test "the 30-day cleanup removes a chat nobody touched for 31 days", %{root: root, cwd: cwd} do
      old = new_chat(cwd)
      fresh = new_chat(cwd)
      old_path = Path.join(root, "#{old.id}.jsonl")
      past = System.os_time(:second) - 31 * 24 * 60 * 60
      File.touch!(old_path, past)

      :ok = ExAthena.Storage.Sweeper.run(cwd: cwd)

      refute File.exists?(old_path)
      assert {:ok, _} = Chats.load(fresh.id)
    end
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp touch_later(id) do
    path = Chats.path(id)
    File.touch!(path, System.os_time(:second) + 60)
  end
end
