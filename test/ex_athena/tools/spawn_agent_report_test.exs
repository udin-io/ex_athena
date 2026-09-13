defmodule ExAthena.Tools.SpawnAgentReportTest do
  @moduledoc """
  A worker's full report survives its own hand-back, and the parent can get it
  back without re-running the worker.

  Session 5906635b743d: worker `Ut1hUSMB` produced a 21,697-character
  extraction. The orchestrator had passed `max_result_chars: 2000` — correctly,
  because the brief told the worker to write a file and reply with a short
  confirmation — the worker replied in chat instead, and the parent's own cap
  destroyed the payload. The orchestrator then recorded "the data has been lost
  from my context" and re-delegated.

  The full text was never actually lost: `Agents.Sidechain.write/1` persists it
  before either result branch runs. What was missing was an address the model
  could act on, and a tool to act on it with.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    base = Path.join(System.tmp_dir!(), "spawn_report_#{System.unique_integer([:positive])}")
    parent = Path.join(base, "parent")
    worker = Path.join(base, "worker")
    File.mkdir_p!(parent)
    File.mkdir_p!(worker)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base, parent: parent, worker: worker}
  end

  defp parent_responder(spawn_args) do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          %Response{
            text: "delegating",
            tool_calls: [%ToolCall{id: "c1", name: "spawn_agent", arguments: spawn_args}],
            finish_reason: :tool_calls,
            provider: :mock
          }

        _ ->
          %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end
  end

  defp worker_responder(report) do
    fn _req -> %Response{text: report, finish_reason: :stop, provider: :mock} end
  end

  defp sidechain_dir(cwd, session_id),
    do: Path.join([cwd, ".exathena", "sessions", session_id, "sidechains"])

  describe "the sidechain follows the parent, not the worker" do
    # A `:worktree`-isolated worker runs in an ephemeral directory that
    # `finalize_isolation/1` deletes moments after the sidechain is written
    # (write at spawn_agent.ex:368, `git worktree remove --force` at :381).
    # Writing the transcript there means writing it into a grave. The worker's
    # own cwd arrives via `sub_opts[:cwd]`, so a host-supplied cwd reproduces
    # the same path without needing a git repo.
    test "the transcript lands under the parent's cwd even when the worker ran elsewhere",
         %{parent: parent, worker: worker} do
      {:ok, _} =
        Loop.run("do a thing",
          provider: :mock,
          mock: [responder: parent_responder(%{"prompt" => "go"})],
          tools: [ExAthena.Tools.SpawnAgent],
          cwd: parent,
          memory: false,
          session_id: "parent-session",
          assigns: %{
            spawn_agent_opts: [
              cwd: worker,
              provider: :mock,
              mock: [responder: worker_responder("worker report")],
              tools: [],
              memory: false
            ]
          },
          max_iterations: 5
        )

      assert [file] = File.ls!(sidechain_dir(parent, "parent-session"))
      assert String.ends_with?(file, ".jsonl")
      refute File.dir?(sidechain_dir(worker, "parent-session"))
    end
  end
end
