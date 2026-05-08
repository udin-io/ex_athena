defmodule ExAthena.Sessions.Stores.ETSTest do
  use ExUnit.Case, async: false

  alias ExAthena.Sessions.Store
  alias ExAthena.Sessions.Stores.{ETS, Jsonl}

  setup do
    ETS.reset()
    :ok
  end

  # ── Sessions table ───────────────────────────────────────────────────

  describe "sessions table" do
    test "put_session + get_session round-trip" do
      s = %{id: "s1", title: "hello"}
      :ok = ETS.put_session(s)
      assert {:ok, ^s} = ETS.get_session("s1")
    end

    test "get_session on unknown id returns not_found" do
      assert {:error, :not_found} = ETS.get_session("nope")
    end

    test "list_sessions returns every inserted session" do
      :ok = ETS.put_session(%{id: "a"})
      :ok = ETS.put_session(%{id: "b"})
      ids = ETS.list_sessions() |> Enum.map(& &1.id)
      assert "a" in ids
      assert "b" in ids
    end

    test "re-put_session with same id overwrites" do
      :ok = ETS.put_session(%{id: "s1", title: "original"})
      :ok = ETS.put_session(%{id: "s1", title: "updated"})
      assert {:ok, %{title: "updated"}} = ETS.get_session("s1")
      assert length(ETS.list_sessions()) == 1
    end

    test "delete_session removes the session" do
      :ok = ETS.put_session(%{id: "s1"})
      :ok = ETS.delete_session("s1")
      assert {:error, :not_found} = ETS.get_session("s1")
    end

    test "delete_session cascades to messages" do
      :ok = ETS.put_session(%{id: "s1"})
      :ok = ETS.put_message(%{id: "m1", session_id: "s1", role: :user, content: %{}, ts: now()})
      :ok = ETS.delete_session("s1")
      assert {:ok, []} = ETS.list_messages("s1")
    end

    test "delete_session cascades to snapshots" do
      :ok = ETS.put_session(%{id: "s1"})
      :ok = ETS.put_message(%{id: "m1", session_id: "s1", role: :user, content: %{}, ts: now()})

      :ok =
        ETS.put_snapshot(%{
          id: "snap1",
          session_id: "s1",
          message_id: "m1",
          state: %{},
          created_at: now()
        })

      :ok = ETS.delete_session("s1")
      assert {:ok, []} = ETS.list_snapshots("s1")
    end
  end

  # ── Messages table ───────────────────────────────────────────────────

  describe "messages table" do
    test "put_message + list_messages round-trip" do
      m = %{id: "m1", session_id: "s1", role: :user, content: %{text: "hi"}, ts: now()}
      :ok = ETS.put_message(m)
      assert {:ok, [stored]} = ETS.list_messages("s1")
      assert stored.id == "m1"
      assert stored.role == :user
    end

    test "list_messages for unknown session returns empty" do
      assert {:ok, []} = ETS.list_messages("ghost")
    end

    test "messages are returned in insertion/seq order even when timestamps tie" do
      ts = now()

      :ok = ETS.put_message(%{id: "m1", session_id: "s1", role: :user, content: %{}, ts: ts})
      :ok = ETS.put_message(%{id: "m2", session_id: "s1", role: :assistant, content: %{}, ts: ts})
      :ok = ETS.put_message(%{id: "m3", session_id: "s1", role: :user, content: %{}, ts: ts})

      assert {:ok, msgs} = ETS.list_messages("s1")
      assert Enum.map(msgs, & &1.id) == ["m1", "m2", "m3"]
    end

    test "two sessions don't bleed into each other" do
      :ok = ETS.put_message(%{id: "m1", session_id: "s1", role: :user, content: %{}, ts: now()})
      :ok = ETS.put_message(%{id: "m2", session_id: "s2", role: :user, content: %{}, ts: now()})

      assert {:ok, [m1]} = ETS.list_messages("s1")
      assert m1.id == "m1"

      assert {:ok, [m2]} = ETS.list_messages("s2")
      assert m2.id == "m2"
    end

    test "delete_messages_after keeps anchor, removes later messages" do
      :ok = ETS.put_message(%{id: "m1", session_id: "s1", role: :user, content: %{}, ts: now()})

      :ok =
        ETS.put_message(%{id: "m2", session_id: "s1", role: :assistant, content: %{}, ts: now()})

      :ok = ETS.put_message(%{id: "m3", session_id: "s1", role: :user, content: %{}, ts: now()})

      :ok = ETS.delete_messages_after("s1", "m1")

      assert {:ok, msgs} = ETS.list_messages("s1")
      assert Enum.map(msgs, & &1.id) == ["m1"]
    end

    test "delete_messages_after on the last message leaves it intact" do
      :ok = ETS.put_message(%{id: "m1", session_id: "s1", role: :user, content: %{}, ts: now()})
      :ok = ETS.delete_messages_after("s1", "m1")

      assert {:ok, [m]} = ETS.list_messages("s1")
      assert m.id == "m1"
    end

    test "put_message assigns seq when absent" do
      :ok = ETS.put_message(%{id: "m1", session_id: "s1", role: :user, content: %{}, ts: now()})
      {:ok, [msg]} = ETS.list_messages("s1")
      assert is_integer(msg.seq)
    end
  end

  # ── Snapshots table ──────────────────────────────────────────────────

  describe "snapshots table" do
    test "put_snapshot + list_snapshots round-trip" do
      :ok = ETS.put_message(%{id: "m1", session_id: "s1", role: :user, content: %{}, ts: now()})
      snap = %{id: "snap1", session_id: "s1", message_id: "m1", state: %{x: 1}, created_at: now()}
      :ok = ETS.put_snapshot(snap)
      assert {:ok, [stored]} = ETS.list_snapshots("s1")
      assert stored.id == "snap1"
    end

    test "multiple snapshots for the same (session_id, message_id) coexist" do
      :ok = ETS.put_message(%{id: "m1", session_id: "s1", role: :user, content: %{}, ts: now()})

      :ok =
        ETS.put_snapshot(%{
          id: "snap1",
          session_id: "s1",
          message_id: "m1",
          state: %{},
          created_at: now()
        })

      :ok =
        ETS.put_snapshot(%{
          id: "snap2",
          session_id: "s1",
          message_id: "m1",
          state: %{},
          created_at: now()
        })

      assert {:ok, snaps} = ETS.list_snapshots("s1")
      ids = Enum.map(snaps, & &1.id)
      assert "snap1" in ids
      assert "snap2" in ids
    end

    test "get_snapshot retrieves by id" do
      :ok = ETS.put_message(%{id: "m1", session_id: "s1", role: :user, content: %{}, ts: now()})
      snap = %{id: "snap1", session_id: "s1", message_id: "m1", state: %{}, created_at: now()}
      :ok = ETS.put_snapshot(snap)
      assert {:ok, ^snap} = ETS.get_snapshot("snap1")
    end

    test "get_snapshot on unknown id returns not_found" do
      assert {:error, :not_found} = ETS.get_snapshot("no-such-snap")
    end

    test "delete_snapshots_for_session only removes rows for that session" do
      :ok = ETS.put_message(%{id: "m1", session_id: "s1", role: :user, content: %{}, ts: now()})
      :ok = ETS.put_message(%{id: "m2", session_id: "s2", role: :user, content: %{}, ts: now()})

      :ok =
        ETS.put_snapshot(%{
          id: "snap1",
          session_id: "s1",
          message_id: "m1",
          state: %{},
          created_at: now()
        })

      :ok =
        ETS.put_snapshot(%{
          id: "snap2",
          session_id: "s2",
          message_id: "m2",
          state: %{},
          created_at: now()
        })

      :ok = ETS.delete_snapshots_for_session("s1")

      assert {:ok, []} = ETS.list_snapshots("s1")
      assert {:ok, [_]} = ETS.list_snapshots("s2")
    end
  end

  # ── Event-log Store parity ───────────────────────────────────────────

  describe "ETS event-log Store parity" do
    test "append + read returns events in append order" do
      e1 = Store.new_event(:user_message, %{message: "first"})
      e2 = Store.new_event(:assistant_message, %{message: "ok"})

      :ok = ETS.append("sess-1", e1)
      :ok = ETS.append("sess-1", e2)

      assert {:ok, [^e1, ^e2]} = ETS.read("sess-1")
    end

    test "tail/2 returns the last N events" do
      Enum.each(1..5, fn i ->
        ETS.append("sess-1", Store.new_event(:user_message, %{i: i}))
      end)

      assert {:ok, events} = ETS.tail("sess-1", 2)
      assert length(events) == 2
      assert hd(events).data.i == 4
    end

    test "list/0 enumerates session ids" do
      ETS.append("a", Store.new_event(:session_start, %{}))
      ETS.append("b", Store.new_event(:session_start, %{}))

      sids = ETS.list()
      assert "a" in sids
      assert "b" in sids
    end
  end

  # ── Migration helper ─────────────────────────────────────────────────

  describe "migrate_jsonl/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "migrate_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      case GenServer.whereis(Jsonl) do
        nil -> :ok
        pid -> :ok = GenServer.stop(pid, :normal, 1_000)
      end

      {:ok, _} = Jsonl.start_link(root: root, flush_interval_ms: 50_000)

      on_exit(fn ->
        case GenServer.whereis(Jsonl) do
          nil -> :ok
          pid -> :ok = GenServer.stop(pid, :normal, 1_000)
        end

        File.rm_rf!(root)
      end)

      {:ok, root: root}
    end

    test "round-trip: JSONL events become session + message rows", %{root: root} do
      sid = "mig-test"
      :ok = Jsonl.append(sid, Store.new_event(:session_start, %{ts: now()}))

      :ok =
        Jsonl.append(
          sid,
          Store.new_event(:user_message, %{message: %{role: :user, content: "hi"}})
        )

      :ok =
        Jsonl.append(
          sid,
          Store.new_event(:assistant_message, %{message: %{role: :assistant, content: "hello"}})
        )

      :ok =
        Jsonl.append(
          sid,
          Store.new_event(:tool_result, %{message: %{role: :tool, content: "done"}})
        )

      :ok =
        Jsonl.append(
          sid,
          Store.new_event(:assistant_message, %{message: %{role: :assistant, content: "all done"}})
        )

      :ok = Jsonl.flush()

      assert {:ok, %{sessions: 1, messages: 4}} = ETS.migrate_jsonl(root: root)

      assert {:ok, session} = ETS.get_session(sid)
      assert session.id == sid

      assert {:ok, msgs} = ETS.list_messages(sid)
      assert length(msgs) == 4
      assert {:ok, []} = ETS.list_snapshots(sid)
    end

    test "idempotent: overwrite: true re-run produces same counts", %{root: root} do
      sid = "idem-test"
      :ok = Jsonl.append(sid, Store.new_event(:session_start, %{ts: now()}))

      :ok =
        Jsonl.append(
          sid,
          Store.new_event(:user_message, %{message: %{role: :user, content: "hi"}})
        )

      :ok = Jsonl.flush()

      assert {:ok, %{sessions: 1, messages: 1}} = ETS.migrate_jsonl(root: root, overwrite: true)
      assert {:ok, %{sessions: 1, messages: 1}} = ETS.migrate_jsonl(root: root, overwrite: true)

      assert {:ok, msgs} = ETS.list_messages(sid)
      assert length(msgs) == 1
    end

    test "overwrite: false skips existing sessions", %{root: root} do
      sid = "skip-test"
      :ok = Jsonl.append(sid, Store.new_event(:session_start, %{ts: now()}))

      :ok =
        Jsonl.append(
          sid,
          Store.new_event(:user_message, %{message: %{role: :user, content: "hi"}})
        )

      :ok = Jsonl.flush()

      assert {:ok, %{sessions: 1, messages: 1}} = ETS.migrate_jsonl(root: root, overwrite: false)
      assert {:ok, %{sessions: 0, messages: 0}} = ETS.migrate_jsonl(root: root, overwrite: false)

      assert {:ok, msgs} = ETS.list_messages(sid)
      assert length(msgs) == 1
    end

    test "empty root directory returns zero counts", %{root: _root} do
      empty = Path.join(System.tmp_dir!(), "empty_#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)

      on_exit(fn -> File.rm_rf!(empty) end)

      assert {:ok, %{sessions: 0, messages: 0}} = ETS.migrate_jsonl(root: empty)
    end
  end

  # ── Helper ───────────────────────────────────────────────────────────

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
