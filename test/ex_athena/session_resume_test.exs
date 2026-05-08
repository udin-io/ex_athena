defmodule ExAthena.SessionResumeTest do
  @moduledoc """
  Tests for `Session.resume/2` covering:
    - event-log path (InMemory, backwards compatibility)
    - SchemaStore path (ETS dual-write + read)
    - :as option variants (:messages, :state, :map)
    - :replay_last_user_turn trimming
    - start_link(messages: ...) seeding
    - BEAM-restart simulation via Jsonl → ETS migrate
    - telemetry emission
  """
  use ExUnit.Case, async: false

  alias ExAthena.{Loop, Response, Session}
  alias ExAthena.Sessions.Stores.{ETS, InMemory, Jsonl}

  setup do
    InMemory.reset()
    :ok
  end

  defp single_text(text) do
    fn _req -> %Response{text: text, finish_reason: :stop, provider: :mock} end
  end

  # ── Backwards-compatible event-log tests (InMemory) ────────────────

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

  # ── SchemaStore path (ETS) ─────────────────────────────────────────

  describe "ETS-backed SchemaStore resume" do
    setup do
      case GenServer.whereis(ETS) do
        nil -> start_supervised!(ETS)
        _pid -> :ok
      end

      ETS.reset()
      :ok
    end

    test "Session dual-writes to SchemaStore when store implements it" do
      {:ok, pid} =
        Session.start_link(
          provider: :mock,
          mock: [responder: single_text("ack")],
          tools: [],
          memory: false,
          store: :ets
        )

      sid = Session.session_id(pid)
      {:ok, _} = Session.send_message(pid, "first")
      {:ok, _} = Session.send_message(pid, "second")
      Session.stop(pid)

      assert {:ok, rows} = ETS.list_messages(sid)
      assert length(rows) == 4
    end

    test "Session.resume reads from SchemaStore when available" do
      {:ok, pid} =
        Session.start_link(
          provider: :mock,
          mock: [responder: single_text("ack")],
          tools: [],
          memory: false,
          store: :ets
        )

      sid = Session.session_id(pid)
      {:ok, _} = Session.send_message(pid, "first")
      {:ok, _} = Session.send_message(pid, "second")
      Session.stop(pid)

      assert {:ok, messages} = Session.resume(sid, store: :ets)
      assert Enum.map(messages, & &1.role) == [:user, :assistant, :user, :assistant]
      assert hd(messages).content == "first"
    end

    test "Session.resume(as: :state) returns a Loop.State" do
      {:ok, pid} =
        Session.start_link(
          provider: :mock,
          mock: [responder: single_text("ack")],
          tools: [],
          memory: false,
          store: :ets
        )

      sid = Session.session_id(pid)
      {:ok, _} = Session.send_message(pid, "first")
      {:ok, _} = Session.send_message(pid, "second")
      Session.stop(pid)

      assert {:ok, %Loop.State{messages: messages, session_id: ^sid}} =
               Session.resume(sid, store: :ets, as: :state)

      assert length(messages) == 4
    end

    test "Session.resume(as: :map) returns a plain map" do
      {:ok, pid} =
        Session.start_link(
          provider: :mock,
          mock: [responder: single_text("ack")],
          tools: [],
          memory: false,
          store: :ets
        )

      sid = Session.session_id(pid)
      {:ok, _} = Session.send_message(pid, "hello")
      Session.stop(pid)

      assert {:ok, payload} = Session.resume(sid, store: :ets, as: :map)
      assert is_map(payload)
      assert payload.session_id == sid
      assert is_list(payload.messages)
      assert length(payload.messages) == 2
    end

    test "replay_last_user_turn: true trims trailing assistant" do
      {:ok, pid} =
        Session.start_link(
          provider: :mock,
          mock: [responder: single_text("ack")],
          tools: [],
          memory: false,
          store: :ets
        )

      sid = Session.session_id(pid)
      {:ok, _} = Session.send_message(pid, "first")
      {:ok, _} = Session.send_message(pid, "second")
      Session.stop(pid)

      assert {:ok, msgs} = Session.resume(sid, store: :ets, replay_last_user_turn: true)
      assert List.last(msgs).role == :user
      assert List.last(msgs).content == "second"
    end

    test "resume → start_link(messages: ...) preserves history on next turn" do
      {:ok, pid} =
        Session.start_link(
          provider: :mock,
          mock: [responder: single_text("ack")],
          tools: [],
          memory: false,
          store: :ets
        )

      sid = Session.session_id(pid)
      {:ok, _} = Session.send_message(pid, "first")
      {:ok, _} = Session.send_message(pid, "second")
      Session.stop(pid)

      {:ok, msgs} = Session.resume(sid, store: :ets)

      {:ok, pid2} =
        Session.start_link(
          provider: :mock,
          mock: [responder: single_text("ok")],
          tools: [],
          memory: false,
          store: :ets,
          session_id: sid,
          messages: msgs
        )

      {:ok, result} = Session.send_message(pid2, "third")
      roles = Enum.map(result.messages, & &1.role)
      assert Enum.take(roles, 5) == [:user, :assistant, :user, :assistant, :user]
    end

    test "emits [:ex_athena, :session, :resume] telemetry" do
      {:ok, pid} =
        Session.start_link(
          provider: :mock,
          mock: [responder: single_text("ack")],
          tools: [],
          memory: false,
          store: :ets
        )

      sid = Session.session_id(pid)
      {:ok, _} = Session.send_message(pid, "hello")
      Session.stop(pid)

      ref = :telemetry_test.attach_event_handlers(self(), [[:ex_athena, :session, :resume]])

      {:ok, _} = Session.resume(sid, store: :ets)

      assert_receive {[:ex_athena, :session, :resume], ^ref, %{message_count: 2},
                      %{session_id: ^sid, source: :schema_store}}

      :telemetry.detach(ref)
    end
  end

  # ── BEAM-restart simulation ────────────────────────────────────────

  describe "BEAM-restart simulation via Jsonl → ETS migrate" do
    setup do
      case GenServer.whereis(ETS) do
        nil -> start_supervised!(ETS)
        _pid -> :ok
      end

      ETS.reset()
      :ok
    end

    @tag :tmp_dir
    test "resume after BEAM restart (Jsonl → ETS migrate)", %{tmp_dir: tmp} do
      {:ok, _} = start_supervised({Jsonl, root: tmp, flush_interval_ms: 50_000})

      {:ok, pid} =
        Session.start_link(
          provider: :mock,
          mock: [responder: single_text("ack")],
          tools: [],
          memory: false,
          store: :jsonl
        )

      sid = Session.session_id(pid)
      {:ok, _} = Session.send_message(pid, "before crash")
      :ok = Jsonl.flush()
      Session.stop(pid)

      # Simulate BEAM restart: wipe ETS, replay JSONL.
      ETS.reset()
      {:ok, _} = ETS.migrate_jsonl(root: tmp)

      assert {:ok, msgs} = Session.resume(sid, store: :ets)

      assert Enum.map(msgs, &{&1.role, &1.content}) == [
               {:user, "before crash"},
               {:assistant, "ack"}
             ]
    end
  end
end
