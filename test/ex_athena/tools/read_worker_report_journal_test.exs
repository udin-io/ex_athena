defmodule ExAthena.Tools.ReadWorkerReportJournalTest do
  @moduledoc """
  The pull half of issue 215.

  A worker's journal is never pushed into the parent's transcript: the runs that
  need a worker's detail are the runs with the least context headroom left. The
  parent reads only when the pushed summary surprises it, and pays a cost
  proportional to its confusion.

  One tool, two sources. `read_worker_report` already owned the argument, the id
  validation and the path resolution; the journal is a second source on it, not
  a second tool.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Agents.Journal
  alias ExAthena.Messages.{ToolCall, ToolResult}
  alias ExAthena.ToolContext
  alias ExAthena.Tools.ReadWorkerReport

  @worker "subagent_AbC123"

  setup do
    dir = Path.join(System.tmp_dir!(), "rwr_journal_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir, ctx: ToolContext.new(cwd: dir, session_id: "sess_1")}
  end

  defp journal_events(dir, events) do
    path = Journal.path(dir, "sess_1", @worker)
    cb = Journal.compose(nil, path, cwd: dir)
    Enum.each(events, cb)
    path
  end

  defp write_call(id, path),
    do: {:tool_call, %ToolCall{id: id, name: "write", arguments: %{"path" => path}}}

  defp write_ok(id, abs_path),
    do:
      {:tool_result,
       %ToolResult{
         tool_call_id: id,
         content: "wrote",
         ui_payload: %{kind: :diff, payload: %{path: abs_path}}
       }}

  defp bash(id, cmd, code),
    do:
      {:tool_result,
       %ToolResult{
         tool_call_id: id,
         content: "exit #{code}",
         ui_payload: %{kind: :process, payload: %{command: cmd, exit_code: code}}
       }}

  defp fetch(ctx, args),
    do: ReadWorkerReport.execute(Map.merge(%{"subagent_id" => @worker}, args), ctx)

  describe "source: journal" do
    test "lists what the worker wrote, with the sizes it measured", %{dir: dir, ctx: ctx} do
      target = Path.join(dir, "plan/extract.md")
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, String.duplicate("x", 85_043))

      journal_events(dir, [
        {:iteration, 1},
        write_call("w1", "plan/extract.md"),
        write_ok("w1", target)
      ])

      assert {:ok, text} = fetch(ctx, %{"source" => "journal", "filter" => "writes"})
      assert text =~ "plan/extract.md"
      assert text =~ "85043 B"
    end

    test "lists the commands it ran and which failed", %{dir: dir, ctx: ctx} do
      journal_events(dir, [
        {:iteration, 1},
        bash("b1", "mix compile", 0),
        bash("b2", "mix test", 1)
      ])

      assert {:ok, text} = fetch(ctx, %{"source" => "journal", "filter" => "commands"})
      assert text =~ "mix compile"
      assert text =~ "mix test"
      assert text =~ "exit 1"
    end

    test "shows only the failures under the errors filter", %{dir: dir, ctx: ctx} do
      journal_events(dir, [
        bash("b1", "mix compile", 0),
        bash("b2", "mix test", 1),
        {:tool_result, %ToolResult{tool_call_id: "t1", content: "boom", is_error: true}}
      ])

      assert {:ok, text} = fetch(ctx, %{"source" => "journal", "filter" => "errors"})
      assert text =~ "mix test"
      assert text =~ "t1"
      refute text =~ "mix compile"
    end

    test "tails the last n entries", %{dir: dir, ctx: ctx} do
      journal_events(dir, for(i <- 1..30, do: {:iteration, i}))

      assert {:ok, text} = fetch(ctx, %{"source" => "journal", "filter" => "tail", "n" => 3})

      lines = text |> String.split("\n", trim: true) |> Enum.filter(&(&1 =~ "iteration"))
      assert length(lines) == 3
      assert text =~ "iteration 30"
      refute text =~ "iteration 27"
    end

    test "tail is the default view of a journal", %{dir: dir, ctx: ctx} do
      journal_events(dir, [{:iteration, 1}, {:iteration, 2}])

      assert {:ok, text} = fetch(ctx, %{"source" => "journal"})
      assert text =~ "iteration 2"
    end

    test "says plainly when a worker has no journal", %{ctx: ctx} do
      assert {:error, message} = fetch(ctx, %{"source" => "journal"})
      assert message =~ "no journal on disk"
      assert message =~ @worker
    end

    test "an unknown filter is refused rather than silently ignored", %{dir: dir, ctx: ctx} do
      journal_events(dir, [{:iteration, 1}])

      assert {:error, message} = fetch(ctx, %{"source" => "journal", "filter" => "everything"})
      assert message =~ "writes"
    end
  end

  describe "the report source is unchanged" do
    test "still reads the sidechain, and still says when there is none", %{ctx: ctx} do
      assert {:error, message} = fetch(ctx, %{})
      assert message =~ "no report on disk"
    end

    test "rejects an id that is not a worker id", %{ctx: ctx} do
      assert {:error, message} =
               ReadWorkerReport.execute(
                 %{"subagent_id" => "../../etc/passwd", "source" => "journal"},
                 ctx
               )

      assert message =~ "is not a worker id"
    end
  end
end
