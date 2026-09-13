defmodule ExAthena.Tools.SpawnAgentProvenanceTest do
  @moduledoc """
  A worker's report is the ONLY thing that enters the orchestrator's context,
  and it is free text — so an orchestrator cannot tell "the worker ran the
  build" from "the worker said it built". A live run ended with the
  deliverable "The app compiles cleanly with no new errors" for a run in which
  no build command was ever executed.

  SpawnAgent appends a factual provenance line derived from the worker's own
  tool calls, so the claim is checkable rather than taken on trust.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "spawn_prov_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
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
                id: "c1",
                name: "spawn_agent",
                arguments: %{
                  "prompt" => "do the work",
                  "objective" => "do the work",
                  "expected_output" => "a report",
                  "tool_guidance" => "use write",
                  "boundaries" => "stay in cwd"
                }
              }
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "all done", finish_reason: :stop, provider: :mock}
      end
    end
  end

  # Worker: makes `calls` on its first turn, then reports success in prose.
  defp worker_responder(calls) do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "working",
            tool_calls: calls,
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{
            text: "Done. Everything compiles cleanly with no new errors.",
            finish_reason: :stop,
            provider: :mock
          }
      end
    end
  end

  defp run(worker_calls, worker_tools, dir, extra_worker_opts \\ []) do
    worker_opts =
      Keyword.merge(
        [
          provider: :mock,
          mock: [responder: worker_responder(worker_calls)],
          tools: worker_tools,
          memory: false
        ],
        extra_worker_opts
      )

    Loop.run("do the task",
      provider: :mock,
      mock: [responder: parent_responder()],
      tools: [ExAthena.Tools.SpawnAgent],
      cwd: dir,
      memory: false,
      assigns: %{spawn_agent_opts: worker_opts},
      max_iterations: 5
    )
  end

  defp report(result) do
    result.messages
    |> Enum.filter(&match?(%{role: :tool}, &1))
    |> Enum.flat_map(& &1.tool_results)
    |> List.first()
    |> Map.fetch!(:content)
  end

  test "a worker that changed a file but ran nothing reports exactly that", %{dir: dir} do
    calls = [
      %ToolCall{
        id: "w1",
        name: "write",
        arguments: %{"path" => "lib/a.ex", "content" => "defmodule A do\nend\n"}
      }
    ]

    assert {:ok, result} = run(calls, [ExAthena.Tools.Write], dir)

    report = report(result)

    # The worker's prose claim survives...
    assert report =~ "compiles cleanly"
    # ...but is now sitting next to the facts that contradict it.
    assert report =~ "[worker provenance]"
    assert report =~ "lib/a.ex"
    assert report =~ "commands run: none"
  end

  # The size is read off the disk at hand-back, not taken from the worker's
  # word, which is what makes the footer evidence rather than a second claim.
  test "sizes what the worker wrote, from disk", %{dir: dir} do
    content = String.duplicate("x", 1234)

    calls = [
      %ToolCall{id: "w1", name: "write", arguments: %{"path" => "lib/a.ex", "content" => content}}
    ]

    assert {:ok, result} = run(calls, [ExAthena.Tools.Write], dir)

    assert report(result) =~ "lib/a.ex (1234 B)"
  end

  test "a read-only worker gets no provenance line at all", %{dir: dir} do
    File.write!(Path.join(dir, "a.ex"), "defmodule A do\nend\n")

    calls = [%ToolCall{id: "w1", name: "read", arguments: %{"path" => "a.ex"}}]

    assert {:ok, result} = run(calls, [ExAthena.Tools.Read], dir)

    refute report(result) =~ "[worker provenance]"
  end

  # A bare "…" told the orchestrator nothing had been lost, so it re-requested
  # whole files instead of the missing part.
  describe "truncate_result/2" do
    test "says how much was cut, and what to do about it" do
      out = ExAthena.Tools.SpawnAgent.truncate_result(String.duplicate("x", 100), 40)

      assert out =~ "40 of 100 characters shown"
      assert out =~ ~r/do not re-request the whole/i
      assert String.starts_with?(out, String.duplicate("x", 40))
    end

    test "leaves a report that fits completely alone" do
      assert ExAthena.Tools.SpawnAgent.truncate_result("short", 40) == "short"
      refute ExAthena.Tools.SpawnAgent.truncate_result("short", 40) =~ "truncated"
    end
  end

  # Session 5906635b743d: three workers wrote their file, then stopped on
  # `error_max_input_tokens` during a verification pass. Each handed back
  # "No stated findings — the worker recorded only intentions", and the
  # 85,043-byte file it had written 90 seconds earlier went unmentioned. The
  # orchestrator re-delegated, failed again, and died on its mistake counter.
  #
  # The worker's Result — including its full `messages` — survives every loop
  # termination (only a brutal kill destroys it), so Provenance could always
  # read it. It simply was never asked to on this branch.
  describe "a worker cut off before it reported" do
    test "hands back the files it wrote, not just what it said", %{dir: dir} do
      calls = [
        %ToolCall{
          id: "w1",
          name: "write",
          arguments: %{"path" => "plan/extract.md", "content" => String.duplicate("x", 400)}
        }
      ]

      assert {:ok, result} = run(calls, [ExAthena.Tools.Write], dir, max_iterations: 1)

      report = report(result)

      # It is still reported as a failure — the parent has to know it lost the step.
      assert report =~ "worker stopped on its budget"
      # ...but the evidence of what it managed to do now rides along.
      assert report =~ "[worker provenance]"
      assert report =~ "plan/extract.md"
    end

    test "a cut-off worker that changed nothing gets no provenance line", %{dir: dir} do
      File.write!(Path.join(dir, "a.ex"), "defmodule A do\nend\n")
      calls = [%ToolCall{id: "w1", name: "read", arguments: %{"path" => "a.ex"}}]

      assert {:ok, result} = run(calls, [ExAthena.Tools.Read], dir, max_iterations: 1)

      report = report(result)
      assert report =~ "worker stopped on its budget"
      refute report =~ "[worker provenance]"
    end
  end

  test "the provenance line survives truncation of a long worker report", %{dir: dir} do
    calls = [
      %ToolCall{
        id: "w1",
        name: "write",
        arguments: %{"path" => "lib/a.ex", "content" => String.duplicate("x", 200)}
      }
    ]

    assert {:ok, result} = run(calls, [ExAthena.Tools.Write], dir)

    # Truncation caps the worker's prose; the footer is appended after it, so
    # a verbose worker can never push its own accountability out of context.
    assert report(result) =~ "[worker provenance]"
  end
end
