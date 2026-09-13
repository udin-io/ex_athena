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

  describe "the parent can fetch a report its own cap truncated" do
    @report String.duplicate("finding. ", 400)

    defp run_with_cap(parent, worker, cap) do
      Loop.run("do a thing",
        provider: :mock,
        mock: [
          responder: parent_responder(%{"prompt" => "go", "max_result_chars" => cap})
        ],
        tools: [ExAthena.Tools.SpawnAgent, ExAthena.Tools.ReadWorkerReport],
        cwd: parent,
        memory: false,
        session_id: "parent-session",
        assigns: %{
          spawn_agent_opts: [
            cwd: worker,
            provider: :mock,
            mock: [responder: worker_responder(@report)],
            tools: [],
            memory: false
          ]
        },
        max_iterations: 5
      )
    end

    defp spawn_report(result) do
      result.messages
      |> Enum.filter(&match?(%{role: :tool}, &1))
      |> Enum.flat_map(& &1.tool_results)
      |> List.first()
      |> Map.fetch!(:content)
    end

    test "the truncation notice names a call the model can actually make",
         %{parent: parent, worker: worker} do
      assert {:ok, result} = run_with_cap(parent, worker, 200)
      report = spawn_report(result)

      assert report =~ "200 of #{String.length(@report)} characters shown"
      # The old notice said "ask for the specific part you still need" — an
      # instruction with no tool behind it. Name the tool and the offset.
      assert report =~ "read_worker_report"
      assert report =~ ~s(from: 200)
      assert report =~ "subagent_"
    end

    test "the full report comes back through read_worker_report",
         %{parent: parent, worker: worker} do
      assert {:ok, _result} = run_with_cap(parent, worker, 200)

      [file] = File.ls!(sidechain_dir(parent, "parent-session"))
      id = Path.basename(file, ".jsonl")

      ctx =
        ExAthena.ToolContext.new(cwd: parent, session_id: "parent-session")

      assert {:ok, text} =
               ExAthena.Tools.ReadWorkerReport.execute(%{"subagent_id" => id}, ctx)

      assert text =~ String.slice(@report, 0, 50)
      assert String.contains?(text, String.slice(@report, -50, 50))
    end

    test "a window can be requested from where the truncation stopped",
         %{parent: parent, worker: worker} do
      assert {:ok, _result} = run_with_cap(parent, worker, 200)

      [file] = File.ls!(sidechain_dir(parent, "parent-session"))
      id = Path.basename(file, ".jsonl")
      ctx = ExAthena.ToolContext.new(cwd: parent, session_id: "parent-session")

      assert {:ok, text} =
               ExAthena.Tools.ReadWorkerReport.execute(
                 %{"subagent_id" => id, "from" => 200, "max_chars" => 50},
                 ctx
               )

      assert text =~ String.slice(@report, 200, 50)
      refute text =~ String.slice(@report, 0, 50)
    end

    test "an unknown worker says so instead of raising", %{parent: parent} do
      ctx = ExAthena.ToolContext.new(cwd: parent, session_id: "parent-session")

      assert {:error, reason} =
               ExAthena.Tools.ReadWorkerReport.execute(
                 %{"subagent_id" => "subagent_neverExisted"},
                 ctx
               )

      assert reason =~ "no report"
    end

    # The id comes from the model, so it must never reach the filesystem as
    # given.
    test "a traversal attempt is refused, not resolved", %{parent: parent} do
      ctx = ExAthena.ToolContext.new(cwd: parent, session_id: "parent-session")

      for bad <- ["../../etc/passwd", "subagent_../../x", "/etc/passwd", "sub agent"] do
        assert {:error, reason} =
                 ExAthena.Tools.ReadWorkerReport.execute(%{"subagent_id" => bad}, ctx)

        assert reason =~ "not a worker id"
      end
    end
  end

  # read_worker_report answers "what did MY worker say". A leaf worker has no
  # workers, so the tool is schema noise there — it is granted exactly when
  # spawn_agent is, and never inherited from an agent definition's ceiling.
  describe "the tool is scoped to whoever can delegate" do
    defp worker_tools(parent, worker, depth) do
      ref = make_ref()
      test_pid = self()

      spy = fn _req ->
        send(test_pid, {ref, :worker_ran})
        %Response{text: "done", finish_reason: :stop, provider: :mock}
      end

      {:ok, _} =
        Loop.run("do a thing",
          provider: :mock,
          mock: [responder: parent_responder(%{"prompt" => "go"})],
          tools: [ExAthena.Tools.SpawnAgent],
          cwd: parent,
          memory: false,
          session_id: "parent-session",
          assigns: %{
            agent_depth: depth,
            max_agent_depth: 2,
            spawn_agent_opts: [
              cwd: worker,
              provider: :mock,
              mock: [responder: spy],
              memory: false,
              on_event: fn _ -> :ok end
            ]
          },
          max_iterations: 5
        )

      assert_receive {^ref, :worker_ran}, 2_000

      [file] = File.ls!(sidechain_dir(parent, "parent-session"))

      Path.join([parent, ".exathena", "sessions", "parent-session", "sidechains", file])
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["opts", "tools"])
    end

    test "a worker that may still delegate gets it", %{parent: parent, worker: worker} do
      assert worker_tools(parent, worker, 0) =~ "read_worker_report"
    end

    test "a worker at the nesting ceiling does not", %{parent: parent, worker: worker} do
      tools = worker_tools(parent, worker, 1)
      refute tools =~ "read_worker_report"
      refute tools =~ "spawn_agent"
    end
  end
end
