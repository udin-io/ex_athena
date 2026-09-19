defmodule ExAthena.Tools.SpawnAgentTranscriptTest do
  @moduledoc """
  The acceptance criterion for issue 251's first half: a worker's prose is on
  disk as it is produced, and survives what destroys it in memory.

  Web session `0f73f270b133`: worker `subagent_fqB0WqCf` wrote a codebase map,
  then signed off with 545 characters saying the map had been "delivered in the
  previous turn". The map was the only copy, it was mid-conversation, and
  compaction had replaced it. Both the parent and `read_worker_report` got the
  sign-off.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Agents.Transcript
  alias ExAthena.Messages.ToolCall
  alias ExAthena.{Loop, Response}

  @map String.duplicate("lib/ex_athena/router.ex defines the routes. ", 40)
  @signoff "The report above is the complete deliverable, delivered in the previous turn."

  setup do
    base = Path.join(System.tmp_dir!(), "spawn_tr_#{System.unique_integer([:positive])}")
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

  # The live shape: the real report lands mid-run, the final message is a
  # pointer at it.
  defp summarises_itself do
    fn request ->
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        %Response{text: @signoff, finish_reason: :stop, provider: :mock}
      else
        %Response{
          text: @map,
          tool_calls: [
            %ToolCall{
              id: "w1",
              name: "write",
              arguments: %{"path" => "notes.md", "content" => "x"}
            }
          ],
          finish_reason: :tool_calls,
          provider: :mock
        }
      end
    end
  end

  defp run(parent, worker, responder) do
    Loop.run("map the codebase",
      provider: :mock,
      mock: [responder: parent_responder(%{"prompt" => "map it"})],
      tools: [ExAthena.Tools.SpawnAgent],
      cwd: parent,
      memory: false,
      session_id: "parent-session",
      assigns: %{
        spawn_agent_opts: [
          cwd: worker,
          provider: :mock,
          mock: [responder: responder],
          tools: ["write"],
          memory: false,
          # Off, so this test is about the transcript alone.
          summarise_reports: false
        ]
      },
      max_iterations: 5
    )
  end

  defp transcript_dir(cwd, session),
    do: Path.join([cwd, ".exathena", "sessions", session, "transcript"])

  test "the turn a worker later summarises away is on disk in full",
       %{parent: parent, worker: worker} do
    assert {:ok, _} = run(parent, worker, summarises_itself())

    assert [file] = File.ls!(transcript_dir(parent, "parent-session"))

    texts =
      transcript_dir(parent, "parent-session")
      |> Path.join(file)
      |> Transcript.read()
      |> Enum.map(& &1["text"])

    # Both turns, in order: the real report AND the sign-off that replaced it.
    assert texts == [@map, @signoff]
  end

  # Same argument as the journal and the sidechain (issue 216): a
  # `:worktree` worker's own directory is removed moments after it finishes,
  # so a transcript written there is written into a grave.
  test "it lands under the parent's cwd, never the worker's",
       %{parent: parent, worker: worker} do
    assert {:ok, _} = run(parent, worker, summarises_itself())

    assert [_] = File.ls!(transcript_dir(parent, "parent-session"))
    refute File.dir?(transcript_dir(worker, "parent-session"))
  end

  test "the file is named for the worker, so the parent can address it",
       %{parent: parent, worker: worker} do
    assert {:ok, _} = run(parent, worker, summarises_itself())

    assert [file] = File.ls!(transcript_dir(parent, "parent-session"))
    assert String.starts_with?(file, "subagent_")
    assert String.ends_with?(file, ".ndjson")
  end
end
