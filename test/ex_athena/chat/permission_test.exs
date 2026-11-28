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

  describe "a level moved while the run goes (issue 333)" do
    # A run at `level` whose model moves it to `moved_to` before its first
    # step, the way the web chat's picker does.
    defp run_moved(level, moved_to, step, dir, answers) do
      {ref, opts} = Keyword.pop(Permission.run_opts(level, asker(answers)), :level_ref)
      counter = :counters.new(1, [:atomics])

      responder = fn _request ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          Permission.put(ref, moved_to)
          step
        else
          says("Done.")
        end
      end

      Loop.run(
        "do it",
        [
          provider: :mock,
          mock: [responder: responder],
          cwd: dir,
          tools: [ExAthena.Tools.Write, ExAthena.Tools.Bash],
          memory: false,
          max_iterations: 5
        ] ++ opts
      )
    end

    test "Trusted lets the next command run without asking", %{dir: dir} do
      assert {:ok, _} = run_moved(:ask, :trusted, bash("b1", "touch made.txt"), dir, [])

      refute_received {:asked, _, _}
      assert written?(dir, "made.txt")
    end

    test "Ask makes a Trusted run's next command ask", %{dir: dir} do
      assert {:ok, _} = run_moved(:trusted, :ask, bash("b1", "touch made.txt"), dir, ["Deny"])

      assert_received {:asked, "Run this command?\n\ntouch made.txt", _}
      refute written?(dir, "made.txt")
    end

    test "Read only refuses the next edit without asking", %{dir: dir} do
      assert {:ok, _} = run_moved(:edit, :read_only, write(), dir, ["Allow"])

      refute_received {:asked, _, _}
      refute written?(dir)
    end

    test "Read only refuses a command that can change something", %{dir: dir} do
      assert {:ok, _} =
               run_moved(:trusted, :read_only, bash("b1", "touch made.txt"), dir, ["Allow"])

      refute_received {:asked, _, _}
      refute written?(dir, "made.txt")
    end

    test "Read only still asks before a command that only reads", %{dir: dir} do
      assert {:ok, _} = run_moved(:ask, :read_only, bash("b1", "ls"), dir, ["Allow"])
      assert_received {:asked, "Run this command?\n\nls", _}
    end

    test "Read only tells the chat how to show its plan, and the approval lets it edit",
         %{dir: dir} do
      {ref, opts} =
        Keyword.pop(Permission.run_opts(:edit, asker(["Yes, and edit freely"])), :level_ref)

      exit_plan = tool_turn([call("p1", "plan_mode", %{"action" => "exit", "plan" => "1. a"})])
      responses = [write("w1"), exit_plan, write("w2"), says("Done.")]
      counter = :counters.new(1, [:atomics])
      test_pid = self()

      responder = fn request ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        if n == 1, do: Permission.put(ref, :read_only)
        if n == 2, do: send(test_pid, {:refusal, List.last(request.messages)})
        Enum.at(responses, n - 1, says("Done."))
      end

      assert {:ok, _} =
               Loop.run(
                 "do it",
                 [
                   provider: :mock,
                   mock: [responder: responder],
                   cwd: dir,
                   tools: [ExAthena.Tools.Write, ExAthena.Tools.PlanMode],
                   memory: false,
                   max_iterations: 6
                 ] ++ opts
               )

      assert_received {:refusal, refusal}
      assert inspect(refusal) =~ "plan_mode"
      assert_received {:asked, "The chat's plan:" <> _, _}
      refute_received {:asked, _, _}
      assert Permission.current(ref) == :edit
      assert written?(dir)
    end

    test "an Allow given after the person picked Read only changes nothing" do
      # The picker moves while the question is on screen; the call runs here,
      # in the test process.
      ask = fn _question, _options, _kind ->
        Permission.put(Process.get(:level_ref), :read_only)
        "Allow"
      end

      {ref, opts} = Keyword.pop(Permission.run_opts(:ask, ask), :level_ref)
      Process.put(:level_ref, ref)

      assert {:deny, reason} =
               opts[:can_use_tool].("bash", %{"command" => "touch x"}, %{phase: :default})

      assert reason =~ "read only"
    end

    test "a helper sent after the level was lowered asks before its command", %{dir: dir} do
      assert {:ok, _} = run_with_helper(:trusted, :ask, dir, ["Deny"])

      assert_received {:asked, "Run this command?\n\ntouch helper.txt", _}
      refute written?(dir, "helper.txt")
    end

    test "a helper in a run moved to Read only is refused without asking", %{dir: dir} do
      assert {:ok, _} = run_with_helper(:trusted, :read_only, dir, ["Allow"])

      refute_received {:asked, _, _}
      refute written?(dir, "helper.txt")
      assert_received {:helper_refusal, refusal}
      assert inspect(refusal) =~ "your report"
      refute inspect(refusal) =~ "plan_mode"
    end

    test "Read only refuses a helper named by an agent definition, and sends a plain one" do
      {ref, opts} = Keyword.pop(Permission.run_opts(:ask, asker([])), :level_ref)
      decide = opts[:can_use_tool]
      Permission.put(ref, :read_only)

      assert {:deny, _} =
               decide.("spawn_agent", %{"prompt" => "x", "agent" => "coder"}, %{phase: :default})

      assert decide.("spawn_agent", %{"prompt" => "x"}, %{phase: :default}) == :allow
      assert decide.("todo_write", %{"todos" => []}, %{phase: :default}) == :allow
      assert decide.("finish", %{"summary" => "x"}, %{phase: :default}) == :allow
      refute_received {:asked, _, _}
    end

    # The chat moves to `moved_to`, then sends a helper that runs one command.
    defp run_with_helper(level, moved_to, dir, answers) do
      {ref, opts} = Keyword.pop(Permission.run_opts(level, asker(answers)), :level_ref)
      parent = :counters.new(1, [:atomics])
      child = :counters.new(1, [:atomics])

      parent_responder = fn _request ->
        :counters.add(parent, 1, 1)

        if :counters.get(parent, 1) == 1 do
          Permission.put(ref, moved_to)
          tool_turn([call("s1", "spawn_agent", %{"prompt" => "make helper.txt"})])
        else
          says("Done.")
        end
      end

      test_pid = self()

      child_responder = fn request ->
        :counters.add(child, 1, 1)

        if :counters.get(child, 1) == 2,
          do: send(test_pid, {:helper_refusal, List.last(request.messages)})

        if :counters.get(child, 1) == 1,
          do: bash("c1", "touch helper.txt"),
          else: says("Helper done.")
      end

      Loop.run(
        "do it",
        [
          provider: :mock,
          mock: [responder: parent_responder],
          cwd: dir,
          tools: [ExAthena.Tools.SpawnAgent, ExAthena.Tools.Bash],
          memory: false,
          max_iterations: 5,
          assigns: %{
            spawn_agent_opts: [
              provider: :mock,
              mock: [responder: child_responder],
              tools: [ExAthena.Tools.Bash],
              memory: false
            ]
          }
        ] ++ opts
      )
    end

    test "a helper follows the moved level, and still cannot leave read only" do
      {ref, opts} = Keyword.pop(Permission.run_opts(:ask, asker([])), :level_ref)
      decide = opts[:can_use_tool]
      helper = %{assigns: %{agent_depth: 1}}

      Permission.put(ref, :trusted)
      assert decide.("bash", %{"command" => "touch x"}, helper) == :allow
      refute_received {:asked, _, _}

      assert {:deny, reason} = decide.("plan_mode", %{"action" => "exit", "plan" => "x"}, helper)
      assert reason =~ "helper"
      assert Permission.current(ref) == :trusted
    end

    test "Trusted still lets a provider that runs its own tools skip asking" do
      opts = Permission.run_opts(:trusted, asker([]))

      assert ExAthena.Providers.ClaudeCode.build_opts(
               %ExAthena.Request{messages: []},
               opts
             )[:permission_mode] == :bypass_permissions
    end
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
