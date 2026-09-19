defmodule ExAthena.Tools.ReadWorkerReportTranscriptTest do
  @moduledoc """
  The parent can read the worker's own words without spending another model
  run.

  `source: "report"` is now a SUMMARY of the run — built by
  `ExAthena.Agents.Summariser`, and therefore lossy on purpose. When the
  orchestrator needs the thing itself (an exact snippet, a path, a command),
  a summary is the wrong artifact and re-spawning the worker is a 17-minute
  answer. `source: "transcript"` is the verbatim turns, off disk, for free.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Agents.Transcript
  alias ExAthena.ToolContext
  alias ExAthena.Tools.ReadWorkerReport

  @map "ROUTES live in lib/ex_athena/web/router.ex. There is no QR library anywhere."

  setup do
    dir = Path.join(System.tmp_dir!(), "rwr_tr_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, ctx: ToolContext.new(cwd: dir, session_id: "sess")}
  end

  defp write_turns(dir, id, texts) do
    path = Transcript.path(dir, "sess", id)

    texts
    |> Enum.with_index()
    |> Enum.each(fn {text, i} ->
      Transcript.write(path, {:assistant_turn, %{i: i, text: text, purpose: :turn}})
    end)

    path
  end

  test "returns the worker's verbatim turns", %{dir: dir, ctx: ctx} do
    write_turns(dir, "subagent_abc", [@map, "and then I stopped"])

    assert {:ok, text} =
             ReadWorkerReport.execute(
               %{"subagent_id" => "subagent_abc", "source" => "transcript"},
               ctx
             )

    assert text =~ "no QR library"
    assert text =~ "and then I stopped"
  end

  test "turns are labelled, so the parent can say which one it wants",
       %{dir: dir, ctx: ctx} do
    write_turns(dir, "subagent_abc", ["first", "second"])

    assert {:ok, text} =
             ReadWorkerReport.execute(
               %{"subagent_id" => "subagent_abc", "source" => "transcript"},
               ctx
             )

    assert text =~ "turn 0"
    assert text =~ "turn 1"
  end

  # The same paging contract the other two sources use — a long transcript is
  # exactly the case this matters for.
  test "it pages with from and max_chars", %{dir: dir, ctx: ctx} do
    write_turns(dir, "subagent_abc", [String.duplicate("a", 200) <> "TAIL"])

    assert {:ok, head} =
             ReadWorkerReport.execute(
               %{"subagent_id" => "subagent_abc", "source" => "transcript", "max_chars" => 40},
               ctx
             )

    refute head =~ "TAIL"
    assert head =~ "Continue with from:"
  end

  test "a worker with no transcript says so instead of raising", %{ctx: ctx} do
    assert {:error, reason} =
             ReadWorkerReport.execute(
               %{"subagent_id" => "subagent_missing", "source" => "transcript"},
               ctx
             )

    assert reason =~ "no transcript"
  end

  # The id still arrives from the model and must never reach the filesystem
  # as given, whichever source is asked for.
  test "a traversal attempt is refused on this source too", %{ctx: ctx} do
    assert {:error, reason} =
             ReadWorkerReport.execute(
               %{"subagent_id" => "../../etc/passwd", "source" => "transcript"},
               ctx
             )

    assert reason =~ "not a worker id"
  end

  test "the tool schema offers the source, so a model can ask for it" do
    source = ReadWorkerReport.schema().properties.source

    assert "transcript" in source.enum
    assert source.description =~ "transcript"
  end
end
