defmodule ExAthena.Tools.SpawnAgentChatRecordTest do
  @moduledoc """
  A helper's transcript is a saved chat of its own, linked to the parent chat
  and to the step that started it (issue 360).
  """
  # Not async: the chat folder comes from app config.
  use ExUnit.Case, async: false

  alias ExAthena.{Chats, Loop, Response}
  alias ExAthena.Messages.ToolCall

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.get_env(:ex_athena, :chats_dir)
    Application.put_env(:ex_athena, :chats_dir, Path.join(tmp, "chats"))
    on_exit(fn -> Application.put_env(:ex_athena, :chats_dir, previous) end)
    parent = Path.join(tmp, "parent")
    File.mkdir_p!(parent)
    {:ok, parent: parent}
  end

  defp parent_responder do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "delegating",
            tool_calls: [
              %ToolCall{
                id: "spawn-1",
                name: "spawn_agent",
                arguments: %{"prompt" => "find every login route"}
              }
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end
  end

  defp run(parent, session_id) do
    Loop.run("add rate limiting",
      provider: :mock,
      mock: [responder: parent_responder()],
      tools: [ExAthena.Tools.SpawnAgent],
      cwd: parent,
      memory: false,
      session_id: session_id,
      assigns: %{
        spawn_agent_opts: [
          cwd: parent,
          provider: :mock,
          mock: [
            responder: fn _ ->
              %Response{text: "routes: /login, /session", finish_reason: :stop, provider: :mock}
            end
          ],
          tools: [],
          memory: false,
          summarise_reports: false
        ]
      },
      max_iterations: 5
    )
  end

  test "the helper's chat names its parent and the step that started it", %{parent: parent} do
    {:ok, _} = Chats.create(%{id: "parentchat01", cwd: parent})
    assert {:ok, _} = run(parent, "parentchat01")

    assert [helper] = Enum.filter(Chats.list(helpers: true), & &1[:parent])
    assert helper.parent == %{chat: "parentchat01", step: "spawn-1"}
    assert helper.title =~ "find every login route"

    assert {:ok, %{messages: messages}} = Chats.load(helper.id)
    assert Enum.any?(messages, &(&1.role == :assistant and &1.content =~ "/login"))
    # A helper stays out of the chat list front ends show.
    assert [%{id: "parentchat01"}] = Chats.list()
  end

  test "a run with no chat id to link to writes no helper chat", %{parent: parent} do
    assert {:ok, _} = run(parent, "not a chat id")
    assert Chats.list(helpers: true) == []
  end

  test "a run whose session is not a saved chat writes no helper chat", %{parent: parent} do
    assert {:ok, _} = run(parent, "nosuchchat01")
    assert Chats.list(helpers: true) == []
  end
end
