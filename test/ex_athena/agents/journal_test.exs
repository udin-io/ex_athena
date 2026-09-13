defmodule ExAthena.Agents.JournalTest do
  @moduledoc """
  A worker's evidence used to die with the worker.

  Session 5906635b743d: three workers wrote their deliverable, then were cut
  off. What reached the orchestrator was the worker's prose about its
  intentions; the 85 KB file it had written 90 seconds earlier went unmentioned,
  so the orchestrator re-delegated and eventually died on its mistake counter.

  Everything derived at hand-back depends on a `Result` coming back. A brutal
  kill returns none, so the journal puts the evidence on disk *while the worker
  is still alive*. These tests are about that guarantee and the cost of buying
  it.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Agents.Journal
  alias ExAthena.Messages.{ToolCall, ToolResult}
  alias ExAthena.Result

  defp journal(dir), do: Journal.path(dir, "sess_1", "subagent_AbC123")

  defp write_result(path, bytes) do
    %ToolResult{
      tool_call_id: "w1",
      content: "wrote #{bytes} bytes",
      ui_payload: %{kind: :diff, payload: %{path: path, before: nil, after: "x"}}
    }
  end

  defp bash_result(cmd, code) do
    %ToolResult{
      tool_call_id: "b1",
      content: "exit #{code}",
      ui_payload: %{kind: :process, payload: %{command: cmd, exit_code: code, stdout: ""}}
    }
  end

  describe "what is written" do
    @tag :tmp_dir
    test "one JSON object per event, in order", %{tmp_dir: dir} do
      path = journal(dir)
      cb = Journal.compose(nil, path, cwd: dir)

      cb.({:iteration, 14})
      cb.({:usage, %{input_tokens: 900, output_tokens: 40}})
      cb.({:done, %Result{finish_reason: :error_max_input_tokens}})

      assert [
               %{"ev" => "iteration", "i" => 14},
               %{"ev" => "usage", "in" => 900, "out" => 40},
               %{"ev" => "done", "finish_reason" => "error_max_input_tokens"}
             ] = Journal.read(path)
    end

    @tag :tmp_dir
    test "every line carries a timestamp", %{tmp_dir: dir} do
      path = journal(dir)
      Journal.compose(nil, path, cwd: dir).({:iteration, 1})

      assert [%{"t" => t}] = Journal.read(path)
      assert is_integer(t)
    end

    # Streaming text arrives one delta per token. Journalling it would mean one
    # filesystem write per token, and the journal would become a second copy of
    # the transcript — which is what the size cap exists to prevent.
    @tag :tmp_dir
    test "refuses streamed text and thinking", %{tmp_dir: dir} do
      path = journal(dir)
      cb = Journal.compose(nil, path, cwd: dir)

      cb.({:content, "the "})
      cb.({:thinking, "let me "})
      cb.({:iteration, 1})

      assert [%{"ev" => "iteration"}] = Journal.read(path)
    end

    @tag :tmp_dir
    test "records the path a write tool call named", %{tmp_dir: dir} do
      path = journal(dir)

      Journal.compose(nil, path, cwd: dir).(
        {:tool_call,
         %ToolCall{id: "w1", name: "write", arguments: %{"path" => "plan/a.md", "content" => "x"}}}
      )

      assert [%{"ev" => "tool_call", "name" => "write", "path" => "plan/a.md"}] =
               Journal.read(path)
    end

    @tag :tmp_dir
    test "digests tool arguments instead of storing them whole", %{tmp_dir: dir} do
      path = journal(dir)

      Journal.compose(nil, path, cwd: dir, line_chars: 80).(
        {:tool_call,
         %ToolCall{
           id: "w1",
           name: "write",
           arguments: %{"path" => "a.md", "content" => String.duplicate("x", 100_000)}
         }}
      )

      assert [%{"args" => args}] = Journal.read(path)
      assert String.length(args) <= 80
    end
  end

  # The size is taken here, in the worker's own process and directory, because
  # this is the one moment the file certainly exists. A :worktree worker's
  # directory is deleted by finalize_isolation/1 before the parent could stat
  # anything.
  describe "sizes are taken while the file still exists" do
    @tag :tmp_dir
    test "records the bytes a write left on disk", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "plan"))
      target = Path.join(dir, "plan/a.md")
      File.write!(target, String.duplicate("x", 85_043))

      path = journal(dir)
      Journal.compose(nil, path, cwd: dir).({:tool_result, write_result(target, 85_043)})

      assert [%{"ev" => "tool_result", "ok" => true, "bytes" => 85_043, "path" => ^target}] =
               Journal.read(path)
    end

    @tag :tmp_dir
    test "records a bash redirect target and its size", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "out.json"), "{}")

      path = journal(dir)

      Journal.compose(nil, path, cwd: dir).({:tool_result, bash_result("gen | tee out.json", 0)})

      assert [%{"ev" => "tool_result", "exit_code" => 0, "writes" => writes}] = Journal.read(path)
      assert writes == [%{"path" => "out.json", "bytes" => 2}]
    end

    @tag :tmp_dir
    test "claims no write it cannot find on disk", %{tmp_dir: dir} do
      path = journal(dir)

      Journal.compose(nil, path, cwd: dir).({:tool_result, bash_result("gen > ghost.json", 0)})

      assert [%{"writes" => []}] = Journal.read(path)
    end

    @tag :tmp_dir
    test "marks a failed tool result as such", %{tmp_dir: dir} do
      path = journal(dir)

      Journal.compose(nil, path, cwd: dir).(
        {:tool_result, %ToolResult{tool_call_id: "x", content: "boom", is_error: true}}
      )

      assert [%{"ev" => "tool_result", "ok" => false}] = Journal.read(path)
    end
  end

  describe "the write path" do
    # The whole feature is for the case where the writer is killed, so a line
    # that is only in a buffer is a line that was never written. Reading it from
    # a different process is the property that matters, and it is the one
    # :delayed_write would take away.
    @tag :tmp_dir
    test "a line is readable by another process as soon as the call returns", %{tmp_dir: dir} do
      path = journal(dir)
      Journal.compose(nil, path, cwd: dir).({:iteration, 7})

      assert [%{"i" => 7}] = Task.await(Task.async(fn -> Journal.read(path) end))
    end

    # The acceptance criterion: evidence must survive a worker that returns no
    # Result at all.
    @tag :tmp_dir
    test "evidence written before a brutal kill survives it", %{tmp_dir: dir} do
      path = journal(dir)
      parent = self()

      pid =
        spawn(fn ->
          cb = Journal.compose(nil, path, cwd: dir)
          cb.({:iteration, 1})

          cb.(
            {:tool_call, %ToolCall{id: "w1", name: "write", arguments: %{"path" => "plan/a.md"}}}
          )

          send(parent, :journalled)
          receive do: (:never -> :ok)
        end)

      ref = Process.monitor(pid)
      assert_receive :journalled, 2_000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

      assert [%{"ev" => "iteration"}, %{"ev" => "tool_call", "path" => "plan/a.md"}] =
               Journal.read(path)
    end

    # A process killed between formatting a line and writing it loses that line
    # outright, and a large line can be torn. NDJSON degrades one line at a
    # time; the reader must not.
    @tag :tmp_dir
    test "read/1 drops a torn final line instead of raising", %{tmp_dir: dir} do
      path = journal(dir)
      Journal.compose(nil, path, cwd: dir).({:iteration, 1})
      File.write!(path, ~s({"t":1789,"ev":"tool_ca), [:append])

      assert [%{"ev" => "iteration"}] = Journal.read(path)
    end

    @tag :tmp_dir
    test "read/1 on a journal that was never written is empty, not an error", %{tmp_dir: dir} do
      assert Journal.read(journal(dir)) == []
    end

    @tag :tmp_dir
    test "forwards every event to the wrapped callback, including the refused ones",
         %{tmp_dir: dir} do
      parent = self()
      cb = Journal.compose(fn event -> send(parent, {:seen, event}) end, journal(dir), cwd: dir)

      cb.({:content, "hi"})
      cb.({:iteration, 1})

      assert_receive {:seen, {:content, "hi"}}, 2_000
      assert_receive {:seen, {:iteration, 1}}, 2_000
    end

    @tag :tmp_dir
    test "a callback with no inner callback still journals", %{tmp_dir: dir} do
      path = journal(dir)
      assert :ok = Journal.compose(nil, path, cwd: dir).({:iteration, 1})
      assert [_] = Journal.read(path)
    end
  end

  describe "cost" do
    @tag :tmp_dir
    test "stops at the size cap and says it stopped", %{tmp_dir: dir} do
      path = journal(dir)
      cb = Journal.compose(nil, path, cwd: dir, max_bytes: 200)

      for i <- 1..50, do: cb.({:iteration, i})

      entries = Journal.read(path)
      assert File.stat!(path).size < 600
      assert List.last(entries)["ev"] == "journal_truncated"
      assert length(entries) < 50
    end

    # 0 is the repo's convention for "off" on an integer knob.
    @tag :tmp_dir
    test "a zero cap disables journalling entirely", %{tmp_dir: dir} do
      path = journal(dir)
      cb = Journal.compose(nil, path, cwd: dir, max_bytes: 0)

      cb.({:iteration, 1})

      refute File.exists?(path)
    end

    @tag :tmp_dir
    test "a journalling failure never propagates to the worker", %{tmp_dir: dir} do
      # A directory where the file should be: every write fails, the loop must
      # not care. The worker's job is the work, not the record of it.
      path = journal(dir)
      File.mkdir_p!(path)

      assert :ok = Journal.compose(nil, path, cwd: dir).({:iteration, 1})
    end
  end

  describe "path/3" do
    test "sits beside the sidechain transcript, under the parent's session" do
      assert Journal.path("/w", "sess_1", "subagent_A") ==
               "/w/.exathena/sessions/sess_1/journal/subagent_A.ndjson"
    end
  end
end
