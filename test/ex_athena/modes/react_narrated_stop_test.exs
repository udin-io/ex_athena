defmodule ExAthena.Modes.ReActNarratedStopTest do
  @moduledoc """
  Issue 258. `ReAct` treats a turn with no tool calls as terminal, so a worker
  that spends its turn saying what it will do next ends the run instead.

  Web session `cfcf79154cb1`, worker `subagent_J8xXdYDq`: 15 iterations, 38
  tool calls, 608,954 input tokens and 19 minutes, then a turn that ended
  "Writing the brief now." and nothing else. `finish_reason: :stop`, `ok:
  true`, no brief.

  The push-back has to fire on that and NOT on a worker whose final text is
  its deliverable — an `explore` worker reports in prose, and nudging it would
  cost a turn on every research spawn in the tree.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}

  # The live failure, verbatim apart from the file names.
  @narration """
  I'm at the budget line and the deliverable isn't written yet. I have
  everything I need: the issue, the existing code, the router sessions and the
  console's design system. Writing the brief now.
  """

  # What an `explore` worker hands back: its findings ARE the deliverable.
  @report """
  The console reads its theme from lib/web/theme.ex, which resolves tokens at
  compile time. Three call sites depend on that: the layout, the sidebar and
  the settings form. The settings form is the only one that re-reads tokens
  per render, so it is the one a runtime theme switch would break.
  """

  @marker "[runtime: narrated-stop]"

  setup do
    dir = Path.join(System.tmp_dir!(), "narrated_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "f.txt"), "contents")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Answers with the nth text, tool-free, and forwards every request to the
  # test. Past the end of the list it repeats the last one.
  defp responder(test_pid, texts) do
    counter = :counters.new(1, [:atomics])

    fn request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(test_pid, {:req, n, request})

      %Response{
        text: Enum.at(texts, n - 1, List.last(texts)),
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    end
  end

  defp run(dir, responder, opts) do
    Loop.run(
      "build an HTML architecture brief for the payment-url work",
      [
        provider: :mock,
        mock: [responder: responder],
        cwd: dir,
        max_iterations: 6,
        max_unproductive_iterations: 10_000,
        tools: [ExAthena.Tools.Read]
      ] ++ opts
    )
  end

  defp text_of(%{messages: messages}) do
    messages
    |> Enum.filter(&is_binary(&1.content))
    |> Enum.map_join("\n", & &1.content)
  end

  describe "a worker that narrates its next action" do
    test "is pushed back once, and its second stop is honoured", %{dir: dir} do
      responder =
        responder(self(), [@narration, "I did NOT write the brief. Nothing is on disk."])

      assert {:ok, result} = run(dir, responder, parent_session_id: "parent-1")

      assert_receive {:req, 1, _first}, 1_000
      assert_receive {:req, 2, second}, 1_000
      refute_receive {:req, 3, _third}, 200

      assert text_of(second) =~ @marker
      assert result.finish_reason == :stop
      assert result.text =~ "I did NOT write the brief"
    end

    test "is told to do the thing or hand back honestly, not merely to continue",
         %{dir: dir} do
      responder = responder(self(), [@narration, "done"])

      assert {:ok, _} = run(dir, responder, parent_session_id: "parent-1")

      assert_receive {:req, 2, second}, 1_000
      note = text_of(second)

      assert note =~ ~r/hand back/i
      assert note =~ ~r/not done/i
      refute note =~ ~r/\bplease continue\b/i
    end

    test "is nudged once per run, even when it narrates again", %{dir: dir} do
      responder = responder(self(), [@narration, "Let me double-check the router first."])

      assert {:ok, result} = run(dir, responder, parent_session_id: "parent-1")

      assert_receive {:req, 2, _second}, 1_000
      refute_receive {:req, 3, _third}, 200
      assert result.finish_reason == :stop
    end

    test "is not nudged again on a resume that already carries the note", %{dir: dir} do
      prior = [
        %{role: :user, content: "build an HTML architecture brief"},
        %{role: :assistant, content: @narration},
        %{role: :user, content: @marker <> " You said what you would do next."}
      ]

      responder = responder(self(), [@narration])

      assert {:ok, _} =
               run(dir, responder, parent_session_id: "parent-1", messages: prior)

      assert_receive {:req, 1, _first}, 1_000
      refute_receive {:req, 2, _second}, 200
    end
  end

  describe "a run whose final text IS the deliverable" do
    test "stops on its first :stop", %{dir: dir} do
      responder = responder(self(), [@report])

      assert {:ok, result} = run(dir, responder, parent_session_id: "parent-1")

      assert_receive {:req, 1, _first}, 1_000
      refute_receive {:req, 2, _second}, 200

      assert result.finish_reason == :stop
      assert result.text =~ "resolves tokens at"
    end

    test "stops when it closes by offering help rather than announcing work", %{dir: dir} do
      responder = responder(self(), [@report <> "\n\nLet me know if you want the call graph."])

      assert {:ok, result} = run(dir, responder, parent_session_id: "parent-1")

      assert_receive {:req, 1, _first}, 1_000
      refute_receive {:req, 2, _second}, 200
      assert result.finish_reason == :stop
    end

    test "stops when it reports the work in the past tense", %{dir: dir} do
      text = "Wrote the brief to docs/design/258-brief.html. I will not be adding the diagrams."
      responder = responder(self(), [text])

      assert {:ok, result} = run(dir, responder, parent_session_id: "parent-1")

      assert_receive {:req, 1, _first}, 1_000
      refute_receive {:req, 2, _second}, 200
      assert result.finish_reason == :stop
    end
  end

  describe "a top-level run" do
    test "is never nudged — a human is reading the text and can answer it", %{dir: dir} do
      responder = responder(self(), [@narration])

      assert {:ok, result} = run(dir, responder, [])

      assert_receive {:req, 1, _first}, 1_000
      refute_receive {:req, 2, _second}, 200
      assert result.finish_reason == :stop
    end
  end
end
