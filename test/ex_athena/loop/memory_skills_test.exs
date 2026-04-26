defmodule ExAthena.Loop.MemorySkillsTest do
  @moduledoc """
  PR1 — verifies the Memory + Skills wiring at the loop boundary:

    * `AGENTS.md` → user-context message at the front of the conversation.
    * `SKILL.md` → frontmatter catalog appended to the system prompt.
    * `[skill: name]` sentinel in assistant text → body activation
      message appended after the tool-result turn.
    * `:preload_skills` opt → body activated up-front.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Loop
  alias ExAthena.Messages.{Message, ToolCall}
  alias ExAthena.Response

  setup do
    cwd = Path.join(System.tmp_dir!(), "memskills_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  defp single_text_response(text) do
    fn _request ->
      %Response{text: text, tool_calls: [], finish_reason: :stop, provider: :mock}
    end
  end

  defp tool_then_stop_responder(tool_call_text, tool_args) do
    counter = :counters.new(1, [:atomics])

    fn _request ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: tool_call_text,
            tool_calls: [%ToolCall{id: "c1", name: "read", arguments: tool_args}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
      end
    end
  end

  describe "memory" do
    test "AGENTS.md is loaded as a user-context message at the front", %{cwd: cwd} do
      File.write!(Path.join(cwd, "AGENTS.md"), "Always run mix format.")

      {:ok, result} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: single_text_response("ok")],
          tools: [],
          cwd: cwd,
          # Skip user-level memory so the test is hermetic.
          memory: ExAthena.Memory.discover(cwd, user_dir: "/no/such/dir")
        )

      assert [first | _] = result.messages

      assert %Message{role: :user, name: "memory", content: c} = first
      assert c =~ "Always run mix format."
    end

    test "memory: false skips discovery entirely", %{cwd: cwd} do
      File.write!(Path.join(cwd, "AGENTS.md"), "should not appear")

      {:ok, result} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: single_text_response("ok")],
          tools: [],
          cwd: cwd,
          memory: false
        )

      refute Enum.any?(result.messages, &match?(%Message{name: "memory"}, &1))
    end
  end

  describe "skills catalog" do
    test "skill frontmatter is appended to the system prompt", %{cwd: cwd} do
      skill_dir = Path.join(cwd, ".exathena/skills/deploy")
      File.mkdir_p!(skill_dir)

      File.write!(
        Path.join(skill_dir, "SKILL.md"),
        "---\nname: deploy\ndescription: Ship the app\n---\n# Body\nrun deploy"
      )

      ref = make_ref()
      parent = self()

      responder = fn request ->
        send(parent, {ref, request.system_prompt})
        %Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
      end

      {:ok, _} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: responder],
          tools: [],
          cwd: cwd,
          memory: false,
          skills: ExAthena.Skills.discover(cwd, user_dir: "/no/such/dir")
        )

      assert_receive {^ref, system_prompt}
      assert system_prompt =~ "Available Skills"
      assert system_prompt =~ "deploy"
      assert system_prompt =~ "Ship the app"
    end
  end

  describe "skill auto-load via [skill: name] sentinel" do
    test "appends the skill body to messages on the next iteration", %{cwd: cwd} do
      skill_dir = Path.join(cwd, ".exathena/skills/deploy")
      File.mkdir_p!(skill_dir)

      File.write!(
        Path.join(skill_dir, "SKILL.md"),
        "---\nname: deploy\ndescription: Ship the app\n---\n# Deploy steps\n1. Build"
      )

      File.write!(Path.join(cwd, "hello.txt"), "hi")

      # First response: model says it needs deploy + calls a read tool.
      # Second response: terminal text. The activation message must land
      # between the tool result and the second turn.
      responder =
        tool_then_stop_responder("I need [skill: deploy] then I'll read", %{
          "path" => "hello.txt"
        })

      {:ok, result} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: responder],
          tools: [ExAthena.Tools.Read],
          cwd: cwd,
          memory: false,
          skills: ExAthena.Skills.discover(cwd, user_dir: "/no/such/dir")
        )

      activation =
        Enum.find(result.messages, fn
          %Message{role: :system, name: "skill:deploy"} -> true
          _ -> false
        end)

      assert activation, "expected skill:deploy activation message in #{inspect(result.messages)}"
      assert activation.content =~ "Deploy steps"
    end

    test "is idempotent across multiple sentinel mentions", %{cwd: cwd} do
      skill_dir = Path.join(cwd, ".exathena/skills/deploy")
      File.mkdir_p!(skill_dir)

      File.write!(
        Path.join(skill_dir, "SKILL.md"),
        "---\nname: deploy\ndescription: x\n---\nbody"
      )

      File.write!(Path.join(cwd, "hello.txt"), "hi")

      counter = :counters.new(1, [:atomics])

      # Three turns, each mentioning [skill: deploy]. Only the first
      # should attach a body; the rest see the existing skill:deploy
      # message and skip.
      responder = fn _request ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          n when n in [1, 2] ->
            %Response{
              text: "[skill: deploy] turn #{n}",
              tool_calls: [
                %ToolCall{id: "c#{n}", name: "read", arguments: %{"path" => "hello.txt"}}
              ],
              finish_reason: :tool_calls,
              provider: :mock
            }

          _ ->
            %Response{text: "done", tool_calls: [], finish_reason: :stop, provider: :mock}
        end
      end

      {:ok, result} =
        Loop.run("go",
          provider: :mock,
          mock: [responder: responder],
          tools: [ExAthena.Tools.Read],
          cwd: cwd,
          memory: false,
          skills: ExAthena.Skills.discover(cwd, user_dir: "/no/such/dir")
        )

      attached = Enum.count(result.messages, &match?(%Message{name: "skill:deploy"}, &1))
      assert attached == 1
    end
  end

  describe "preload_skills" do
    test "activates skill bodies up-front before the first model call", %{cwd: cwd} do
      skill_dir = Path.join(cwd, ".exathena/skills/deploy")
      File.mkdir_p!(skill_dir)

      File.write!(
        Path.join(skill_dir, "SKILL.md"),
        "---\nname: deploy\ndescription: x\n---\npreloaded body"
      )

      ref = make_ref()
      parent = self()

      responder = fn request ->
        send(parent, {ref, request.messages})
        %Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
      end

      {:ok, _} =
        Loop.run("hi",
          provider: :mock,
          mock: [responder: responder],
          tools: [],
          cwd: cwd,
          memory: false,
          skills: ExAthena.Skills.discover(cwd, user_dir: "/no/such/dir"),
          preload_skills: ["deploy"]
        )

      assert_receive {^ref, messages}

      assert Enum.any?(messages, fn
               %Message{role: :system, name: "skill:deploy"} -> true
               _ -> false
             end)
    end
  end
end
