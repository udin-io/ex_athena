defmodule ExAthena.Web.Live.ChatLivePermissionTest do
  @moduledoc """
  The web chat's picker sets how much the chat may do, in place of the four
  chat modes (issue 322), and its approvals reach the person as the question
  card.
  """
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias ExAthena.Messages
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Response
  alias ExAthena.Web.{Endpoint, RunServer}
  alias ExAthena.Web.Live.ChatLive

  @endpoint Endpoint

  setup do
    case start_supervised(Endpoint) do
      {:ok, _pid} -> :ok
      {:error, {{:already_started, _pid}, _}} -> :ok
    end

    %{conn: Phoenix.ConnTest.build_conn()}
  end

  describe "the picker" do
    test "offers the four levels, with Ask before edits picked", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      for label <- ["Read only (plan)", "Ask before edits", "Edit freely", "Trusted"] do
        assert html =~ label
      end

      refute html =~ "Reflexion"
      refute html =~ "Orchestrate"
      assert has_element?(view, ~s(#permission-select option[value="ask"][selected]))
    end

    test "picking a level through the form keeps it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> form("#permission-form", %{"value" => "read_only"}) |> render_change()

      assert has_element?(view, ~s(#permission-select option[value="read_only"][selected]))
    end

    test "a value the page never offers falls back to the default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_change(view, "set_permission", %{"value" => "orchestrate"})
      assert has_element?(view, ~s(#permission-select option[value="ask"][selected]))

      render_change(view, "set_permission", %{"value" => %{"nested" => "map"}})
      assert Process.alive?(view.pid)
      assert has_element?(view, ~s(#permission-select option[value="ask"][selected]))
    end
  end

  describe "a plan approval" do
    test "moves the picker to the level the plan was approved at", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view |> form("#permission-form", %{"value" => "read_only"}) |> render_change()

      send(
        view.pid,
        {:athena_ask_user,
         %{
           tool_call_id: "approval-1",
           kind: :plan_approval,
           question: "The chat's plan:\n\n1. Write a.txt\n\nGo ahead?",
           options: ["Yes, and ask before each edit", "Yes, and edit freely", "No, keep planning"]
         }}
      )

      assert render(view) =~ "1. Write a.txt"

      view
      |> element(~s(button.ask-user-option[phx-value-option="Yes, and edit freely"]))
      |> render_click()

      assert has_element?(view, ~s(#permission-select option[value="edit"][selected]))
    end

    test "a question the model wrote with the same words moves nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view |> form("#permission-form", %{"value" => "read_only"}) |> render_change()

      send(
        view.pid,
        {:athena_ask_user,
         %{tool_call_id: "t1", question: "Shall I?", options: ["Yes, and edit freely"]}}
      )

      _ = render(view)

      view
      |> element(~s(button.ask-user-option[phx-value-option="Yes, and edit freely"]))
      |> render_click()

      assert has_element?(view, ~s(#permission-select option[value="read_only"][selected]))
    end

    test "keep planning leaves the picker where it was", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view |> form("#permission-form", %{"value" => "read_only"}) |> render_change()

      send(
        view.pid,
        {:athena_ask_user,
         %{tool_call_id: "approval-2", question: "Go ahead?", options: ["No, keep planning"]}}
      )

      _ = render(view)

      view
      |> element(~s(button.ask-user-option[phx-value-option="No, keep planning"]))
      |> render_click()

      assert has_element?(view, ~s(#permission-select option[value="read_only"][selected]))
    end
  end

  describe "saved chats" do
    test "a saved chat keeps its level" do
      payload =
        ChatLive.session_payload(%{
          session_id: "s1",
          session_title: "t",
          cwd: "/tmp",
          provider: "ollama",
          model: "m",
          permission: "edit",
          session_created_at: ~U[2026-11-27 10:00:00Z],
          messages: [],
          ex_messages: [],
          provider_session_id: nil,
          tool_uis: %{},
          details_stream: []
        })

      assert payload.permission == "edit"
    end
  end

  describe "approvals in a run" do
    setup do
      start_supervised!({Registry, keys: :unique, name: ExAthena.Web.RunRegistry})

      start_supervised!(
        {DynamicSupervisor, name: ExAthena.Web.RunSupervisor, strategy: :one_for_one}
      )

      dir = Path.join(System.tmp_dir!(), "web_perm_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    defp scripted(responses) do
      counter = :counters.new(1, [:atomics])

      fn _request ->
        :counters.add(counter, 1, 1)
        Enum.at(responses, :counters.get(counter, 1) - 1) || List.last(responses)
      end
    end

    defp start(sid, level, dir) do
      write = %Response{
        text: "",
        tool_calls: [
          %ToolCall{id: "w1", name: "write", arguments: %{"path" => "a.txt", "content" => "hi"}}
        ],
        finish_reason: :tool_calls,
        provider: :mock
      }

      done = %Response{text: "Done.", finish_reason: :stop, provider: :mock}

      {:ok, _} =
        RunServer.start_run(sid, %{
          run_opts: [
            provider: :mock,
            mock: [responder: scripted([write, done])],
            messages: [Messages.user("write a.txt")],
            cwd: dir,
            tools: [ExAthena.Tools.Write],
            memory: false
          ],
          assistant_msg_id: "amsg",
          run_sid: "#{sid}-run",
          subscriber: self(),
          permission: level
        })
    end

    test "Ask before edits shows the edit as a question, and a denied edit never runs",
         %{dir: dir} do
      start("s-ask-#{System.unique_integer([:positive])}", :ask, dir)

      assert_receive {:athena_ask_user,
                      %{question: "Change a.txt?", options: ["Allow", "Deny"]} = q},
                     2_000

      send(q.reply_to, {:athena_user_answer, q.tool_call_id, "Deny"})
      assert_receive {:athena_done, _}, 2_000
      refute File.exists?(Path.join(dir, "a.txt"))
    end

    test "an allowed edit runs", %{dir: dir} do
      sid = "s-allow-#{System.unique_integer([:positive])}"
      start(sid, :ask, dir)

      assert_receive {:athena_ask_user, %{tool_call_id: id}}, 2_000
      RunServer.answer(sid, id, "Allow")

      assert_receive {:athena_done, _}, 2_000
      assert File.exists?(Path.join(dir, "a.txt"))
    end

    test "Edit freely asks nothing for an edit", %{dir: dir} do
      start("s-edit-#{System.unique_integer([:positive])}", :edit, dir)

      assert_receive {:athena_done, _}, 2_000
      refute_received {:athena_ask_user, _}
      assert File.exists?(Path.join(dir, "a.txt"))
    end
  end
end
