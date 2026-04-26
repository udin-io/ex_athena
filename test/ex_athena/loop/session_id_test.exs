defmodule ExAthena.Loop.SessionIdTest do
  @moduledoc """
  PR0 — verifies that `:session_id` and `:parent_session_id` flow through
  `Loop.run/2`, the resulting `ToolContext`, and lifecycle hooks. PR4 + PR5
  read these fields on hot paths, so the plumbing has to be solid before
  later PRs land.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Session}

  defp single_text_response do
    fn _request ->
      %Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
    end
  end

  describe "Loop.run/2" do
    test "auto-generates a session_id when the caller didn't pass one" do
      ref = make_ref()
      parent = self()

      hooks = %{
        SessionStart: [
          fn input, _id ->
            send(parent, {ref, :session_start, input})
            :ok
          end
        ]
      }

      {:ok, _} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: single_text_response()],
          tools: [],
          hooks: hooks
        )

      assert_receive {^ref, :session_start, %{session_id: id, parent_session_id: nil}}
      assert is_binary(id)
      # Strong-rand 16 bytes -> 22-char Base64URL without padding.
      assert byte_size(id) >= 20
    end

    test "uses the supplied :session_id verbatim and threads parent through" do
      ref = make_ref()
      parent = self()

      hooks = %{
        SessionStart: [
          fn input, _id ->
            send(parent, {ref, :session_start, input})
            :ok
          end
        ]
      }

      {:ok, _} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: single_text_response()],
          tools: [],
          hooks: hooks,
          session_id: "fixed-session",
          parent_session_id: "outer-session"
        )

      assert_receive {^ref, :session_start,
                      %{session_id: "fixed-session", parent_session_id: "outer-session"}}
    end
  end

  describe "Session" do
    test "auto-generates a session_id and reuses it across turns" do
      {:ok, pid} =
        Session.start_link(
          provider: :mock,
          mock: [responder: single_text_response()],
          tools: []
        )

      sid = Session.session_id(pid)
      assert is_binary(sid)

      ref = make_ref()
      parent = self()

      hooks = %{
        SessionStart: [
          fn input, _id ->
            send(parent, {ref, input.session_id})
            :ok
          end
        ]
      }

      {:ok, _} = Session.send_message(pid, "first", hooks: hooks)
      assert_receive {^ref, ^sid}

      {:ok, _} = Session.send_message(pid, "second", hooks: hooks)
      assert_receive {^ref, ^sid}

      Session.stop(pid)
    end

    test "honours an explicit :session_id at start_link" do
      {:ok, pid} =
        Session.start_link(
          provider: :mock,
          mock: [responder: single_text_response()],
          tools: [],
          session_id: "my-session"
        )

      assert Session.session_id(pid) == "my-session"
      Session.stop(pid)
    end

    test "ignores per-call :session_id in extra_opts (cannot drift mid-conversation)" do
      {:ok, pid} =
        Session.start_link(
          provider: :mock,
          mock: [responder: single_text_response()],
          tools: [],
          session_id: "stable"
        )

      ref = make_ref()
      parent = self()

      hooks = %{
        SessionStart: [
          fn input, _id ->
            send(parent, {ref, input.session_id})
            :ok
          end
        ]
      }

      {:ok, _} = Session.send_message(pid, "hi", hooks: hooks, session_id: "drifted")
      assert_receive {^ref, "stable"}

      Session.stop(pid)
    end
  end
end
