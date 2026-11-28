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

  describe "a level picked while the chat runs (issue 333)" do
    setup %{conn: conn} do
      start_supervised!({Registry, keys: :unique, name: ExAthena.Web.RunRegistry})

      start_supervised!(
        {DynamicSupervisor, name: ExAthena.Web.RunSupervisor, strategy: :one_for_one}
      )

      dir = Path.join(System.tmp_dir!(), "web_live_perm_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, view, _html} = live(conn, "/")
      {:ok, dir: dir, view: view}
    end

    # A run at `level` that holds before its first step until the test sends
    # `:go`, then runs one command and finishes.
    defp paused_run(sid, level, dir) do
      test_pid = self()
      counter = :counters.new(1, [:atomics])

      responder = fn _request ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            send(test_pid, {:paused, sid, self()})
            receive do: (:go -> :ok)

            %Response{
              text: "",
              tool_calls: [
                %ToolCall{id: "b1", name: "bash", arguments: %{"command" => "touch one.txt"}}
              ],
              finish_reason: :tool_calls,
              provider: :mock
            }

          _ ->
            %Response{text: "Done.", finish_reason: :stop, provider: :mock}
        end
      end

      {:ok, _} =
        RunServer.start_run(sid, %{
          run_opts: [
            provider: :mock,
            mock: [responder: responder],
            messages: [Messages.user("make one.txt")],
            cwd: dir,
            tools: [ExAthena.Tools.Bash],
            memory: false
          ],
          assistant_msg_id: "amsg",
          run_sid: "#{sid}-run",
          subscriber: self(),
          permission: level
        })

      assert_receive {:paused, ^sid, task}, 2_000
      task
    end

    # The state start_agent_run leaves: this session, a run going.
    defp bind(view, sid, level) do
      :sys.replace_state(view.pid, fn st ->
        socket =
          Phoenix.Component.assign(st.socket,
            session_id: sid,
            streaming: true,
            permission: Atom.to_string(level)
          )

        %{st | socket: socket}
      end)
    end

    defp pick(view, level),
      do: view |> form("#permission-form", %{"value" => level}) |> render_change()

    test "Trusted picked mid-run lets the next command run without asking",
         %{view: view, dir: dir} do
      sid = "live-up-#{System.unique_integer([:positive])}"
      task = paused_run(sid, :ask, dir)
      bind(view, sid, :ask)

      pick(view, "trusted")
      send(task, :go)

      assert_receive {:athena_done, _}, 2_000
      refute_received {:athena_ask_user, _}
      assert File.exists?(Path.join(dir, "one.txt"))
    end

    test "Ask picked mid-run makes the next command ask", %{view: view, dir: dir} do
      sid = "live-down-#{System.unique_integer([:positive])}"
      task = paused_run(sid, :trusted, dir)
      bind(view, sid, :trusted)

      pick(view, "ask")
      send(task, :go)

      assert_receive {:athena_ask_user, %{question: "Run this command?\n\ntouch one.txt"} = q},
                     2_000

      RunServer.answer(sid, q.tool_call_id, "Deny")
      assert_receive {:athena_done, _}, 2_000
      refute File.exists?(Path.join(dir, "one.txt"))
    end

    test "the picker moves only its own chat's run", %{view: view, dir: dir} do
      other = "live-other-#{System.unique_integer([:positive])}"
      task = paused_run(other, :ask, dir)
      bind(view, "live-mine-#{System.unique_integer([:positive])}", :ask)

      pick(view, "trusted")
      send(task, :go)

      assert_receive {:athena_ask_user, %{question: "Run this command?\n\ntouch one.txt"} = q},
                     2_000

      RunServer.answer(other, q.tool_call_id, "Deny")
      assert_receive {:athena_done, _}, 2_000
    end
  end
end
