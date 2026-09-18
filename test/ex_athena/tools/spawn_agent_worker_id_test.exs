defmodule ExAthena.Tools.SpawnAgentWorkerIdTest do
  @moduledoc """
  Issue 245. A spawn result carries the allowance line ("worker N of M...")
  but never the worker's own id, so an orchestrator that wants to re-read a
  report or journal has nothing to pass to `read_worker_report`.

  Web session 272a4251558c hit exactly this: the allowance line read
  "worker 1 of 24 this run; 23 left.", the orchestrator guessed `subagent_id:
  "1"`, then `"worker_1"`, burned two mistakes against a cap of three, and
  re-spawned a worker to redo work it already had.

  The fix extends that same line with the id, on every result path — success,
  timeout, handback, and error — so there is no line left to guess from.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Response, ToolContext}
  alias ExAthena.Agents.Quota
  alias ExAthena.Tools.{ReadWorkerReport, SpawnAgent}

  defmodule RefusingMode do
    @moduledoc false
    @behaviour ExAthena.Loop.Mode

    @impl true
    def init(_state), do: {:error, :mode_refused}

    @impl true
    def iterate(state), do: {:halt, state}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "spawn_worker_id_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp bounded(extra), do: Quota.install(%{max_agents_per_run: 24}) |> Map.merge(extra)

  defp ctx(dir, assigns) do
    ToolContext.new(
      cwd: dir,
      session_id: "sess_#{System.unique_integer([:positive])}",
      assigns: assigns
    )
  end

  # Mirrors how a model would have to parse the line: pull the id out with a
  # regex, exactly the shape a small model can match.
  defp worker_id!(text) do
    assert [_, id] = Regex.run(~r/Worker id: (subagent_[A-Za-z0-9_-]+)/, text)
    id
  end

  test "a successful spawn names a worker id read_worker_report accepts", %{dir: dir} do
    worker = fn _req -> %Response{text: "done", finish_reason: :stop, provider: :mock} end

    context =
      ctx(
        dir,
        bounded(%{spawn_agent_opts: [provider: :mock, mock: [responder: worker], memory: false]})
      )

    assert {:ok, text, _ui} = SpawnAgent.execute(%{"prompt" => "do the thing"}, context)

    assert text =~ "worker 1 of 24 this run; 23 left."
    id = worker_id!(text)

    # Fed straight from the rendered line back into the tool: it must be
    # ACCEPTED (not refused for its shape), and it must resolve to the report
    # this very spawn just wrote.
    assert {:ok, report} = ReadWorkerReport.execute(%{"subagent_id" => id}, context)
    assert report =~ "done"
  end

  test "a timed-out worker still names its id", %{dir: dir} do
    blocked = fn _req -> receive do: (:never -> :never) end

    context =
      ctx(
        dir,
        bounded(%{
          spawn_agent_opts: [
            provider: :mock,
            mock: [responder: blocked],
            memory: false,
            timeout_ms: 1,
            max_iterations: 1
          ]
        })
      )

    assert {:error, :uncounted, text} =
             SpawnAgent.execute(%{"prompt" => "do the thing"}, context)

    assert text =~ ~r/timed out/i
    worker_id!(text)
  end

  @tag :capture_log
  test "a crashed worker still names its id", %{dir: dir} do
    crashing = fn _req -> exit(:boom) end

    context =
      ctx(
        dir,
        bounded(%{
          spawn_agent_opts: [
            provider: :mock,
            mock: [responder: crashing],
            memory: false,
            max_iterations: 5
          ]
        })
      )

    assert {:error, :uncounted, text} =
             SpawnAgent.execute(%{"prompt" => "do the thing"}, context)

    assert text =~ "crashed"
    worker_id!(text)
  end

  test "a worker never started still names its id", %{dir: dir} do
    context =
      ctx(
        dir,
        bounded(%{
          spawn_agent_opts: [
            mode: RefusingMode,
            provider: :mock,
            mock: [
              responder: fn _req ->
                %Response{text: "hi", finish_reason: :stop, provider: :mock}
              end
            ],
            memory: false
          ]
        })
      )

    assert {:error, text} = SpawnAgent.execute(%{"prompt" => "do the thing"}, context)

    assert text =~ "never started"
    worker_id!(text)
  end

  test "a worker handed back on its time budget still names its id", %{dir: dir} do
    Application.put_env(:ex_athena, :loop, handback_at_percent: 0)
    on_exit(fn -> Application.delete_env(:ex_athena, :loop) end)

    worker = fn _req ->
      %Response{
        text: "PRODUCED: nothing yet.",
        tool_calls: [],
        finish_reason: :stop,
        provider: :mock
      }
    end

    context =
      ctx(
        dir,
        bounded(%{
          spawn_agent_opts: [
            provider: :mock,
            mock: [responder: worker],
            tools: [],
            memory: false,
            max_iterations: 5
          ]
        })
      )

    assert {:ok, text, _ui} = SpawnAgent.execute(%{"prompt" => "do the thing"}, context)

    assert text =~ ~r/time budget/i
    worker_id!(text)
  end

  # A run with no counter installed (`Quota.remaining/1` is `:unbounded`) has
  # no count to report, but it still spawned a real worker with a real id —
  # the id must not be conditioned on the allowance existing.
  test "an unbounded run still names the worker id", %{dir: dir} do
    worker = fn _req -> %Response{text: "done", finish_reason: :stop, provider: :mock} end

    context =
      ctx(dir, %{spawn_agent_opts: [provider: :mock, mock: [responder: worker], memory: false]})

    assert {:ok, text, _ui} = SpawnAgent.execute(%{"prompt" => "do the thing"}, context)

    refute text =~ "this run;"
    worker_id!(text)
  end
end
