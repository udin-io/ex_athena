defmodule ExAthena.SessionRewindTest do
  use ExUnit.Case, async: false

  alias ExAthena.{Response, Session}
  alias ExAthena.Sessions.Stores.ETS

  setup do
    case GenServer.whereis(ETS) do
      nil -> start_supervised!(ETS)
      _pid -> :ok
    end

    ETS.reset()
    :ok
  end

  defp single_text(text) do
    fn _req -> %Response{text: text, finish_reason: :stop, provider: :mock} end
  end

  defp start_session do
    {:ok, pid} =
      Session.start_link(
        provider: :mock,
        mock: [responder: single_text("ack")],
        tools: [],
        memory: false,
        store: :ets
      )

    sid = Session.session_id(pid)
    {pid, sid}
  end

  # ── Anchor resolution — by snapshot ────────────────────────────────

  test "rewind by snapshot truncates messages after anchor" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "one")
    {:ok, snap} = Session.checkpoint(sid, store: :ets)
    {:ok, _} = Session.send_message(pid, "two")
    {:ok, _} = Session.send_message(pid, "three")
    Session.stop(pid)

    {:ok, before_msgs} = ETS.list_messages(sid)
    count_before = length(before_msgs)

    assert {:ok, info} = Session.rewind(sid, {:snapshot, snap.id}, store: :ets)
    assert info.session_id == sid
    assert info.anchor_message_id == snap.message_id
    assert info.messages_deleted > 0
    assert info.message_count == count_before - info.messages_deleted

    {:ok, after_msgs} = ETS.list_messages(sid)
    assert length(after_msgs) == info.message_count

    anchor_seq = after_msgs |> Enum.sort_by(& &1.seq) |> List.last() |> Map.get(:seq)
    snap_msg = Enum.find(before_msgs, &(&1.id == snap.message_id))
    assert anchor_seq == snap_msg.seq
  end

  # ── Anchor resolution — by message ─────────────────────────────────

  test "rewind by message_id truncates messages after anchor" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "one")
    {:ok, _} = Session.send_message(pid, "two")
    Session.stop(pid)

    {:ok, messages} = ETS.list_messages(sid)
    sorted = Enum.sort_by(messages, & &1.seq)
    anchor = hd(sorted)

    assert {:ok, info} = Session.rewind(sid, {:message, anchor.id}, store: :ets)
    assert info.anchor_message_id == anchor.id
    assert info.messages_deleted > 0

    {:ok, after_msgs} = ETS.list_messages(sid)
    assert Enum.all?(after_msgs, &(&1.seq <= anchor.seq))
  end

  # ── Missing anchors ────────────────────────────────────────────────

  test "rewind with missing snapshot id returns {:error, :not_found}" do
    {_pid, sid} = start_session()
    assert {:error, :not_found} = Session.rewind(sid, {:snapshot, "nonexistent"}, store: :ets)
  end

  test "rewind with missing message id returns {:error, :not_found}" do
    {_pid, sid} = start_session()
    assert {:error, :not_found} = Session.rewind(sid, {:message, "nonexistent"}, store: :ets)
  end

  # ── Idempotency / no-op ─────────────────────────────────────────────

  test "rewind twice to same anchor returns messages_deleted: 0 on second call" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "one")
    {:ok, snap} = Session.checkpoint(sid, store: :ets)
    {:ok, _} = Session.send_message(pid, "two")
    Session.stop(pid)

    {:ok, info1} = Session.rewind(sid, {:snapshot, snap.id}, store: :ets)
    assert info1.messages_deleted > 0

    {:ok, info2} = Session.rewind(sid, {:snapshot, snap.id}, store: :ets)
    assert info2.messages_deleted == 0
    assert info2.message_count == info1.message_count
  end

  test "rewind to last message returns messages_deleted: 0" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "only")
    Session.stop(pid)

    {:ok, messages} = ETS.list_messages(sid)
    last = messages |> Enum.sort_by(& &1.seq) |> List.last()

    assert {:ok, info} = Session.rewind(sid, {:message, last.id}, store: :ets)
    assert info.messages_deleted == 0
  end

  # ── Continued loop execution after rewind ─────────────────────────

  test "resume after rewind returns only messages up to anchor" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "turn 1")
    {:ok, snap} = Session.checkpoint(sid, store: :ets)
    {:ok, _} = Session.send_message(pid, "turn 2")
    {:ok, _} = Session.send_message(pid, "turn 3")
    Session.stop(pid)

    {:ok, info} = Session.rewind(sid, {:snapshot, snap.id}, store: :ets)

    {:ok, msgs} = Session.resume(sid, store: :ets, as: :messages)
    assert length(msgs) == info.message_count
  end

  test "new session started from rewound state continues from rewound point" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "turn 1")
    {:ok, snap} = Session.checkpoint(sid, store: :ets)
    {:ok, _} = Session.send_message(pid, "turn 2")
    Session.stop(pid)

    {:ok, _info} = Session.rewind(sid, {:snapshot, snap.id}, store: :ets)

    {:ok, seed_msgs} = Session.resume(sid, store: :ets, as: :messages)

    {:ok, pid2} =
      Session.start_link(
        provider: :mock,
        mock: [responder: single_text("ack")],
        tools: [],
        memory: false,
        store: :ets,
        session_id: sid,
        messages: seed_msgs
      )

    {:ok, _} = Session.send_message(pid2, "new turn after rewind")
    Session.stop(pid2)

    {:ok, final_msgs} = Session.resume(sid, store: :ets, as: :messages)

    contents = Enum.map(final_msgs, & &1.content)

    assert Enum.any?(contents, fn c ->
             is_binary(c) and String.contains?(c, "new turn after rewind")
           end)

    refute Enum.any?(contents, fn c -> is_binary(c) and String.contains?(c, "turn 2") end)
  end

  # ── Snapshots survive rewind ───────────────────────────────────────

  test "snapshots beyond anchor are preserved after rewind" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "turn 1")
    {:ok, snap1} = Session.checkpoint(sid, store: :ets)
    {:ok, _} = Session.send_message(pid, "turn 2")
    {:ok, snap2} = Session.checkpoint(sid, store: :ets)
    Session.stop(pid)

    {:ok, _} = Session.rewind(sid, {:snapshot, snap1.id}, store: :ets)

    {:ok, snapshots} = ETS.list_snapshots(sid)
    snap_ids = Enum.map(snapshots, & &1.id)
    assert snap1.id in snap_ids
    assert snap2.id in snap_ids
  end

  # ── Store gating ───────────────────────────────────────────────────

  test "unsupported store returns {:error, :unsupported_store} and emits no telemetry" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:ex_athena, :session, :rewind]])

    assert {:error, :unsupported_store} =
             Session.rewind("any-id", {:snapshot, "x"}, store: :in_memory)

    refute_receive {[:ex_athena, :session, :rewind], _, _, _}

    :telemetry.detach(ref)
  end

  # ── Telemetry ──────────────────────────────────────────────────────

  test "emits rewind telemetry with correct measurements and metadata" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "one")
    {:ok, snap} = Session.checkpoint(sid, store: :ets)
    {:ok, _} = Session.send_message(pid, "two")
    Session.stop(pid)

    ref = :telemetry_test.attach_event_handlers(self(), [[:ex_athena, :session, :rewind]])

    {:ok, info} = Session.rewind(sid, {:snapshot, snap.id}, store: :ets)

    assert_receive {[:ex_athena, :session, :rewind], ^ref,
                    %{messages_deleted: deleted, message_count: count},
                    %{
                      session_id: ^sid,
                      anchor_message_id: anchor_id,
                      target: :snapshot,
                      store: _
                    }}

    assert deleted == info.messages_deleted
    assert count == info.message_count
    assert anchor_id == snap.message_id

    :telemetry.detach(ref)
  end

  test "emits telemetry with target: :message when rewinding by message id" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "one")
    Session.stop(pid)

    {:ok, messages} = ETS.list_messages(sid)
    msg = hd(Enum.sort_by(messages, & &1.seq))

    ref = :telemetry_test.attach_event_handlers(self(), [[:ex_athena, :session, :rewind]])

    Session.rewind(sid, {:message, msg.id}, store: :ets)

    assert_receive {[:ex_athena, :session, :rewind], ^ref, _, %{target: :message}}

    :telemetry.detach(ref)
  end

  # ── Session updated_at refresh ─────────────────────────────────────

  test "rewind refreshes the session updated_at" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "one")
    {:ok, snap} = Session.checkpoint(sid, store: :ets)
    {:ok, _} = Session.send_message(pid, "two")
    Session.stop(pid)

    {:ok, before_session} = ETS.get_session(sid)
    updated_before = before_session.updated_at

    # ensure timestamp advances
    :timer.sleep(2)

    {:ok, _} = Session.rewind(sid, {:snapshot, snap.id}, store: :ets)

    {:ok, after_session} = ETS.get_session(sid)
    assert after_session.updated_at != updated_before
  end

  # ── Snapshot index O(1) smoke ──────────────────────────────────────

  test "get_snapshot returns correct snapshot after many inserts across sessions" do
    session_ids =
      for _ <- 1..5, do: Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    all_snap_ids =
      for sid <- session_ids do
        {:ok, pid} =
          Session.start_link(
            provider: :mock,
            mock: [responder: single_text("ack")],
            tools: [],
            memory: false,
            store: :ets,
            session_id: sid
          )

        {:ok, _} = Session.send_message(pid, "hello")

        snaps =
          for _i <- 1..10 do
            {:ok, snap} =
              Session.checkpoint(sid, store: :ets, label: "snap-#{:erlang.unique_integer()}")

            snap
          end

        Session.stop(pid)
        snaps
      end
      |> List.flatten()

    for snap <- all_snap_ids do
      assert {:ok, found} = ETS.get_snapshot(snap.id)
      assert found.id == snap.id
    end

    assert {:error, :not_found} = ETS.get_snapshot("does-not-exist")
  end

  # ── Snapshot index cleanup via delete_session ──────────────────────

  test "delete_session removes all snapshot index entries for that session" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "one")
    {:ok, snap1} = Session.checkpoint(sid, store: :ets, label: "a")
    {:ok, _} = Session.send_message(pid, "two")
    {:ok, snap2} = Session.checkpoint(sid, store: :ets, label: "b")
    Session.stop(pid)

    ETS.delete_session(sid)

    assert {:error, :not_found} = ETS.get_snapshot(snap1.id)
    assert {:error, :not_found} = ETS.get_snapshot(snap2.id)
  end
end
