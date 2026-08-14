defmodule ExAthena.ProvenanceTest do
  use ExUnit.Case, async: true

  alias ExAthena.Messages.{Message, ToolCall, ToolResult}
  alias ExAthena.Provenance

  # A worker's report is free text, so an orchestrator cannot tell "the worker
  # ran mix compile" from "the worker said it compiled". These events are
  # derived from the worker's actual tool calls, so the claim becomes checkable.

  defp call(id, name, args), do: %ToolCall{id: id, name: name, arguments: args}

  defp assistant(calls), do: %Message{role: :assistant, tool_calls: calls}

  defp results(pairs) do
    %Message{
      role: :tool,
      tool_results:
        Enum.map(pairs, fn
          {id, :ok} ->
            %ToolResult{tool_call_id: id, content: "ok"}

          {id, :error} ->
            %ToolResult{tool_call_id: id, content: "boom", is_error: true}

          {id, {:exit, code}} ->
            %ToolResult{
              tool_call_id: id,
              content: "exit #{code}",
              ui_payload: %{kind: :process, payload: %{exit_code: code}}
            }
        end)
    }
  end

  describe "events/1 — what the worker actually did" do
    test "records file writes from write and edit, in call order" do
      msgs = [
        assistant([
          call("1", "write", %{"path" => "lib/a.ex", "content" => "x"}),
          call("2", "edit", %{"path" => "lib/b.ex", "old_string" => "a", "new_string" => "b"})
        ]),
        results([{"1", :ok}, {"2", :ok}])
      ]

      assert Provenance.events(msgs) == [{:write, "lib/a.ex"}, {:write, "lib/b.ex"}]
    end

    test "records each target file of an apply_patch from the diff" do
      patch = """
      --- a/lib/a.ex
      +++ b/lib/a.ex
      @@ -1 +1 @@
      -old
      +new
      --- a/test/a_test.exs
      +++ b/test/a_test.exs
      @@ -1 +1 @@
      -old
      +new
      """

      msgs = [
        assistant([call("1", "apply_patch", %{"patch" => patch})]),
        results([{"1", :ok}])
      ]

      assert Provenance.events(msgs) == [
               {:write, "lib/a.ex"},
               {:write, "test/a_test.exs"}
             ]
    end

    test "records bash commands" do
      msgs = [
        assistant([call("1", "bash", %{"command" => "mix compile --warnings-as-errors"})]),
        results([{"1", :ok}])
      ]

      assert Provenance.events(msgs) == [{:command, "mix compile --warnings-as-errors"}]
    end

    # Order is what separates "wrote a test, ran it, then implemented" from
    # "implemented, then bolted on a test" — the TDD rail depends on it.
    test "preserves interleaving across messages" do
      msgs = [
        assistant([call("1", "write", %{"path" => "test/a_test.exs", "content" => "x"})]),
        results([{"1", :ok}]),
        assistant([call("2", "bash", %{"command" => "mix test"})]),
        results([{"2", :ok}]),
        assistant([
          call("3", "edit", %{"path" => "lib/a.ex", "old_string" => "a", "new_string" => "b"})
        ]),
        results([{"3", :ok}])
      ]

      assert Provenance.events(msgs) == [
               {:write, "test/a_test.exs"},
               {:command, "mix test"},
               {:write, "lib/a.ex"}
             ]
    end

    test "ignores a call whose result came back as an error — it changed nothing" do
      msgs = [
        assistant([
          call("1", "edit", %{"path" => "lib/a.ex", "old_string" => "a", "new_string" => "b"}),
          call("2", "write", %{"path" => "lib/b.ex", "content" => "x"})
        ]),
        results([{"1", :error}, {"2", :ok}])
      ]

      assert Provenance.events(msgs) == [{:write, "lib/b.ex"}]
    end

    test "counts a call with no recorded result — the tool was still invoked" do
      msgs = [assistant([call("1", "bash", %{"command" => "mix test"})])]

      assert Provenance.events(msgs) == [{:command, "mix test"}]
    end

    test "ignores read-only tools and bookkeeping" do
      msgs = [
        assistant([
          call("1", "read", %{"path" => "lib/a.ex"}),
          call("2", "grep", %{"pattern" => "foo"}),
          call("3", "glob", %{"pattern" => "**/*.ex"}),
          call("4", "todo_write", %{"todos" => []})
        ]),
        results([{"1", :ok}, {"2", :ok}, {"3", :ok}, {"4", :ok}])
      ]

      assert Provenance.events(msgs) == []
    end

    # Bash returns {:ok, …} whatever the exit code — the code rides in the UI
    # payload. Without this, a worker could run the suite, watch it go red, and
    # still satisfy a rail asking "was this exercised?".
    test "distinguishes a command that failed from one that succeeded" do
      msgs = [
        assistant([
          call("1", "bash", %{"command" => "mix test"}),
          call("2", "bash", %{"command" => "mix compile"})
        ]),
        results([{"1", {:exit, 1}}, {"2", {:exit, 0}}])
      ]

      assert Provenance.events(msgs) == [
               {:failed_command, "mix test"},
               {:command, "mix compile"}
             ]
    end

    test "treats an exit-code-less command as having run" do
      msgs = [
        assistant([call("1", "bash", %{"command" => "mix test"})]),
        results([{"1", :ok}])
      ]

      assert Provenance.events(msgs) == [{:command, "mix test"}]
    end

    test "treats a tool declared mutating via :mutating_tools as a write" do
      msgs = [
        assistant([call("1", "mcp__fs__put", %{"path" => "lib/a.ex"})]),
        results([{"1", :ok}])
      ]

      assert Provenance.events(msgs, mutating_tools: ["mcp__fs__put"]) ==
               [{:write, "lib/a.ex"}]
    end
  end

  describe "footer/1 — the line the orchestrator reads" do
    test "states files changed and commands run" do
      events = [{:write, "lib/a.ex"}, {:command, "mix test"}]

      footer = Provenance.footer(events)

      assert footer =~ "lib/a.ex"
      assert footer =~ "mix test"
    end

    # The whole point: "commands run: none" is what makes an unverified change
    # visible instead of something the orchestrator can paper over in prose.
    test "says none explicitly when files changed but nothing ran" do
      footer = Provenance.footer([{:write, "lib/a.ex"}])

      assert footer =~ "commands run: none"
    end

    test "deduplicates repeated writes to the same path, keeping first-seen order" do
      events = [{:write, "lib/b.ex"}, {:write, "lib/a.ex"}, {:write, "lib/b.ex"}]

      footer = Provenance.footer(events)

      assert footer =~ "lib/b.ex, lib/a.ex"
      refute footer =~ "lib/b.ex, lib/a.ex, lib/b.ex"
    end

    test "returns nil when the worker neither changed nor ran anything" do
      assert Provenance.footer([]) == nil
    end

    # The footer rides in the orchestrator's context on every single spawn, so
    # a worker that touched 40 files must not cost 40 lines of a 128k budget.
    test "caps a long file list and reports the remainder as a count" do
      events = for i <- 1..40, do: {:write, "lib/f#{i}.ex"}

      footer = Provenance.footer(events)

      assert footer =~ "lib/f15.ex (+25 more)"
      refute footer =~ "lib/f16.ex"
    end

    test "truncates an overlong command rather than pasting a whole script" do
      footer = Provenance.footer([{:command, String.duplicate("x", 300)}])

      assert footer =~ "…"
      assert String.length(footer) < 250
    end
  end

  # The footer is a contract, not just display: it is the only channel through
  # which an orchestrator's rails learn what its workers did, since a tool
  # cannot write into loop state.
  describe "scan/1 — reading footers back out of a transcript" do
    test "round-trips the facts a footer carries" do
      events = [{:write, "lib/a.ex"}, {:command, "mix test"}, {:write, "lib/b.ex"}]

      scanned = events |> Provenance.footer() |> Provenance.scan()

      assert Provenance.changed_files(scanned) == ["lib/a.ex", "lib/b.ex"]
      assert Provenance.commands(scanned) == ["mix test"]
    end

    test "reads none back as nothing" do
      scanned = [{:write, "lib/a.ex"}] |> Provenance.footer() |> Provenance.scan()

      assert Provenance.changed_files(scanned) == ["lib/a.ex"]
      assert Provenance.commands(scanned) == []
    end

    test "aggregates every footer in a transcript, ignoring surrounding prose" do
      text = """
      Worker one did some things.
      #{Provenance.footer([{:write, "lib/a.ex"}])}
      Then the orchestrator said something.
      #{Provenance.footer([{:write, "lib/b.ex"}, {:command, "mix test"}])}
      """

      scanned = Provenance.scan(text)

      assert Provenance.changed_files(scanned) == ["lib/a.ex", "lib/b.ex"]
      assert Provenance.commands(scanned) == ["mix test"]
    end

    test "ignores the elided remainder of a capped list" do
      footer = Provenance.footer(for i <- 1..40, do: {:write, "lib/f#{i}.ex"})

      files = footer |> Provenance.scan() |> Provenance.changed_files()

      assert length(files) == 15
      refute Enum.any?(files, &(&1 =~ "more"))
    end

    test "returns nothing for text with no footer" do
      assert Provenance.scan("just a normal worker report") == []
    end
  end

  # A compile proves the code parses, not that it works. The live failure
  # compiled cleanly and raised on every page load, so "was anything actually
  # exercised" needs its own classification.
  describe "test_file?/1" do
    test "recognises test files across the ecosystems a worker might touch" do
      for path <- [
            "test/ice_web/live/appointment_calendar_live_test.exs",
            "test/support/conn_case.ex",
            "spec/models/user_spec.rb",
            "__tests__/button.js",
            "src/components/Button.test.tsx",
            "src/components/Button.spec.ts",
            "tests/test_parser.py",
            "internal/server/server_test.go"
          ] do
        assert Provenance.test_file?(path), "expected #{path} to be a test file"
      end
    end

    test "does not mistake production code for a test" do
      for path <- [
            "lib/ice_web/live/appointment_calendar_live.ex",
            "lib/ice/pervasive/resources/appointment.ex",
            "lib/my_app/test_helper_builder.ex",
            "src/latest.ts",
            "priv/static/assets/css/app.css"
          ] do
        refute Provenance.test_file?(path), "expected #{path} NOT to be a test file"
      end
    end
  end

  describe "test_command?/1" do
    test "recognises test runners" do
      for cmd <- [
            "mix test",
            "mix test test/foo_test.exs --only screenshots",
            "MIX_ENV=test mix test",
            "npm test",
            "npm run test -- --watch=false",
            "yarn test",
            "pytest -q",
            "go test ./...",
            "cargo test",
            "bundle exec rspec",
            "npx jest",
            "npx vitest run"
          ] do
        assert Provenance.test_command?(cmd), "expected #{cmd} to be a test command"
      end
    end

    test "does not count building or inspecting as testing" do
      for cmd <- [
            "mix compile --warnings-as-errors",
            "mix format",
            "ls test",
            "cat test/foo_test.exs",
            "grep -r test lib/",
            "npm install",
            "mix deps.get"
          ] do
        refute Provenance.test_command?(cmd), "expected #{cmd} NOT to count as a test run"
      end
    end
  end

  describe "changed_files/1, commands/1 and failed_commands/1" do
    test "project the event list for the rails that gate on it" do
      events = [{:write, "lib/a.ex"}, {:command, "mix test"}, {:write, "lib/a.ex"}]

      assert Provenance.changed_files(events) == ["lib/a.ex"]
      assert Provenance.commands(events) == ["mix test"]
      assert Provenance.failed_commands(events) == []
    end

    test "commands/1 counts a failed command as having run; failed_commands/1 isolates it" do
      events = [{:failed_command, "mix test"}, {:command, "mix compile"}]

      assert Provenance.commands(events) == ["mix test", "mix compile"]
      assert Provenance.failed_commands(events) == ["mix test"]
    end
  end

  # Order is the whole reason events are a list rather than a set: the same
  # files and commands mean different things depending on what came first.
  describe "test_first?/1" do
    test "true when a test was written before the source it covers" do
      events = [
        {:write, "test/a_test.exs"},
        {:failed_command, "mix test"},
        {:write, "lib/a.ex"},
        {:command, "mix test"}
      ]

      assert Provenance.test_first?(events)
    end

    test "false when the test was bolted on afterwards" do
      events = [{:write, "lib/a.ex"}, {:write, "test/a_test.exs"}, {:command, "mix test"}]

      refute Provenance.test_first?(events)
    end

    test "true when no source was written at all" do
      assert Provenance.test_first?([{:write, "test/a_test.exs"}])
      assert Provenance.test_first?([{:command, "mix test"}])
      assert Provenance.test_first?([])
    end
  end

  describe "footer/1 — the test-first advisory" do
    test "flags source edited with no test written first" do
      footer = Provenance.footer([{:write, "lib/a.ex"}, {:command, "npm test"}])

      assert footer =~ "before any test was written"
    end

    test "stays silent when the test came first" do
      footer =
        Provenance.footer([
          {:write, "test/a_test.exs"},
          {:write, "lib/a.ex"},
          {:command, "npm test"}
        ])

      refute footer =~ "before any test"
    end

    test "the advisory does not disturb scanning of the facts" do
      events = [{:write, "lib/a.ex"}, {:command, "npm test"}]

      scanned = events |> Provenance.footer() |> Provenance.scan()

      assert Provenance.changed_files(scanned) == ["lib/a.ex"]
      assert Provenance.commands(scanned) == ["npm test"]
    end
  end

  describe "failure survives the footer round-trip" do
    test "a failed command is marked and read back as failed" do
      footer = Provenance.footer([{:write, "lib/a.ex"}, {:failed_command, "mix test"}])

      assert footer =~ "mix test (failed)"

      scanned = Provenance.scan(footer)
      assert Provenance.failed_commands(scanned) == ["mix test"]
      assert Provenance.commands(scanned) == ["mix test"]
    end

    test "a successful command carries no marker" do
      footer = Provenance.footer([{:command, "mix test"}])

      refute footer =~ "failed"
      assert Provenance.failed_commands(Provenance.scan(footer)) == []
    end
  end
end
