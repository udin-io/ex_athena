defmodule ExAthena.Web.Live.ChatLiveInboxTest do
  @moduledoc """
  A message typed while the web chat runs reaches the run (issue 323).
  """
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias ExAthena.Web.Endpoint

  @endpoint Endpoint

  setup do
    case start_supervised(Endpoint) do
      {:ok, _pid} -> :ok
      {:error, {{:already_started, _pid}, _}} -> :ok
    end

    start_supervised!({Registry, keys: :unique, name: ExAthena.Web.RunRegistry})

    start_supervised!(
      {DynamicSupervisor, name: ExAthena.Web.RunSupervisor, strategy: :one_for_one}
    )

    %{conn: Phoenix.ConnTest.build_conn()}
  end

  # A view that believes a run is going, for a run server this test holds.
  defp streaming_view(conn, sid) do
    test_pid = self()

    responder = fn _request ->
      send(test_pid, {:run_task, self()})

      receive do: (:finish ->
                     %ExAthena.Response{text: "ok", finish_reason: :stop, provider: :mock})
    end

    {:ok, _} =
      ExAthena.Web.RunServer.start_run(sid, %{
        run_opts: [provider: :mock, mock: [responder: responder], memory: false],
        assistant_msg_id: "amsg",
        run_sid: "#{sid}-run"
      })

    assert_receive {:run_task, task}, 2_000

    {:ok, view, _html} = live(conn, "/")

    # The state start_agent_run leaves: this session, a run going.
    :sys.replace_state(view.pid, fn st ->
      %{st | socket: Phoenix.Component.assign(st.socket, session_id: sid, streaming: true)}
    end)

    {view, task}
  end

  test "the composer stays open while the chat runs, and a message shows as waiting",
       %{conn: conn} do
    sid = "inbox-#{System.unique_integer([:positive])}"
    {view, task} = streaming_view(conn, sid)

    html = render_submit(view, "send", %{"text" => "skip the admin login"})

    assert html =~ "skip the admin login"
    assert html =~ "waiting for the chat to finish its step"

    send(view.pid, {:athena, {:user_message_taken, "skip the admin login"}})
    refute render(view) =~ "waiting for the chat to finish its step"

    send(task, :finish)
  end

  test "a message the run never took goes back to the composer", %{conn: conn} do
    sid = "inbox-#{System.unique_integer([:positive])}"
    {view, task} = streaming_view(conn, sid)

    render_submit(view, "send", %{"text" => "one more thing"})
    send(view.pid, {:athena_unsent, ["one more thing"]})

    assert_push_event(view, "restore-chat-input", %{text: "one more thing"})
    refute render(view) =~ "waiting for the chat to finish its step"

    send(task, :finish)
  end

  test "text typed while an approval waits is a message, never the answer", %{conn: conn} do
    sid = "inbox-#{System.unique_integer([:positive])}"
    {view, task} = streaming_view(conn, sid)

    send(
      view.pid,
      {:athena_ask_user,
       %{
         tool_call_id: "approval-1",
         kind: :approval,
         question: "Change a.txt?",
         options: ["Allow", "Deny"]
       }}
    )

    html = render_submit(view, "send", %{"text" => "Allow"})

    assert html =~ "Change a.txt?"
    assert html =~ "waiting for the chat to finish its step"

    send(task, :finish)
  end

  test "a saved chat never holds a message that is still waiting" do
    payload =
      ExAthena.Web.Live.ChatLive.session_payload(%{
        session_id: "s1",
        session_title: "t",
        cwd: "/tmp",
        provider: "ollama",
        model: "m",
        permission: "ask",
        session_created_at: ~U[2026-11-27 10:00:00Z],
        messages: [
          %{id: "a", role: :user, text: "sent", images: [], tool_events: [], status: nil},
          %{
            id: "b",
            role: :user,
            text: "queued",
            images: [],
            tool_events: [],
            status: nil,
            waiting: true
          }
        ],
        ex_messages: [],
        provider_session_id: nil,
        tool_uis: %{},
        details_stream: []
      })

    assert Enum.map(payload.display_messages, & &1.text) == ["sent"]
  end

  test "after a reconnect a waiting message shows, and a Stop takes it off the thread",
       %{conn: conn} do
    sid = "inbox-#{System.unique_integer([:positive])}"
    test_pid = self()

    responder = fn _request ->
      send(test_pid, {:run_task, self()})

      receive do: (:finish ->
                     %ExAthena.Response{text: "ok", finish_reason: :stop, provider: :mock})
    end

    {:ok, _} =
      ExAthena.Web.RunServer.start_run(sid, %{
        run_opts: [provider: :mock, mock: [responder: responder], memory: false],
        assistant_msg_id: "amsg",
        run_sid: "#{sid}-run"
      })

    assert_receive {:run_task, task}, 2_000
    :ok = ExAthena.Web.RunServer.push_message(sid, "sent before the reload")

    {:ok, view, html} = live(conn, "/c/#{sid}")
    assert html =~ "sent before the reload"

    send(view.pid, {:athena, {:user_message_taken, "sent before the reload"}})
    refute render(view) =~ "waiting for the chat to finish its step"

    send(view.pid, {:athena_unsent, ["sent before the reload"]})
    refute render(view) =~ "sent before the reload"

    send(task, :finish)
  end
end
