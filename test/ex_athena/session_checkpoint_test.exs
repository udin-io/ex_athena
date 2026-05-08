defmodule ExAthena.SessionCheckpointTest do
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

  test "checkpoint anchors to last message by default" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "first")
    {:ok, _} = Session.send_message(pid, "second")
    Session.stop(pid)

    {:ok, messages} = ETS.list_messages(sid)
    last_msg = messages |> Enum.sort_by(& &1.seq) |> List.last()

    assert {:ok, snap} = Session.checkpoint(sid, store: :ets)
    assert snap.message_id == last_msg.id
    assert is_binary(snap.id)
  end

  test "checkpoint anchors to explicit message_id" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "first")
    {:ok, _} = Session.send_message(pid, "second")
    Session.stop(pid)

    {:ok, messages} = ETS.list_messages(sid)
    first_msg = messages |> Enum.sort_by(& &1.seq) |> hd()

    assert {:ok, snap} = Session.checkpoint(sid, store: :ets, message_id: first_msg.id)
    assert snap.message_id == first_msg.id
    assert snap.state.anchor_seq == first_msg.seq
  end

  test "checkpoint is idempotent under repeat calls with no opts" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "hello")
    Session.stop(pid)

    assert {:ok, snap1} = Session.checkpoint(sid, store: :ets)
    assert {:ok, snap2} = Session.checkpoint(sid, store: :ets)

    assert snap1.id == snap2.id

    {:ok, snapshots} = ETS.list_snapshots(sid)
    assert length(snapshots) == 1
  end

  test "distinct labels create distinct snapshots for same anchor" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "hello")
    Session.stop(pid)

    assert {:ok, snap_a} = Session.checkpoint(sid, store: :ets, label: "a")
    assert {:ok, snap_b} = Session.checkpoint(sid, store: :ets, label: "b")

    assert snap_a.id != snap_b.id

    {:ok, snapshots} = ETS.list_snapshots(sid)
    assert length(snapshots) == 2
  end

  test "emits telemetry with idempotent: false on first call, true on repeat" do
    {pid, sid} = start_session()
    {:ok, _} = Session.send_message(pid, "hello")
    Session.stop(pid)

    ref = :telemetry_test.attach_event_handlers(self(), [[:ex_athena, :session, :checkpoint]])

    assert {:ok, snap} = Session.checkpoint(sid, store: :ets)
    snap_id = snap.id

    assert_receive {[:ex_athena, :session, :checkpoint], ^ref, %{message_count: 2},
                    %{session_id: ^sid, snapshot_id: ^snap_id, idempotent: false}}

    assert {:ok, _} = Session.checkpoint(sid, store: :ets)

    assert_receive {[:ex_athena, :session, :checkpoint], ^ref, %{message_count: 2},
                    %{session_id: ^sid, snapshot_id: ^snap_id, idempotent: true}}

    :telemetry.detach(ref)
  end

  test "empty session returns {:error, :no_messages}" do
    {:ok, pid} =
      Session.start_link(
        provider: :mock,
        mock: [responder: single_text("ack")],
        tools: [],
        memory: false,
        store: :ets
      )

    sid = Session.session_id(pid)
    Session.stop(pid)

    assert {:error, :no_messages} = Session.checkpoint(sid, store: :ets)
  end

  test "unsupported store returns {:error, :unsupported_store} and emits no telemetry" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:ex_athena, :session, :checkpoint]])

    assert {:error, :unsupported_store} = Session.checkpoint("any-id", store: :in_memory)

    refute_receive {[:ex_athena, :session, :checkpoint], _, _, _}

    :telemetry.detach(ref)
  end
end
