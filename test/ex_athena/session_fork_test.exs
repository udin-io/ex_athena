defmodule ExAthena.SessionForkTest do
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

  test "full-history clone preserves all messages with fresh ids" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "first")
    {:ok, _} = Session.send_message(pid, "second")
    Session.stop(pid)

    assert {:ok, %{session_id: new_id, parent_id: ^sid, message_count: 4}} =
             Session.fork(sid, store: :ets)

    assert new_id != sid

    {:ok, orig_msgs} = ETS.list_messages(sid)
    {:ok, fork_msgs} = ETS.list_messages(new_id)

    assert length(fork_msgs) == length(orig_msgs)

    Enum.zip(
      Enum.sort_by(orig_msgs, & &1.seq),
      Enum.sort_by(fork_msgs, & &1.seq)
    )
    |> Enum.each(fn {orig, fork} ->
      assert orig.role == fork.role
      assert orig.content == fork.content
      assert orig.id != fork.id
    end)
  end

  test "fork at explicit message_id includes only messages up to that point" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "first")
    {:ok, _} = Session.send_message(pid, "second")
    {:ok, _} = Session.send_message(pid, "third")
    Session.stop(pid)

    {:ok, messages} = ETS.list_messages(sid)
    second_msg = messages |> Enum.sort_by(& &1.seq) |> Enum.at(1)

    assert {:ok, %{session_id: new_id, message_count: 2}} =
             Session.fork(sid, store: :ets, message_id: second_msg.id)

    {:ok, fork_msgs} = ETS.list_messages(new_id)
    assert length(fork_msgs) == 2
  end

  test "fork at checkpoint_id includes only messages up to snapshot anchor" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "first")
    Session.stop(pid)

    {:ok, messages} = ETS.list_messages(sid)
    first_msg = messages |> Enum.sort_by(& &1.seq) |> hd()
    {:ok, snap} = Session.checkpoint(sid, store: :ets, message_id: first_msg.id)

    # Add more messages after the checkpoint
    {:ok, prior_msgs} = Session.resume(sid, store: :ets)

    {:ok, pid2} =
      Session.start_link(
        provider: :mock,
        mock: [responder: single_text("ack")],
        tools: [],
        memory: false,
        store: :ets,
        session_id: sid,
        messages: prior_msgs
      )

    {:ok, _} = Session.send_message(pid2, "second")
    Session.stop(pid2)

    assert {:ok, %{session_id: new_id, message_count: 1}} =
             Session.fork(sid, store: :ets, checkpoint_id: snap.id)

    {:ok, fork_msgs} = ETS.list_messages(new_id)
    assert length(fork_msgs) == 1
  end

  test "parent_id is set on the new session row" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "hello")
    Session.stop(pid)

    {:ok, %{session_id: new_id}} = Session.fork(sid, store: :ets)

    assert {:ok, new_session} = ETS.get_session(new_id)
    assert new_session.parent_id == sid
  end

  test "restarting a forked session preserves parent_id, title, and created_at" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "hello")
    Session.stop(pid)

    {:ok, %{session_id: new_id}} = Session.fork(sid, store: :ets, title: "branch a")

    {:ok, before_row} = ETS.get_session(new_id)
    created_before = before_row.created_at

    {:ok, msgs} = Session.resume(new_id, store: :ets)

    {:ok, pid2} =
      Session.start_link(
        provider: :mock,
        mock: [responder: single_text("ack")],
        tools: [],
        memory: false,
        store: :ets,
        session_id: new_id,
        messages: msgs
      )

    Session.stop(pid2)

    {:ok, after_row} = ETS.get_session(new_id)
    assert after_row.parent_id == sid
    assert after_row.title == "branch a"
    assert after_row.created_at == created_before
  end

  test "forked messages have independent monotonic seqs" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "first")
    {:ok, _} = Session.send_message(pid, "second")
    Session.stop(pid)

    {:ok, %{session_id: new_id}} = Session.fork(sid, store: :ets)

    {:ok, fork_msgs} = ETS.list_messages(new_id)
    seqs = fork_msgs |> Enum.sort_by(& &1.seq) |> Enum.map(& &1.seq)

    assert seqs == Enum.sort(seqs)
    Enum.each(fork_msgs, fn msg -> assert msg.session_id == new_id end)
  end

  test "copy_snapshots: true rewrites snapshot message_ids to the new session" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "first")
    Session.stop(pid)

    {:ok, messages} = ETS.list_messages(sid)
    first_msg = messages |> Enum.sort_by(& &1.seq) |> hd()
    {:ok, snap} = Session.checkpoint(sid, store: :ets, message_id: first_msg.id)

    {:ok, %{session_id: new_id}} =
      Session.fork(sid, store: :ets, copy_snapshots: true)

    {:ok, new_snaps} = ETS.list_snapshots(new_id)
    assert length(new_snaps) == 1

    new_snap = hd(new_snaps)
    assert new_snap.id != snap.id

    {:ok, new_msgs} = ETS.list_messages(new_id)
    new_msg_ids = MapSet.new(new_msgs, & &1.id)
    assert MapSet.member?(new_msg_ids, new_snap.message_id)
  end

  test "emits [:ex_athena, :session, :fork] telemetry" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "hello")
    Session.stop(pid)

    ref = :telemetry_test.attach_event_handlers(self(), [[:ex_athena, :session, :fork]])

    {:ok, %{session_id: new_id}} = Session.fork(sid, store: :ets)

    assert_receive {[:ex_athena, :session, :fork], ^ref, %{message_count: 2},
                    %{session_id: ^new_id, parent_id: ^sid, store: _, anchor_message_id: _}}

    :telemetry.detach(ref)
  end

  test "resume after fork returns forked messages in order" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "first")
    {:ok, _} = Session.send_message(pid, "second")
    Session.stop(pid)

    {:ok, messages} = ETS.list_messages(sid)
    second_msg = messages |> Enum.sort_by(& &1.seq) |> Enum.at(1)

    {:ok, %{session_id: new_id}} =
      Session.fork(sid, store: :ets, message_id: second_msg.id)

    assert {:ok, msgs} = Session.resume(new_id, store: :ets)
    assert length(msgs) == 2
    assert hd(msgs).content == "first"
  end

  test "unknown source session returns {:error, :not_found}" do
    assert {:error, :not_found} = Session.fork("nope", store: :ets)
  end

  test "unsupported store returns {:error, :unsupported_store} and emits no telemetry" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:ex_athena, :session, :fork]])

    assert {:error, :unsupported_store} = Session.fork("any-id", store: :jsonl)

    refute_receive {[:ex_athena, :session, :fork], _, _, _}

    :telemetry.detach(ref)
  end
end
