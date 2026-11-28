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
      :ok = Checkpoint.record_written(cwd, chat.id, kept_file)
      {:ok, _} = Checkpoint.snapshot(cwd, chat.id, edited, "c1")
      File.write!(edited, "v1")
      :ok = Checkpoint.record_written(cwd, chat.id, edited)
      {:ok, _} = Checkpoint.snapshot(cwd, chat.id, edited, "c2")
      File.write!(edited, "v2")
      :ok = Checkpoint.record_written(cwd, chat.id, edited)
      {:ok, _} = Checkpoint.snapshot(cwd, chat.id, created, "c3")
      File.write!(created, "new")
      :ok = Checkpoint.record_written(cwd, chat.id, created)

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
      :ok = Checkpoint.record_written(cwd, chat.id, path)

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
      :ok = Checkpoint.record_written(cwd, chat.id, path)
      :ok = Chats.sync(chat.id, [Messages.user("go")] ++ tool_turn("c1", "a.ex"))
      {:ok, %{steps: [first | _]}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 0}} = Chats.rewind(chat.id, first.uuid, restore_files: false)
      assert File.read!(path) == "v1"
    end
  end

  describe "rewind/3 and the file history" do
    test "an edit a compaction summarised keeps its effect", %{cwd: cwd} do
      chat = new_chat(cwd)
      path = Path.join(cwd, "auth.ex")
      File.write!(path, "v0")
      {:ok, _} = Checkpoint.snapshot(cwd, chat.id, path, "c1")
      File.write!(path, "v1")
      :ok = Checkpoint.record_written(cwd, chat.id, path)

      full = [Messages.user("go")] ++ tool_turn("c1", "auth.ex") ++ [Messages.assistant("done")]
      :ok = Chats.sync(chat.id, full)

      compacted = [
        hd(full),
        %Message{role: :user, content: "summary: edited auth.ex"},
        Messages.user("next")
      ]

      :ok = Chats.sync(chat.id, compacted)
      {:ok, %{steps: steps}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 0}} = Chats.rewind(chat.id, Enum.at(steps, 1).uuid)
      assert File.read!(path) == "v1"
    end

    test "an edit an earlier rewind already undid does not pull a later rewind back", %{cwd: cwd} do
      chat = new_chat(cwd)
      path = Path.join(cwd, "a.ex")
      File.write!(path, "X")

      {:ok, _} = Checkpoint.snapshot(cwd, chat.id, path, "a")
      File.write!(path, "Y")
      :ok = Checkpoint.record_written(cwd, chat.id, path)
      :ok = Chats.sync(chat.id, [Messages.user("go")] ++ tool_turn("a", "a.ex"))
      {:ok, %{steps: [first | _]}} = Chats.load(chat.id)
      {:ok, _} = Chats.rewind(chat.id, first.uuid)
      assert File.read!(path) == "X"

      # As the edit tools do: a snapshot before each write, a note after it.
      {:ok, _} = Checkpoint.snapshot(cwd, chat.id, path, "c")
      File.write!(path, "Z")
      :ok = Checkpoint.record_written(cwd, chat.id, path)
      {:ok, _} = Checkpoint.snapshot(cwd, chat.id, path, "d")
      File.write!(path, "W")
      :ok = Checkpoint.record_written(cwd, chat.id, path)

      :ok =
        Chats.sync(
          chat.id,
          [Messages.user("go")] ++ tool_turn("c", "a.ex") ++ tool_turn("d", "a.ex")
        )

      {:ok, %{steps: steps}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 1}} = Chats.rewind(chat.id, Enum.at(steps, 2).uuid)
      assert File.read!(path) == "Z"
    end

    test "a symlink in the folder cannot carry a restore outside it", %{cwd: cwd, tmp_dir: tmp} do
      project = Path.join(cwd, "project")
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(project)
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret"), "mine")
      File.ln_s!(outside, Path.join(project, "link"))
      chat = new_chat(project)
      target = Path.join(project, "link/secret")

      {:ok, _} = Checkpoint.snapshot(project, chat.id, target, "c1")
      File.write!(Path.join(outside, "secret"), "changed")
      :ok = Chats.sync(chat.id, [Messages.user("go")] ++ tool_turn("c1", target))
      {:ok, %{steps: [first | _]}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 0}} = Chats.rewind(chat.id, first.uuid)
      assert File.read!(Path.join(outside, "secret")) == "changed"
    end

    test "a history entry whose folder does not match its path is skipped", %{cwd: cwd} do
      chat = new_chat(cwd)
      victim = Path.join(cwd, "victim.ex")
      File.write!(victim, "keep")
      forged = Path.join(Checkpoint.history_dir(cwd, chat.id), "forged")
      File.mkdir_p!(forged)
      File.write!(Path.join(forged, "path"), victim)
      File.write!(Path.join(forged, "0.bin"), "PWNED")
      File.write!(Path.join(forged, "0.calls"), "c1\n")
      File.write!(Path.join(forged, "junk.bin"), "")

      :ok = Chats.sync(chat.id, [Messages.user("go")] ++ tool_turn("c1", "victim.ex"))
      {:ok, %{steps: [first | _]}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 0, files_failed: []}} = Chats.rewind(chat.id, first.uuid)
      assert File.read!(victim) == "keep"
    end

    test "a saved version that is a symlink is never copied back", %{cwd: cwd, tmp_dir: tmp} do
      chat = new_chat(cwd)
      path = Path.join(cwd, "a.ex")
      File.write!(path, "v0")
      {:ok, %{path: dir}} = Checkpoint.snapshot(cwd, chat.id, path, "c1")
      File.write!(path, "v1")
      secret = Path.join(tmp, "secret.key")
      File.write!(secret, "KEY")
      File.rm!(Path.join(dir, "0.bin"))
      File.ln_s!(secret, Path.join(dir, "0.bin"))

      :ok = Chats.sync(chat.id, [Messages.user("go")] ++ tool_turn("c1", "a.ex"))
      {:ok, %{steps: [first | _]}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 0}} = Chats.rewind(chat.id, first.uuid)
      assert File.read!(path) == "v1"
    end
  end

  describe "a stale copy in another front end" do
    test "a sync that expects an older version is refused after a rewind", %{cwd: cwd} do
      chat = new_chat(cwd)
      msgs = [Messages.user("1"), Messages.assistant("2"), Messages.user("3")]
      :ok = Chats.sync(chat.id, msgs)
      {:ok, %{steps: [first | _], version: seen}} = Chats.load(chat.id)
      {:ok, _} = Chats.rewind(chat.id, first.uuid)

      assert {:error, :moved} =
               Chats.sync(chat.id, msgs ++ [Messages.assistant("4")], expect: seen)

      assert {:ok, %{messages: [%{content: "1"}]}} = Chats.load(chat.id)
    end

    test "return: :version hands back the version to expect next", %{cwd: cwd} do
      chat = new_chat(cwd)
      {:ok, v1} = Chats.sync(chat.id, [Messages.user("1")], return: :version)

      {:ok, v2} =
        Chats.sync(chat.id, [Messages.user("1"), Messages.assistant("2")],
          expect: v1,
          return: :version
        )

      assert {:ok, ^v2} = Chats.version(chat.id)
      assert {:error, :moved} = Chats.sync(chat.id, [Messages.user("x")], expect: v1)
    end

    test "a sync that expects the current version goes through", %{cwd: cwd} do
      chat = new_chat(cwd)
      :ok = Chats.sync(chat.id, [Messages.user("1")])
      {:ok, v} = Chats.version(chat.id)
      assert :ok = Chats.sync(chat.id, [Messages.user("1"), Messages.assistant("2")], expect: v)
      assert {:ok, v2} = Chats.version(chat.id)
      assert v2 == v + 1
    end
  end

  describe "rewind and files other writers changed" do
    defp write_as(cwd, chat, call, rel, content) do
      ctx = ExAthena.ToolContext.new(cwd: cwd, session_id: chat, tool_call_id: call)
      {:ok, _, _} = ExAthena.Tools.Write.execute(%{"path" => rel, "content" => content}, ctx)
    end

    test "a fork's rewind leaves the files of steps it copied", %{cwd: cwd} do
      parent = new_chat(cwd)
      path = Path.join(cwd, "a.ex")
      File.write!(path, "v0")
      write_as(cwd, parent.id, "c1", "a.ex", "v1")
      :ok = Chats.sync(parent.id, [Messages.user("go")] ++ tool_turn("c1", "a.ex"))
      {:ok, fork} = Chats.fork(parent.id)
      {:ok, %{steps: [first | _]}} = Chats.load(fork.id)

      assert {:ok, %{files_restored: 0}} = Chats.rewind(fork.id, first.uuid)
      assert File.read!(path) == "v1"
    end

    test "a parent's rewind leaves a file its fork changed since, and names it", %{cwd: cwd} do
      parent = new_chat(cwd)
      path = Path.join(cwd, "c.ex")
      File.write!(path, "v0")
      write_as(cwd, parent.id, "c1", "c.ex", "v1")
      :ok = Chats.sync(parent.id, [Messages.user("go")] ++ tool_turn("c1", "c.ex"))
      {:ok, fork} = Chats.fork(parent.id)
      write_as(cwd, fork.id, "f1", "c.ex", "fork-work")
      {:ok, %{steps: [first | _]}} = Chats.load(parent.id)

      assert {:ok, %{files_restored: 0, files_failed: [^path]}} =
               Chats.rewind(parent.id, first.uuid)

      assert File.read!(path) == "fork-work"
    end

    test "a file a person edited after the chat's last write is left and named", %{cwd: cwd} do
      chat = new_chat(cwd)
      path = Path.join(cwd, "d.ex")
      File.write!(path, "v0")
      write_as(cwd, chat.id, "c1", "d.ex", "v1")
      File.write!(path, "my own edit")
      :ok = Chats.sync(chat.id, [Messages.user("go")] ++ tool_turn("c1", "d.ex"))
      {:ok, %{steps: [first | _]}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 0, files_failed: [^path]}} =
               Chats.rewind(chat.id, first.uuid)

      assert File.read!(path) == "my own edit"
    end

    test "a file the chat wrote is put back, and can be put back again later", %{cwd: cwd} do
      chat = new_chat(cwd)
      path = Path.join(cwd, "e.ex")
      File.write!(path, "v0")
      write_as(cwd, chat.id, "c1", "e.ex", "v1")
      write_as(cwd, chat.id, "c2", "e.ex", "v2")

      :ok =
        Chats.sync(
          chat.id,
          [Messages.user("go")] ++ tool_turn("c1", "e.ex") ++ tool_turn("c2", "e.ex")
        )

      {:ok, %{steps: steps}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 1}} = Chats.rewind(chat.id, Enum.at(steps, 2).uuid)
      assert File.read!(path) == "v1"
      assert {:ok, %{files_restored: 1}} = Chats.rewind(chat.id, Enum.at(steps, 0).uuid)
      assert File.read!(path) == "v0"
    end

    test "a person's edit between two of the chat's edits is kept and named", %{cwd: cwd} do
      chat = new_chat(cwd)
      path = Path.join(cwd, "p.ex")
      File.write!(path, "orig")
      write_as(cwd, chat.id, "c1", "p.ex", "s1")
      File.write!(path, "PERSON")
      write_as(cwd, chat.id, "c2", "p.ex", "PERSON+s2")

      :ok =
        Chats.sync(
          chat.id,
          [Messages.user("go")] ++ tool_turn("c1", "p.ex") ++ tool_turn("c2", "p.ex")
        )

      {:ok, %{steps: [first | _]}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 0, files_failed: [^path]}} =
               Chats.rewind(chat.id, first.uuid)

      assert File.read!(path) == "PERSON+s2"
    end

    test "a fork's edit between two of the parent's edits is kept and named", %{cwd: cwd} do
      parent = new_chat(cwd)
      path = Path.join(cwd, "f.ex")
      File.write!(path, "orig")
      write_as(cwd, parent.id, "c1", "f.ex", "p1")
      :ok = Chats.sync(parent.id, [Messages.user("go")] ++ tool_turn("c1", "f.ex"))
      {:ok, fork} = Chats.fork(parent.id)
      write_as(cwd, fork.id, "f1", "f.ex", "FORK")
      write_as(cwd, parent.id, "c2", "f.ex", "p2")
      {:ok, %{messages: msgs}} = Chats.load(parent.id)
      :ok = Chats.sync(parent.id, msgs ++ tool_turn("c2", "f.ex"))
      {:ok, %{steps: [first | _]}} = Chats.load(parent.id)

      assert {:ok, %{files_restored: 0, files_failed: [^path]}} =
               Chats.rewind(parent.id, first.uuid)

      assert File.read!(path) == "p2"
    end

    test "a patch that renames a file is refused, so no rewind can lose the source", %{cwd: cwd} do
      File.write!(Path.join(cwd, "old.ex"), "one\n")
      ctx = ExAthena.ToolContext.new(cwd: cwd, session_id: "renamechat", tool_call_id: "c1")

      rename =
        "diff --git a/old.ex b/new.ex\nrename from old.ex\nrename to new.ex\n" <>
          "--- a/old.ex\n+++ b/new.ex\n@@ -1,1 +1,1 @@\n-one\n+two\n"

      assert {:error, {:unsupported_diff_feature, :rename}} =
               ExAthena.Tools.ApplyPatch.execute(%{"patch" => rename}, ctx)

      plain = "--- a/old.ex\n+++ b/new.ex\n@@ -1,1 +1,1 @@\n-one\n+two\n"

      assert {:error, {:unsupported_diff_feature, :rename}} =
               ExAthena.Tools.ApplyPatch.execute(%{"patch" => plain}, ctx)

      assert File.read!(Path.join(cwd, "old.ex")) == "one\n"
    end

    test "a patch that changes a file its own parser does not see is refused", %{cwd: cwd} do
      {_, 0} = System.cmd("git", ["init", "-q", cwd])
      File.write!(Path.join(cwd, "old.ex"), "keep me\n")
      File.write!(Path.join(cwd, "y.ex"), "a\n")
      File.write!(Path.join(cwd, "empty.ex"), "")
      ctx = ExAthena.ToolContext.new(cwd: cwd, session_id: "hiddenchat", tool_call_id: "c1")
      edit = "diff --git a/y.ex b/y.ex\n--- a/y.ex\n+++ b/y.ex\n@@ -1,1 +1,1 @@\n-a\n+b\n"

      # `git apply` acts on each of these headers, and none has a "--- " line.
      hidden = [
        "diff --git a/old.ex b/new.ex\nsimilarity index 100%\nrename old old.ex\nrename new new.ex\n",
        "diff --git a/empty.ex b/empty.ex\ndeleted file mode 100644\nindex e69de29..0000000\n",
        "diff --git a/made.ex b/made.ex\nnew file mode 100644\nindex 0000000..e69de29\n"
      ]

      for header <- hidden do
        assert {:error, {:unsupported_diff_feature, _}} =
                 ExAthena.Tools.ApplyPatch.execute(%{"patch" => header <> edit}, ctx)
      end

      assert File.read!(Path.join(cwd, "old.ex")) == "keep me\n"
      assert File.exists?(Path.join(cwd, "empty.ex"))
      refute File.exists?(Path.join(cwd, "new.ex"))
      refute File.exists?(Path.join(cwd, "made.ex"))
      assert File.read!(Path.join(cwd, "y.ex")) == "a\n"

      assert :ok = elem(ExAthena.Tools.ApplyPatch.execute(%{"patch" => edit}, ctx), 0)
      assert File.read!(Path.join(cwd, "y.ex")) == "b\n"
    end

    test "a patch that failed, then a person's edit, is not undone", %{cwd: cwd} do
      chat = new_chat(cwd)
      path = Path.join(cwd, "q.ex")
      File.write!(path, "line1\n")
      ctx = ExAthena.ToolContext.new(cwd: cwd, session_id: chat.id, tool_call_id: "c1")
      bad = "--- a/q.ex\n+++ b/q.ex\n@@ -1,1 +1,1 @@\n-nope\n+x\n"
      assert :error = elem(ExAthena.Tools.ApplyPatch.execute(%{"patch" => bad}, ctx), 0)
      File.write!(path, "PERSON\n")
      :ok = Chats.sync(chat.id, [Messages.user("go")] ++ tool_turn("c1", "q.ex"))
      {:ok, %{steps: [first | _]}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 0}} = Chats.rewind(chat.id, first.uuid)
      assert File.read!(path) == "PERSON\n"
    end

    test "a file edited from two folders is named, not half put back", %{cwd: cwd} do
      lib = Path.join(cwd, "lib")
      File.mkdir_p!(lib)
      chat = new_chat(cwd)
      path = Path.join(lib, "a.ex")
      File.write!(path, "orig")
      write_as(cwd, chat.id, "c1", "lib/a.ex", "s1")
      write_as(lib, chat.id, "c2", "a.ex", "s2")

      :ok =
        Chats.sync(
          chat.id,
          [Messages.user("go")] ++ tool_turn("c1", "lib/a.ex") ++ tool_turn("c2", "a.ex")
        )

      :ok = Chats.update(chat.id, %{cwd: lib})
      {:ok, %{steps: [first | _]}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 0, files_failed: [^path]}} =
               Chats.rewind(chat.id, first.uuid)

      assert File.read!(path) == "s2"
    end

    test "rewind reaches files in each folder the chat worked in", %{cwd: cwd} do
      one = Path.join(cwd, "one")
      two = Path.join(cwd, "two")
      File.mkdir_p!(one)
      File.mkdir_p!(two)
      chat = new_chat(one)
      File.write!(Path.join(one, "a.ex"), "v0")
      write_as(one, chat.id, "c1", "a.ex", "v1")
      :ok = Chats.sync(chat.id, [Messages.user("go")] ++ tool_turn("c1", "a.ex"))
      :ok = Chats.update(chat.id, %{cwd: two})
      {:ok, %{steps: [first | _]}} = Chats.load(chat.id)

      assert {:ok, %{files_restored: 1}} = Chats.rewind(chat.id, first.uuid)
      assert File.read!(Path.join(one, "a.ex")) == "v0"
    end
  end

  describe "a damaged or odd file" do
    test "a copied file is not a second chat with the same id", %{root: root, cwd: cwd} do
      chat = new_chat(cwd)
      File.cp!(Path.join(root, "#{chat.id}.jsonl"), Path.join(root, "copy1.jsonl"))
      assert [%{id: id}] = Chats.list()
      assert id == chat.id
      assert {:error, :unreadable} = Chats.load("copy1")
    end

    test "a bad meta line is ignored by list and load", %{root: root, cwd: cwd} do
      chat = new_chat(cwd, %{title: "fine"})

      File.write!(Path.join(root, "#{chat.id}.jsonl"), ~s({"type":"meta","fields":"x"}\n), [
        :append
      ])

      broken = new_chat(cwd)
      File.write!(Path.join(root, "#{broken.id}.jsonl"), ~s({"type":"chat","chat":{"$b":"!!"}}\n))

      assert [%{id: id, title: "fine"}] = Chats.list()
      assert id == chat.id
      assert {:ok, %{title: "fine"}} = Chats.load(chat.id)
      assert {:error, :unreadable} = Chats.load(broken.id)
    end

    test "syncing plain maps twice writes the turn once", %{root: root, cwd: cwd} do
      chat = new_chat(cwd)
      maps = [%{role: :user, content: "hi"}, %{"role" => "assistant", "content" => "yo"}]
      :ok = Chats.sync(chat.id, maps)
      :ok = Chats.sync(chat.id, maps)

      lines =
        root |> Path.join("#{chat.id}.jsonl") |> File.read!() |> String.split("\n", trim: true)

      assert length(lines) == 3
    end

    test "a message holding a value JSON cannot keep does not rewrite the history", %{
      root: root,
      cwd: cwd
    } do
      chat = new_chat(cwd)
      ui = %{kind: :process, payload: %{pid: self()}}

      msg = %Message{
        role: :tool,
        tool_results: [%ToolResult{tool_call_id: "c", content: "x", ui_payload: ui}]
      }

      :ok = Chats.sync(chat.id, [msg])
      :ok = Chats.sync(chat.id, [msg])

      lines =
        root |> Path.join("#{chat.id}.jsonl") |> File.read!() |> String.split("\n", trim: true)

      assert length(lines) == 2
    end
  end

  describe "a turn held by another program" do
    test "a lock left by a live program keeps the chat busy", %{root: root, cwd: cwd} do
      chat = new_chat(cwd)
      # Process 1 is always alive: this stands for another ExAthena still running.
      File.write!(Path.join(root, "#{chat.id}.lock"), "1 sometoken")

      assert {:error, :busy} = Chats.fork(chat.id)
      assert {:error, :busy} = Chats.hold(chat.id)
    end

    test "a lock left by a program that is gone is taken over", %{root: root, cwd: cwd} do
      chat = new_chat(cwd)
      port = Port.open({:spawn, "true"}, [:exit_status])
      {:os_pid, dead} = Port.info(port, :os_pid)
      receive do: ({^port, {:exit_status, _}} -> :ok)
      File.write!(Path.join(root, "#{chat.id}.lock"), "#{dead} sometoken")

      assert {:ok, _} = Chats.fork(chat.id)
      refute File.exists?(Path.join(root, "#{chat.id}.lock"))
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

    test "of many processes asking at once, exactly one holds the chat", %{root: root, cwd: cwd} do
      chat = new_chat(cwd)
      test_pid = self()

      for _ <- 1..8 do
        spawn(fn ->
          send(test_pid, {:held, Chats.hold(chat.id)})
          receive do: (:stop -> :ok)
        end)
      end

      results = for _ <- 1..8, do: receive(do: ({:held, r} -> r))
      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :busy})) == 7
      assert File.exists?(Path.join(root, "#{chat.id}.lock"))
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
