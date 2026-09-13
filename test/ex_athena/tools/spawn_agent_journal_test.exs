defmodule ExAthena.Tools.SpawnAgentJournalTest do
  @moduledoc """
  The acceptance criterion for issue 215.

  A worker that writes a large file and is then killed outright returns no
  `Result` at all — no report, no conclusions, no messages for `Provenance` to
  read. Session 5906635b743d hit this three times and re-delegated every one,
  while the finished deliverables sat on disk.

  The journal is written by the worker as it works, so the parent can still say
  what its dead worker produced.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Agents.Journal
  alias ExAthena.Messages.ToolCall
  alias ExAthena.{Response, ToolContext}
  alias ExAthena.Tools.SpawnAgent

  setup do
    dir = Path.join(System.tmp_dir!(), "spawn_journal_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, session: "sess_#{System.unique_integer([:positive])}"}
  end

  # Writes its deliverable on the first turn, then hangs until the deadline
  # kills it — the shape of the three workers that were lost.
  defp writes_then_hangs(content) do
    fn request ->
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        Process.sleep(:infinity)
      else
        %Response{
          text: "",
          tool_calls: [
            %ToolCall{
              id: "w1",
              name: "write",
              arguments: %{"path" => "plan/extract.md", "content" => content}
            }
          ],
          finish_reason: :tool_calls,
          provider: :mock
        }
      end
    end
  end

  defp ctx(dir, session, responder) do
    ToolContext.new(
      cwd: dir,
      session_id: session,
      assigns: %{
        spawn_agent_opts: [
          provider: :mock,
          mock: [responder: responder],
          tools: ["write"],
          memory: false,
          timeout_ms: 1_000
        ]
      }
    )
  end

  test "a killed worker still reports the file it wrote, and its size", %{
    dir: dir,
    session: session
  } do
    content = String.duplicate("x", 85_043)

    assert {:error, :uncounted, message} =
             SpawnAgent.execute(
               %{"prompt" => "extract the guides"},
               ctx(dir, session, writes_then_hangs(content))
             )

    assert message =~ "timed out"
    assert message =~ "[worker provenance]"
    assert message =~ "plan/extract.md"
    assert message =~ "85043 B"
  end

  test "a killed worker that produced nothing still says so plainly", %{
    dir: dir,
    session: session
  } do
    assert {:error, :uncounted, message} =
             SpawnAgent.execute(
               %{"prompt" => "think about it"},
               ctx(dir, session, fn _req -> Process.sleep(:infinity) end)
             )

    assert message =~ "timed out"
    assert message =~ "no progress recorded"
    refute message =~ "[worker provenance]"
  end

  test "the journal is written under the parent's session, per worker", %{
    dir: dir,
    session: session
  } do
    SpawnAgent.execute(
      %{"prompt" => "extract the guides"},
      ctx(dir, session, writes_then_hangs("hello"))
    )

    journal_dir = Path.join([dir, ".exathena", "sessions", session, "journal"])

    assert [file] = File.ls!(journal_dir)
    assert String.ends_with?(file, ".ndjson")

    records = Journal.read(Path.join(journal_dir, file))

    assert Enum.any?(records, &match?(%{"ev" => "iteration"}, &1))

    assert Enum.any?(
             records,
             &match?(%{"ev" => "tool_call", "name" => "write", "path" => "plan/extract.md"}, &1)
           )

    # Never a second copy of the transcript.
    refute Enum.any?(records, &match?(%{"ev" => "content"}, &1))
    refute Enum.any?(records, &match?(%{"ev" => "thinking"}, &1))
  end

  # A worker that finishes normally is served by its Result; the journal is
  # still written, because whether a worker will die is not knowable in advance.
  test "a worker that finishes cleanly is journalled too", %{dir: dir, session: session} do
    responder = fn _req -> %Response{text: "done", finish_reason: :stop, provider: :mock} end

    assert {:ok, _text, _ui} =
             SpawnAgent.execute(%{"prompt" => "quick job"}, ctx(dir, session, responder))

    journal_dir = Path.join([dir, ".exathena", "sessions", session, "journal"])
    assert [file] = File.ls!(journal_dir)

    records = Journal.read(Path.join(journal_dir, file))
    assert Enum.any?(records, &match?(%{"ev" => "done", "finish_reason" => "stop"}, &1))
  end
end
