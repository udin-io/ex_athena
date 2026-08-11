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

  defp run(worker_calls, worker_tools, dir) do
    Loop.run("do the task",
      provider: :mock,
      mock: [responder: parent_responder()],
      tools: [ExAthena.Tools.SpawnAgent],
      cwd: dir,
      memory: false,
      assigns: %{
        spawn_agent_opts: [
          provider: :mock,
          mock: [responder: worker_responder(worker_calls)],
          tools: worker_tools,
          memory: false
        ]
      },
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

  test "a read-only worker gets no provenance line at all", %{dir: dir} do
    File.write!(Path.join(dir, "a.ex"), "defmodule A do\nend\n")

    calls = [%ToolCall{id: "w1", name: "read", arguments: %{"path" => "a.ex"}}]

    assert {:ok, result} = run(calls, [ExAthena.Tools.Read], dir)

    refute report(result) =~ "[worker provenance]"
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
