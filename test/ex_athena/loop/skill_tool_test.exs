defmodule ExAthena.Loop.SkillToolTest do
  @moduledoc """
  Issue 247 — the `skill` tool as the second entry point to the one loader.

  A skill body must arrive the same way whichever entry point asked for it,
  once per run, and an unknown name must come back as something the model
  can act on.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Loop
  alias ExAthena.Messages.{Message, ToolCall}
  alias ExAthena.Response
  alias ExAthena.Skills

  setup do
    cwd = Path.join(System.tmp_dir!(), "skilltool_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  defp write_skill(cwd, name, frontmatter_extra, body) do
    dir = Path.join(cwd, ".exathena/skills/#{name}")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "SKILL.md"),
      "---\nname: #{name}\ndescription: does #{name}\n#{frontmatter_extra}---\n#{body}"
    )
  end

  defp skills(cwd), do: Skills.discover(cwd, user_dir: "/no/such/dir")

  # Turn 1..n play `turns`, then a terminal reply.
  defp responder(turns) do
    counter = :counters.new(1, [:atomics])

    fn _request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      case Enum.at(turns, n - 1) do
        nil ->
          %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}

        {text, calls} ->
          %Response{
            text: text,
            tool_calls: calls,
            finish_reason: :tool_calls,
            provider: :mock
          }
      end
    end
  end

  defp call(id, name), do: %ToolCall{id: id, name: "skill", arguments: %{"name" => name}}

  defp run(cwd, turns, opts \\ []) do
    {:ok, result} =
      Loop.run(
        "go",
        [
          provider: :mock,
          mock: [responder: responder(turns)],
          tools: [ExAthena.Tools.Skill],
          cwd: cwd,
          memory: false,
          skills: skills(cwd)
        ] ++ opts
      )

    result
  end

  defp activations(result, name) do
    Enum.filter(result.messages, &match?(%Message{name: ^name}, &1))
  end

  defp tool_result_content(result, id) do
    result.messages
    |> Enum.flat_map(fn
      %Message{role: :tool, tool_results: trs} when is_list(trs) -> trs
      _ -> []
    end)
    |> Enum.find(&(&1.tool_call_id == id))
  end

  describe "the tool as an entry point" do
    test "a skill tool call attaches the body", %{cwd: cwd} do
      write_skill(cwd, "deploy", "", "# Deploy steps\n1. Build")

      result = run(cwd, [{"loading", [call("c1", "deploy")]}])

      assert [%Message{role: :system, content: content}] = activations(result, "skill:deploy")
      assert content =~ "Deploy steps"
    end

    test "the body is byte-identical to what the sentinel path delivers", %{cwd: cwd} do
      write_skill(cwd, "deploy", "", "# Deploy steps\n1. Build")

      via_tool = run(cwd, [{"loading", [call("c1", "deploy")]}])
      via_sentinel = run(cwd, [{"I need [skill: deploy]", [call("c1", "nope")]}])

      assert [%Message{content: tool_body}] = activations(via_tool, "skill:deploy")
      assert [%Message{content: sentinel_body}] = activations(via_sentinel, "skill:deploy")
      assert tool_body == sentinel_body
    end

    test "the tool result tells the model the instructions are in context", %{cwd: cwd} do
      write_skill(cwd, "deploy", "", "body")

      result = run(cwd, [{"loading", [call("c1", "deploy")]}])

      assert %{content: content, is_error: is_error} = tool_result_content(result, "c1")
      refute is_error == true
      assert content =~ "deploy"
    end
  end

  describe "once-only loading" do
    test "the same skill called twice attaches one body", %{cwd: cwd} do
      write_skill(cwd, "deploy", "", "body")

      result =
        run(cwd, [
          {"once", [call("c1", "deploy")]},
          {"twice", [call("c2", "deploy")]}
        ])

      assert length(activations(result, "skill:deploy")) == 1
    end

    test "tool and sentinel naming the same skill attach one body", %{cwd: cwd} do
      write_skill(cwd, "deploy", "", "body")

      result =
        run(cwd, [
          {"tool first", [call("c1", "deploy")]},
          {"now the sentinel [skill: deploy]", [call("c2", "deploy")]}
        ])

      assert length(activations(result, "skill:deploy")) == 1
    end

    test "a preloaded skill is not attached again by a tool call", %{cwd: cwd} do
      write_skill(cwd, "deploy", "", "body")

      result =
        run(cwd, [{"loading", [call("c1", "deploy")]}], preload_skills: ["deploy"])

      assert length(activations(result, "skill:deploy")) == 1
    end
  end

  describe "the catalog names the mechanism the run has" do
    test "the skill tool when the run granted it", %{cwd: cwd} do
      write_skill(cwd, "deploy", "", "body")
      parent = self()
      ref = make_ref()

      responder = fn request ->
        send(parent, {ref, request.system_prompt})
        %Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
      end

      {:ok, _} =
        Loop.run("go",
          provider: :mock,
          mock: [responder: responder],
          tools: [ExAthena.Tools.Skill],
          cwd: cwd,
          memory: false,
          skills: skills(cwd)
        )

      assert_receive {^ref, system_prompt}, 1_000
      assert system_prompt =~ "Call the `skill` tool"
      refute system_prompt =~ "[skill: <name>]"
    end

    test "the sentinel when the run has no skill tool", %{cwd: cwd} do
      write_skill(cwd, "deploy", "", "body")
      parent = self()
      ref = make_ref()

      responder = fn request ->
        send(parent, {ref, request.system_prompt})
        %Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
      end

      {:ok, _} =
        Loop.run("go",
          provider: :mock,
          mock: [responder: responder],
          tools: [ExAthena.Tools.Read],
          cwd: cwd,
          memory: false,
          skills: skills(cwd)
        )

      assert_receive {^ref, system_prompt}, 1_000
      assert system_prompt =~ "[skill: <name>]"
      refute system_prompt =~ "Call the `skill` tool"
    end
  end

  describe "unknown and refused names" do
    test "an unknown name is a tool error naming the available skills", %{cwd: cwd} do
      write_skill(cwd, "deploy", "", "body")
      write_skill(cwd, "audit", "", "body")

      result = run(cwd, [{"loading", [call("c1", "deploi")]}])

      assert %{content: content, is_error: true} = tool_result_content(result, "c1")
      assert content =~ "deploi"
      assert content =~ "deploy"
      assert content =~ "audit"
      assert activations(result, "skill:deploi") == []
    end

    test "a failed call attaches nothing", %{cwd: cwd} do
      write_skill(cwd, "deploy", "", "body")

      result =
        run(cwd, [{"loading", [call("c1", "deploy")]}], disallowed_tools: ["skill"])

      assert %{is_error: true} = tool_result_content(result, "c1")
      assert activations(result, "skill:deploy") == []
    end

    test "disable-model-invocation blocks both entry points", %{cwd: cwd} do
      write_skill(cwd, "internal", "disable-model-invocation: true\n", "secret body")

      via_tool = run(cwd, [{"loading", [call("c1", "internal")]}])
      via_sentinel = run(cwd, [{"[skill: internal]", [call("c1", "nope")]}])

      assert %{is_error: true} = tool_result_content(via_tool, "c1")
      assert activations(via_tool, "skill:internal") == []
      assert activations(via_sentinel, "skill:internal") == []
    end
  end
end
