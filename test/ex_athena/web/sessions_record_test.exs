defmodule ExAthena.Web.SessionsRecordTest do
  @moduledoc "The web UI keeps its chats in the shared chat record (issue 359)."
  # Not async: the chat folder and the web folder come from app config.
  use ExUnit.Case, async: false

  alias ExAthena.Chat.Session
  alias ExAthena.Chats
  alias ExAthena.Messages
  alias ExAthena.Messages.{Message, ToolCall, ToolResult}
  alias ExAthena.Result
  alias ExAthena.Web.Sessions

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    chats = Application.get_env(:ex_athena, :chats_dir)
    web = Application.get_env(:ex_athena, :web_dir)
    Application.put_env(:ex_athena, :chats_dir, Path.join(tmp, "chats"))
    Application.put_env(:ex_athena, :web_dir, Path.join(tmp, "web"))

    on_exit(fn ->
      Application.put_env(:ex_athena, :chats_dir, chats)
      Application.put_env(:ex_athena, :web_dir, web)
    end)

    {:ok, cwd: tmp, web: Path.join(tmp, "web")}
  end

  defp ex_turn do
    [
      Messages.user("add rate limiting"),
      Messages.assistant(nil, [
        %ToolCall{id: "c1", name: "read", arguments: %{"path" => "lib/auth.ex"}}
      ]),
      %Message{
        role: :tool,
        tool_results: [%ToolResult{tool_call_id: "c1", content: "212 lines"}]
      },
      Messages.assistant("Done: lib/auth.ex")
    ]
  end

  defp web_payload(cwd, id \\ "abc123def456") do
    ex = ex_turn()

    %{
      id: id,
      title: "add rate limiting",
      cwd: cwd,
      provider: "ollama",
      model: "qwen",
      permission: :edit,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now(),
      display_messages: [
        %{
          id: "u1",
          role: :user,
          text: "add rate limiting",
          images: [],
          tool_events: [],
          status: nil
        },
        %{
          id: "a1",
          role: :assistant,
          text: "Done: lib/auth.ex",
          tool_events: [],
          status: nil,
          ex_snapshot: ex
        }
      ],
      ex_messages: ex,
      provider_session_id: nil,
      tool_uis: %{"c1" => %{kind: :file}},
      details_stream: [%{id: "d1", type: :user_text, message_id: "u1", payload: %{text: "x"}}],
      orchestrator: nil
    }
  end

  test "a web save writes the shared record", %{cwd: cwd} do
    :ok = Sessions.save(web_payload(cwd))

    assert {:ok, chat} = Chats.load("abc123def456")
    assert chat.messages == ex_turn()
    assert chat.title == "add rate limiting"
    assert chat.cwd == cwd
    assert chat.provider == :ollama
    assert chat.permission == :edit
  end

  test "the web UI's own view comes back while it matches the record", %{cwd: cwd} do
    :ok = Sessions.save(web_payload(cwd))

    assert {:ok, data} = Sessions.load("abc123def456")
    assert data.tool_uis == %{"c1" => %{kind: :file}}
    assert [%{id: "u1"}, %{id: "a1"}] = data.display_messages
  end

  test "a chat the terminal saved shows in the web list and opens there", %{cwd: cwd} do
    session = Session.new(provider: :ollama, model: "qwen", permission: :edit, cwd: cwd)
    session = Session.append_user(session, "from the terminal")

    session =
      Session.apply_result(session, %Result{
        messages: session.messages ++ [Messages.assistant("hi there")]
      })

    {:ok, saved} = Session.save(session)

    assert [%{id: id, title: "from the terminal", provider: "ollama", cwd: ^cwd}] =
             Sessions.list()

    assert id == saved.chat_id

    assert {:ok, data} = Sessions.load(id)

    assert [
             %{role: :user, text: "from the terminal"},
             %{role: :assistant, text: "hi there"} = reply
           ] =
             data.display_messages

    assert reply.ex_snapshot == session.messages
    assert data.ex_messages == session.messages
    assert data.provider == "ollama"
    assert data.details_stream == []
  end

  test "a turn added in the terminal shows when the web UI opens the chat again", %{cwd: cwd} do
    :ok = Sessions.save(web_payload(cwd))
    more = ex_turn() ++ [Messages.user("now tests"), Messages.assistant("added")]
    :ok = Chats.sync("abc123def456", more)

    assert {:ok, data} = Sessions.load("abc123def456")
    assert data.ex_messages == more
    assert List.last(data.display_messages).text == "added"
    # The turns the web UI drew keep their panels and details.
    assert data.tool_uis == %{"c1" => %{kind: :file}}
    assert [%{id: "d1"}] = data.details_stream
    assert [%{id: "u1"}, %{id: "a1"} | _] = data.display_messages
  end

  test "a title or model changed elsewhere wins over the web's copy", %{cwd: cwd} do
    :ok = Sessions.save(web_payload(cwd))
    :ok = Chats.update("abc123def456", %{title: "renamed", model: "llama"})

    assert {:ok, %{title: "renamed", model: "llama"}} = Sessions.load("abc123def456")
  end

  test "an old saved chat moves to the record at start", %{cwd: cwd, web: web} do
    legacy = Map.delete(web_payload(cwd, "0123456789ab"), :record)
    dir = Path.join(web, "sessions")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "0123456789ab.session"), :erlang.term_to_binary(legacy))

    old = ~U[2025-01-01 00:00:00Z]

    File.write!(
      Path.join(dir, "0123456789ab.session"),
      :erlang.term_to_binary(%{legacy | updated_at: old})
    )

    assert Sessions.migrate!() == 1
    assert [%{updated_at: ^old}] = Sessions.list()
    assert {:ok, %{messages: messages, title: "add rate limiting"}} = Chats.load("0123456789ab")
    assert messages == ex_turn()
    assert [%{id: "0123456789ab"}] = Sessions.list()
    assert Sessions.migrate!() == 0
    assert Bitwise.band(File.stat!(Chats.path("0123456789ab")).mode, 0o777) == 0o600
  end

  test "a chat the cleanup removed does not come back from the web's copy", %{cwd: cwd, web: web} do
    :ok = Sessions.save(web_payload(cwd))
    :ok = Chats.delete("abc123def456")

    assert {:error, _} = Sessions.load("abc123def456")
    refute File.exists?(Path.join([web, "sessions", "abc123def456.session"]))
    assert Sessions.migrate!() == 0
  end

  test "deleting a chat removes the record and the web's copy", %{cwd: cwd, web: web} do
    {:ok, _} = Chats.create(%{id: "abc123def456", cwd: cwd})
    :ok = Chats.sync("abc123def456", ex_turn())
    File.mkdir_p!(Path.join(web, "sessions"))

    File.write!(
      Path.join([web, "sessions", "abc123def456.session"]),
      :erlang.term_to_binary(web_payload(cwd))
    )

    Sessions.delete("abc123def456")

    assert {:error, :not_found} = Chats.load("abc123def456")
    refute File.exists?(Path.join([web, "sessions", "abc123def456.session"]))
    assert Sessions.list() == []
  end

  test "an id from the address bar that could name another path opens nothing" do
    assert {:error, :invalid_id} = Sessions.load("../../etc/passwd")
  end

  describe "the chat page" do
    alias ExAthena.Web.Live.ChatLive

    setup do
      case start_supervised(ExAthena.Web.Endpoint) do
        {:ok, _} -> :ok
        {:error, {{:already_started, _}, _}} -> :ok
      end

      :ok
    end

    defp opened(id) do
      {:ok, socket} = ChatLive.mount(%{}, nil, %Phoenix.LiveView.Socket{})
      {:noreply, socket} = ChatLive.handle_event("load_session", %{"id" => id}, socket)
      socket
    end

    test "fork copies the chat in the record and names the chat it came from", %{cwd: cwd} do
      :ok = Sessions.save(web_payload(cwd))
      socket = opened("abc123def456")

      {:noreply, socket} = ChatLive.handle_event("fork_at", %{"msg_id" => "a1"}, socket)

      new_id = socket.assigns.session_id
      assert new_id != "abc123def456"

      assert {:ok, %{forked_from: %{chat: "abc123def456"}, messages: messages}} =
               Chats.load(new_id)

      assert messages == ex_turn()
    end

    test "rewind goes back to a reply, in the record and on the page", %{cwd: cwd} do
      payload = web_payload(cwd)
      more = payload.ex_messages ++ [Messages.user("now tests"), Messages.assistant("added")]

      payload = %{
        payload
        | ex_messages: more,
          display_messages:
            payload.display_messages ++
              [
                %{
                  id: "u2",
                  role: :user,
                  text: "now tests",
                  images: [],
                  tool_events: [],
                  status: nil
                },
                %{
                  id: "a2",
                  role: :assistant,
                  text: "added",
                  tool_events: [],
                  status: nil,
                  ex_snapshot: more
                }
              ]
      }

      :ok = Sessions.save(payload)
      socket = opened("abc123def456")

      {:noreply, socket} = ChatLive.handle_event("rewind_to", %{"msg_id" => "a1"}, socket)

      assert [%{id: "u1"}, %{id: "a1"}] = socket.assigns.messages
      assert socket.assigns.ex_messages == ex_turn()
      assert {:ok, %{messages: messages}} = Chats.load("abc123def456")
      assert messages == ex_turn()
      assert socket.assigns.notice =~ "put back 0 file(s)"
    end

    test "rewind waits while another window runs a reply in the chat", %{cwd: cwd} do
      :ok = Sessions.save(web_payload(cwd))
      socket = opened("abc123def456")
      test_pid = self()

      holder =
        spawn(fn ->
          :ok = Chats.hold("abc123def456")
          send(test_pid, :held)
          receive do: (:stop -> :ok)
        end)

      on_exit(fn -> Process.exit(holder, :kill) end)
      assert_receive :held
      {:noreply, socket} = ChatLive.handle_event("rewind_to", %{"msg_id" => "a1"}, socket)
      assert socket.assigns.error =~ "Wait for the reply"
    end

    test "a page whose chat moved on elsewhere goes on as a new chat", %{cwd: cwd} do
      :ok = Sessions.save(web_payload(cwd))
      socket = opened("abc123def456")

      :ok =
        Chats.sync(
          "abc123def456",
          ex_turn() ++ [Messages.user("terminal"), Messages.assistant("t")]
        )

      assert {:moved, new_id} = Sessions.fork_if_moved(ChatLive.session_payload(socket.assigns))
      assert {:ok, %{forked_from: %{chat: "abc123def456"}, messages: mine}} = Chats.load(new_id)
      assert mine == ex_turn()
      assert {:ok, %{messages: theirs}} = Chats.load("abc123def456")
      assert List.last(theirs).content == "t"
    end

    test "a page with the current chat goes on in it", %{cwd: cwd} do
      :ok = Sessions.save(web_payload(cwd))
      socket = opened("abc123def456")
      assert :current = Sessions.fork_if_moved(ChatLive.session_payload(socket.assigns))
    end

    test "a message sent while the terminal runs a reply saves nothing", %{cwd: cwd} do
      :ok = Sessions.save(web_payload(cwd))
      socket = opened("abc123def456")
      test_pid = self()

      holder =
        spawn(fn ->
          :ok = Chats.hold("abc123def456")
          send(test_pid, :held)
          receive do: (:stop -> :ok)
        end)

      on_exit(fn -> Process.exit(holder, :kill) end)
      assert_receive :held

      {:noreply, socket} =
        ChatLive.handle_event("send", %{"text" => "web question"}, %{
          socket
          | assigns: Map.put(socket.assigns, :cwd, cwd)
        })

      assert socket.assigns.error =~ "Another window"
      assert {:ok, %{messages: messages}} = Chats.load("abc123def456")
      assert messages == ex_turn()
    end

    test "rewind on a page whose chat went on elsewhere is refused", %{cwd: cwd} do
      :ok = Sessions.save(web_payload(cwd))
      socket = opened("abc123def456")

      :ok =
        Chats.sync(
          "abc123def456",
          ex_turn() ++ [Messages.user("terminal"), Messages.assistant("t")]
        )

      {:noreply, socket} = ChatLive.handle_event("rewind_to", %{"msg_id" => "a1"}, socket)

      assert socket.assigns.error =~ "went on in another window"
      assert {:ok, %{messages: messages}} = Chats.load("abc123def456")
      assert length(messages) == 6
    end

    test "a page whose moved chat cannot be copied sends nothing and says so", %{cwd: cwd} do
      :ok = Sessions.save(web_payload(cwd))
      socket = opened("abc123def456")

      :ok =
        Chats.sync(
          "abc123def456",
          ex_turn() ++ [Messages.user("terminal"), Messages.assistant("t")]
        )

      Application.put_env(:ex_athena, :chats_create_guard, fn _attrs -> {:error, :disk_full} end)
      on_exit(fn -> Application.delete_env(:ex_athena, :chats_create_guard) end)

      socket = %{socket | assigns: Map.put(socket.assigns, :cwd, cwd)}
      {:noreply, socket} = ChatLive.handle_event("send", %{"text" => "web question"}, socket)

      assert socket.assigns.error =~ "could not be copied"
      assert socket.assigns.session_id == "abc123def456"
      assert {:ok, %{messages: messages}} = Chats.load("abc123def456")
      assert List.last(messages).content == "t"
    end
  end
end
