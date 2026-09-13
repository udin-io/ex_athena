defmodule ExAthena.Tools.SpawnAgentWriteRailTest do
  @moduledoc """
  Issue 217: refuse a write brief handed to a worker that cannot write.

  The acceptance criteria are all here, and the second one is the reason the
  rail sits where it does. `Quota.claim/1` runs inside `do_execute/5` and
  `ExAthena.Agents.Quota` has no release, so a refusal at the natural site —
  next to `resolve_tools/3`, which computes the toolset the rail reads —
  would permanently burn one of the run's 24 worker slots for a spawn that
  never ran. A model repeating a refused brief four times would silently lose
  four. So the rail runs in `execute/2`'s `cond`, beside the depth and
  completed-todo rails, and this file asserts the worker count directly:
  that is the part that is silent when it is wrong.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Agents.{Definition, Quota}
  alias ExAthena.{Response, ToolContext}
  alias ExAthena.Tools.SpawnAgent

  @write_brief "WRITE THE RESULT TO A FILE: `plan/uat_testing/guides-39-76-extract.md`\n" <>
                 "Extract every guide section between 39 and 76."

  setup do
    dir = Path.join(System.tmp_dir!(), "spawn_write_rail_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, assigns: Quota.install(%{})}
  end

  defp ctx(dir, assigns, extra \\ %{}) do
    base = %{
      spawn_agent_opts: [
        provider: :mock,
        mock: [
          responder: fn _req ->
            %Response{text: "worker report", finish_reason: :stop, provider: :mock}
          end
        ],
        memory: false
      ]
    }

    ToolContext.new(
      cwd: dir,
      session_id: "sess_#{System.unique_integer([:positive])}",
      assigns: assigns |> Map.merge(base) |> Map.merge(extra)
    )
  end

  defp explore_with(tools) do
    %{
      "explore" => %Definition{
        name: "explore",
        description: "read-only investigation",
        tools: tools,
        system_prompt: "You are a read-only research assistant."
      }
    }
  end

  test "a write brief to explore is refused, naming its tools and implementer", %{
    dir: dir,
    assigns: assigns
  } do
    assert {:error, message} =
             SpawnAgent.execute(
               %{"prompt" => @write_brief, "agent" => "explore"},
               ctx(dir, assigns)
             )

    assert message =~ "explore"
    assert message =~ "implementer"
    # The agent's ACTUAL tools, read off priv/agents/explore.md.
    assert message =~ "read, glob, grep, lsp, web_fetch, web_search, usage_rules"
    # The always-granted control tools are left out: `todo_write` writes no
    # file and reads as a contradiction in a sentence about writing files.
    refute message =~ "todo_write"
    # The phrase that tripped it, so the model can reword rather than guess.
    assert message =~ "WRITE THE RESULT TO A FILE"
  end

  test "a refused spawn does not consume a worker from the run's allowance", %{
    dir: dir,
    assigns: assigns
  } do
    for _ <- 1..4 do
      assert {:error, _} =
               SpawnAgent.execute(
                 %{"prompt" => @write_brief, "agent" => "explore"},
                 ctx(dir, assigns)
               )
    end

    assert Quota.spawned(assigns) == 0
  end

  test "an allowed spawn still claims its worker", %{dir: dir, assigns: assigns} do
    assert {:ok, _text, _ui} =
             SpawnAgent.execute(
               %{"prompt" => "explore the repo structure and report back", "agent" => "explore"},
               ctx(dir, assigns)
             )

    assert Quota.spawned(assigns) == 1
  end

  test "prose about writing is not a write brief", %{dir: dir, assigns: assigns} do
    assert {:ok, _text, _ui} =
             SpawnAgent.execute(
               %{
                 "prompt" => "read the config file and write up what you find",
                 "agent" => "explore"
               },
               ctx(dir, assigns)
             )
  end

  test "an explore the caller granted write to is not refused", %{dir: dir, assigns: assigns} do
    granted = explore_with(~w(read glob grep write))

    assert {:ok, _text, _ui} =
             SpawnAgent.execute(
               %{"prompt" => @write_brief, "agent" => "explore"},
               ctx(dir, assigns, %{agents: granted})
             )
  end

  # No agent means the full builtin ceiling, write included.
  test "a plain spawn with a write brief is not refused", %{dir: dir, assigns: assigns} do
    assert {:ok, _text, _ui} =
             SpawnAgent.execute(%{"prompt" => @write_brief}, ctx(dir, assigns))
  end

  # The rail reads the toolset, not the agent's name: a caller narrowing a
  # plain spawn to read-only tools gets the same refusal explore does.
  test "a spawn narrowed to read-only tools by its caller is refused", %{
    dir: dir,
    assigns: assigns
  } do
    assert {:error, message} =
             SpawnAgent.execute(
               %{"prompt" => @write_brief, "tools" => ["read", "grep"]},
               ctx(dir, assigns)
             )

    assert message =~ "implementer"
    assert Quota.spawned(assigns) == 0
  end

  # The brief is prompt + objective + expected_output, so an orchestrator that
  # puts the file demand in the deliverable field is caught too.
  test "the file demand is found in expected_output", %{dir: dir, assigns: assigns} do
    assert {:error, message} =
             SpawnAgent.execute(
               %{
                 "prompt" => "extract the guide sections",
                 "agent" => "explore",
                 "expected_output" => "Write the extraction to `out/guides.md`"
               },
               ctx(dir, assigns)
             )

    assert message =~ "implementer"
  end

  # boundaries is excluded on purpose: "do not write any files" is the
  # opposite of an order to write one.
  test "a boundary forbidding writes is not a write brief", %{dir: dir, assigns: assigns} do
    assert {:ok, _text, _ui} =
             SpawnAgent.execute(
               %{
                 "prompt" => "map the module structure",
                 "agent" => "explore",
                 "boundaries" => "Investigate only. Do not write any files."
               },
               ctx(dir, assigns)
             )
  end
end
