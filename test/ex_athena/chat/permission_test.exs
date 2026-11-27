defmodule ExAthena.Chat.PermissionTest do
  @moduledoc """
  The four permission levels a person picks instead of a chat mode (issue 322),
  driven through real runs.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Chat.Permission
  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  doctest ExAthena.Chat.Permission

  setup do
    dir = Path.join(System.tmp_dir!(), "permission_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp says(text), do: %Response{text: text, finish_reason: :stop, provider: :mock}

  defp tool_turn(calls),
    do: %Response{text: "", tool_calls: calls, finish_reason: :tool_calls, provider: :mock}

  defp call(id, name, args), do: %ToolCall{id: id, name: name, arguments: args}

  defp write(id \\ "w1", path \\ "a.txt"),
    do: tool_turn([call(id, "write", %{"path" => path, "content" => "hi"})])

  defp bash(id, cmd), do: tool_turn([call(id, "bash", %{"command" => cmd})])

  defp scripted(responses) do
    counter = :counters.new(1, [:atomics])

    fn _request ->
      :counters.add(counter, 1, 1)
      Enum.at(responses, :counters.get(counter, 1) - 1) || List.last(responses)
    end
  end

  # Answers each question from `answers` in turn and tells the test what it
  # was asked.
  defp asker(answers) do
    test_pid = self()
    queue = :counters.new(1, [:atomics])

    fn question, options, kind ->
      send(test_pid, {:asked, question, options})
      send(test_pid, {:kind, kind})
      :counters.add(queue, 1, 1)
      Enum.at(answers, :counters.get(queue, 1) - 1, "Deny")
    end
  end

  defp run(level, script, dir, answers \\ [], extra_tools \\ []) do
    {_ref, opts} = Keyword.pop(Permission.run_opts(level, asker(answers)), :level_ref)

    Loop.run(
      "do it",
      [
        provider: :mock,
        mock: [responder: scripted(script)],
        cwd: dir,
        tools:
          [ExAthena.Tools.Write, ExAthena.Tools.Bash, ExAthena.Tools.PlanMode] ++ extra_tools,
        memory: false,
        max_iterations: 10
      ] ++ opts
    )
  end

  defp written?(dir, path \\ "a.txt"), do: File.exists?(Path.join(dir, path))

  describe "Ask before edits" do
    test "an edit asks first, and runs when allowed", %{dir: dir} do
      assert {:ok, _} = run(:ask, [write(), says("Done.")], dir, ["Allow"])

      assert_received {:asked, "Change a.txt?", ["Allow", "Deny"]}
      assert written?(dir)
    end

    test "a denied edit never runs", %{dir: dir} do
      assert {:ok, _} = run(:ask, [write(), says("Done.")], dir, ["Deny"])

      assert_received {:asked, _, _}
      refute written?(dir)
    end

    test "a denied command never runs", %{dir: dir} do
      assert {:ok, _} = run(:ask, [bash("b1", "touch made.txt"), says("Done.")], dir, ["Deny"])

      assert_received {:asked, "Run this command?\n\ntouch made.txt", _}
      refute written?(dir, "made.txt")
    end

    # The read-only test reads a command's words, and some read-only words
    # still write or run code; below Trusted every command asks.
    test "a read-only command asks too", %{dir: dir} do
      assert {:ok, _} = run(:ask, [bash("b1", "ls"), says("Two files.")], dir, ["Allow"])
      assert_received {:asked, "Run this command?\n\nls", _}
      assert_received {:kind, :approval}
    end

    test "a web fetch asks, since a request can carry data out", %{dir: dir} do
      fetch = tool_turn([call("f1", "web_fetch", %{"url" => "https://example.com/?q=secret"})])

      assert {:ok, _} =
               run(:ask, [fetch, says("Done.")], dir, ["Deny"], [ExAthena.Tools.WebFetch])

      assert_received {:asked, "Fetch this page?\n\nhttps://example.com/?q=secret", _}
    end
  end

  describe "Edit freely" do
    test "an edit runs without asking", %{dir: dir} do
      assert {:ok, _} = run(:edit, [write(), says("Done.")], dir)

      refute_received {:asked, _, _}
      assert written?(dir)
    end

    test "a command that changes something still asks", %{dir: dir} do
      assert {:ok, _} = run(:edit, [bash("b1", "touch made.txt"), says("Done.")], dir, ["Deny"])

      assert_received {:asked, "Run this command?" <> _, _}
      refute written?(dir, "made.txt")
    end
  end

  describe "Trusted" do
    test "everything runs without asking", %{dir: dir} do
      script = [write(), bash("b1", "touch made.txt"), says("Done.")]
      assert {:ok, _} = run(:trusted, script, dir)

      refute_received {:asked, _, _}
      assert written?(dir)
      assert written?(dir, "made.txt")
    end
  end

  describe "Read only (plan)" do
    defp exit_plan(plan),
      do: tool_turn([call("p1", "plan_mode", %{"action" => "exit", "plan" => plan})])

    test "a read-only command asks too", %{dir: dir} do
      assert {:ok, _} = run(:read_only, [bash("b1", "ls"), says("Two files.")], dir, ["Allow"])
      assert_received {:asked, "Run this command?\n\nls", _}
    end

    test "a helper cannot leave read only on its own" do
      {_ref, opts} = Keyword.pop(Permission.run_opts(:read_only, asker([])), :level_ref)
      ctx = %{assigns: %{agent_depth: 1}}

      assert {:deny, reason} =
               opts[:can_use_tool].("plan_mode", %{"action" => "exit", "plan" => "x"}, ctx)

      assert reason =~ "helper"
      refute_received {:asked, _, _}
    end

    test "changes nothing before the plan is approved", %{dir: dir} do
      assert {:ok, _} = run(:read_only, [write(), says("Here is my plan.")], dir)

      refute_received {:asked, _, _}
      refute written?(dir)
    end

    test "shows the plan, and an approval to edit freely lets the next edit run",
         %{dir: dir} do
      script = [exit_plan("1. Write a.txt"), write(), says("Done.")]
      assert {:ok, _} = run(:read_only, script, dir, ["Yes, and edit freely"])

      assert_received {:asked, question, options}
      assert_received {:kind, :plan_approval}
      assert question =~ "1. Write a.txt"
      assert "No, keep planning" in options
      refute_received {:asked, _, _}
      assert written?(dir)
    end

    test "an approval that keeps asking asks before the edit", %{dir: dir} do
      script = [exit_plan("1. Write a.txt"), write(), says("Done.")]

      assert {:ok, _} =
               run(:read_only, script, dir, ["Yes, and ask before each edit", "Allow"])

      assert_received {:asked, _plan, _}
      assert_received {:asked, "Change a.txt?", _}
      assert written?(dir)
    end

    test "keep planning leaves the chat read only", %{dir: dir} do
      script = [exit_plan("1. Write a.txt"), write(), says("Still planning.")]
      assert {:ok, result} = run(:read_only, script, dir, ["No, keep planning"])

      refute written?(dir)

      text =
        result.messages
        |> Enum.flat_map(&(&1.tool_results || []))
        |> Enum.map_join("\n", &to_string(&1.content))

      assert text =~ "keep planning"
    end

    test "the chat is told how to show its plan", %{dir: dir} do
      test_pid = self()
      {_ref, opts} = Keyword.pop(Permission.run_opts(:read_only, asker([])), :level_ref)

      responder = fn request ->
        send(test_pid, {:system, request.system_prompt})
        says("Looking.")
      end

      assert {:ok, _} =
               Loop.run(
                 "plan it",
                 [
                   provider: :mock,
                   mock: [responder: responder],
                   cwd: dir,
                   tools: [ExAthena.Tools.Read, ExAthena.Tools.PlanMode],
                   memory: false
                 ] ++ opts
               )

      assert_received {:system, prompt}
      assert prompt =~ ~s(call plan_mode with action "exit")
    end
  end

  test "a GitHub command asks, since it sends text to GitHub" do
    {_ref, opts} = Keyword.pop(Permission.run_opts(:edit, asker(["Deny"])), :level_ref)

    assert {:deny, _} = opts[:can_use_tool].("gh", %{"command" => "search code secret"}, nil)
    assert_received {:asked, "Run this GitHub command?\n\ngh search code secret", _}
  end

  test "the language server asks once per run" do
    {_ref, opts} = Keyword.pop(Permission.run_opts(:edit, asker(["Allow"])), :level_ref)
    decide = opts[:can_use_tool]

    assert decide.("lsp", %{"action" => "definition"}, nil) == :allow
    assert_received {:asked, "Start the language server?" <> _, _}

    assert decide.("lsp", %{"action" => "references"}, nil) == :allow
    refute_received {:asked, _, _}
  end

  test "an answer nobody gives denies", %{dir: dir} do
    {_ref, opts} =
      Keyword.pop(Permission.run_opts(:ask, fn _q, _o, _kind -> :gone end), :level_ref)

    assert {:ok, _} =
             Loop.run(
               "do it",
               [
                 provider: :mock,
                 mock: [responder: scripted([write(), says("Done.")])],
                 cwd: dir,
                 tools: [ExAthena.Tools.Write],
                 memory: false
               ] ++ opts
             )

    refute written?(dir)
  end
end
