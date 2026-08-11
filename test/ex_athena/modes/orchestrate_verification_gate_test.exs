defmodule ExAthena.Modes.OrchestrateVerificationGateTest do
  @moduledoc """
  An orchestrator can mark "verify it compiles" completed without any worker
  having run anything, then `finish` with a deliverable asserting the build is
  clean. Live run: 6 spawns (1 explore, 2 file reads, 3 edits), zero
  verification, and a deliverable claiming "The app compiles cleanly with no
  new errors" — for code whose page raised on every load.

  Todo status is self-reported, so it cannot gate anything. Worker provenance
  can: it is derived from the workers' own tool calls.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall

  @ran_nothing_note "no command was run to check"
  @no_test_note "no test run covered"
  @uncovered_note "no test executed"

  # A package.json whose `test` script is `true`/`false` gives a real, fast,
  # hermetic test-runner invocation with a chosen exit code.
  defp npm_project(dir, script) do
    File.write!(
      Path.join(dir, "package.json"),
      ~s({"name":"t","version":"1.0.0","scripts":{"test":"#{script}"}})
    )
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "orch_verify_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp scripted(responses) do
    counter = :counters.new(1, [:atomics])

    fn _request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      Enum.at(responses, n - 1) || List.last(responses)
    end
  end

  defp call(id, name, args), do: %ToolCall{id: id, name: name, arguments: args}

  defp tool_turn(calls),
    do: %Response{text: "", tool_calls: calls, finish_reason: :tool_calls, provider: :mock}

  defp todo(status),
    do:
      tool_turn([
        call("t#{status}", "todo_write", %{
          "todos" => [%{"content" => "make the change", "status" => status}]
        })
      ])

  # The orchestrator: plan → delegate → mark done → declare success.
  defp orchestrator_script do
    [
      todo("in_progress"),
      tool_turn([
        call("s1", "spawn_agent", %{
          "prompt" => "make the change",
          "objective" => "make the change",
          "expected_output" => "a report",
          "tool_guidance" => "edit the file",
          "boundaries" => "stay in cwd",
          "todo" => "make the change"
        })
      ]),
      todo("completed"),
      tool_turn([
        call("f1", "finish", %{"deliverable" => "Done. The app compiles cleanly."})
      ])
    ]
  end

  defp worker(calls) do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 -> tool_turn(calls)
        _ -> %Response{text: "Done, all good.", finish_reason: :stop, provider: :mock}
      end
    end
  end

  defp run(worker_calls, worker_tools, dir) do
    Loop.run("add a doctor filter",
      provider: :mock,
      mock: [responder: scripted(orchestrator_script())],
      cwd: dir,
      tools: ExAthena.Tools.builtins(),
      mode: :orchestrate,
      memory: false,
      max_iterations: 12,
      assigns: %{
        spawn_agent_opts: [
          provider: :mock,
          mock: [responder: worker(worker_calls)],
          tools: worker_tools,
          memory: false
        ]
      }
    )
  end

  # Every message body, including runtime redirects delivered as tool results.
  defp transcript(%Result{messages: messages}) do
    messages
    |> Enum.flat_map(fn msg ->
      [to_string(msg.content || "")] ++
        Enum.map(msg.tool_results || [], &to_string(&1.content || ""))
    end)
    |> Enum.join("\n")
  end

  defp wrote_a_file,
    do: [call("w1", "write", %{"path" => "lib/a.ex", "content" => "defmodule A do\nend\n"})]

  test "refuses a clean finish when files changed and nothing was run", %{dir: dir} do
    assert {:ok, result} = run(wrote_a_file(), [ExAthena.Tools.Write], dir)

    text = transcript(result)

    assert text =~ @ran_nothing_note
    # The redirect must name what is unverified, or the model cannot act on it.
    assert text =~ "lib/a.ex"
  end

  test "a read-only run is never gated", %{dir: dir} do
    File.write!(Path.join(dir, "a.ex"), "defmodule A do\nend\n")
    calls = [call("r1", "read", %{"path" => "a.ex"})]

    assert {:ok, result} = run(calls, [ExAthena.Tools.Read], dir)

    refute transcript(result) =~ @ran_nothing_note
    refute transcript(result) =~ @no_test_note
    assert result.finish_reason == :submitted
  end

  # This is the gap Stage 1 left open: the doctor-filter change compiled
  # cleanly and raised on every page load. A build proves the code parses.
  test "a build alone does not satisfy the gate — nothing exercised the change",
       %{dir: dir} do
    calls = wrote_a_file() ++ [call("b1", "bash", %{"command" => "mix --version"})]

    assert {:ok, result} = run(calls, [ExAthena.Tools.Write, ExAthena.Tools.Bash], dir)

    text = transcript(result)

    refute text =~ @ran_nothing_note
    assert text =~ @no_test_note
  end

  test "honours finish when a test run covered the change", %{dir: dir} do
    npm_project(dir, "true")
    calls = wrote_a_file() ++ [call("b1", "bash", %{"command" => "npm test"})]

    assert {:ok, result} = run(calls, [ExAthena.Tools.Write, ExAthena.Tools.Bash], dir)

    text = transcript(result)

    refute text =~ @ran_nothing_note
    refute text =~ @no_test_note
    assert result.finish_reason == :submitted
  end

  # Bash returns {:ok, …} whatever the exit code, so without exit tracking a
  # worker could watch the suite go red and still finish as a success.
  test "a red test run does not count as coverage", %{dir: dir} do
    npm_project(dir, "false")
    calls = wrote_a_file() ++ [call("b1", "bash", %{"command" => "npm test"})]

    assert {:ok, result} = run(calls, [ExAthena.Tools.Write, ExAthena.Tools.Bash], dir)

    assert transcript(result) =~ @no_test_note
  end

  test "changing only a test file is not treated as unexercised source", %{dir: dir} do
    npm_project(dir, "true")

    calls = [
      call("w1", "write", %{"path" => "test/a_test.exs", "content" => "# a test\n"}),
      call("b1", "bash", %{"command" => "npm test"})
    ]

    assert {:ok, result} = run(calls, [ExAthena.Tools.Write, ExAthena.Tools.Bash], dir)

    refute transcript(result) =~ @no_test_note
    assert result.finish_reason == :submitted
  end

  # A green suite proves a test EXISTS, not that it covers the change. The
  # live failure wrote a test for a private helper it had just written,
  # reported 252 passing, and shipped a page that raised on every load.
  describe "coverage of the changed code" do
    # A worker that changed a file, ran a green suite, and pasted a coverage
    # table showing that file was never executed.
    defp worker_with_coverage(module, percent) do
      report = """
      Percentage | Module
      -----------|--------------------------
      #{percent}% | #{module}
      -----------|--------------------------
           3.82% | Total
      """

      counter = :counters.new(1, [:atomics])

      fn _req ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            tool_turn([
              call("w1", "write", %{
                "path" => "lib/a.ex",
                "content" => "defmodule #{module} do\nend\n"
              }),
              call("b1", "bash", %{"command" => "npm test"})
            ])

          _ ->
            %Response{
              text: "All green.\n\n#{report}",
              finish_reason: :stop,
              provider: :mock
            }
        end
      end
    end

    defp run_with(worker, dir) do
      npm_project(dir, "true")

      Loop.run("add a doctor filter",
        provider: :mock,
        mock: [responder: scripted(orchestrator_script())],
        cwd: dir,
        tools: ExAthena.Tools.builtins(),
        mode: :orchestrate,
        memory: false,
        max_iterations: 12,
        assigns: %{
          spawn_agent_opts: [
            provider: :mock,
            mock: [responder: worker],
            tools: [ExAthena.Tools.Write, ExAthena.Tools.Bash],
            memory: false
          ]
        }
      )
    end

    test "refuses a finish when the changed file was never executed", %{dir: dir} do
      assert {:ok, result} = run_with(worker_with_coverage("MyApp.Thing", "     0.00"), dir)

      text = transcript(result)
      assert text =~ @uncovered_note
      assert text =~ "lib/a.ex"
    end

    test "accepts a change the tests did execute", %{dir: dir} do
      assert {:ok, result} = run_with(worker_with_coverage("MyApp.Thing", "    20.83"), dir)

      refute transcript(result) =~ @uncovered_note
      assert result.finish_reason == :submitted
    end

    # Percentages lie for declarative code: the buggy Ash resource in the live
    # failure reported 100% because its body is compile-time DSL. The gate
    # asks only "was this ever executed", never "is this well covered".
    test "does not gate on how much was covered, only whether anything was", %{dir: dir} do
      assert {:ok, result} = run_with(worker_with_coverage("MyApp.Thing", "     0.01"), dir)

      refute transcript(result) =~ @uncovered_note
    end

    test "asks for coverage when the run reported none", %{dir: dir} do
      counter = :counters.new(1, [:atomics])

      no_coverage = fn _req ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            tool_turn([
              call("w1", "write", %{"path" => "lib/a.ex", "content" => "defmodule A do\nend\n"}),
              call("b1", "bash", %{"command" => "npm test"})
            ])

          _ ->
            %Response{text: "252 tests, 0 failures.", finish_reason: :stop, provider: :mock}
        end
      end

      assert {:ok, result} = run_with(no_coverage, dir)
      assert transcript(result) =~ @uncovered_note
    end
  end

  # The rails raise the floor; they must never trap a run that genuinely
  # cannot verify. Each fires at most once, so the run always terminates.
  test "both gates together still let the run complete", %{dir: dir} do
    assert {:ok, result} = run(wrote_a_file(), [ExAthena.Tools.Write], dir)

    text = transcript(result)

    assert text =~ @ran_nothing_note
    assert text =~ @no_test_note
    assert result.finish_reason == :submitted
    assert result.deliverable =~ "compiles cleanly"
  end
end
