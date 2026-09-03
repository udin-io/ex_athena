defmodule ExAthena.Tools.SpawnAgentSubtreeTest do
  @moduledoc """
  Subagent subtree lifecycle.

  Observed live (session 0211188215f3): a depth-1 explore worker hit its 30
  minute timeout and was killed, but its 33 descendants kept running for
  another 69 minutes — 1.07M input / 259k output tokens whose results could
  never reach anyone, queued ahead of the orchestrator's real work on a
  single-slot local provider. Three things were wrong and each is pinned here:

    * a worker's descendants did not share its fate (they hung off a global
      `Task.Supervisor`, so killing the worker orphaned them);
    * the timeout was re-granted in full at every level, and evaporated
      entirely once the process enforcing it was killed;
    * a timed-out worker's findings were discarded outright, while the
      `error_max_turns` path handed the same findings back as a digest.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, ToolContext}
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Orchestrator.AgentInfo
  alias ExAthena.Tools.SpawnAgent

  setup do
    dir = Path.join(System.tmp_dir!(), "sub_tree_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp call(name, args) do
    %Response{
      text: "",
      tool_calls: [
        %ToolCall{
          id: "c#{System.unique_integer([:positive])}",
          name: name,
          arguments: args
        }
      ],
      finish_reason: :tool_calls,
      provider: :mock
    }
  end

  # One responder drives every level of the tree; which branch it takes is
  # decided by the opening prompt it was spawned with. The mock provider calls
  # it inside the agent's own loop process, so `self()` here IS the agent.
  defp nesting_responder(test_pid) do
    fn request ->
      text = Enum.map_join(request.messages, "\n", &(&1.content || ""))

      cond do
        Enum.any?(request.messages, &(&1.role == :tool)) ->
          %Response{text: "done", finish_reason: :stop, provider: :mock}

        String.contains?(text, "LEVEL2") ->
          send(test_pid, {:blocked, :level2, self()})
          Process.sleep(:infinity)

        String.contains?(text, "LEVEL1") ->
          send(test_pid, {:blocked, :level1, self()})
          call("spawn_agent", %{"prompt" => "LEVEL2 — block here"})

        true ->
          call("spawn_agent", %{"prompt" => "LEVEL1 — nest one more level"})
      end
    end
  end

  describe "subtree fate-sharing" do
    test "killing a run reaps every descendant, not just its direct workers", %{dir: dir} do
      responder = nesting_responder(self())

      # Plain spawn, not Task.async: the test process must survive killing it.
      run =
        spawn(fn ->
          Loop.run("go",
            provider: :mock,
            mock: [responder: responder],
            tools: [SpawnAgent],
            cwd: dir,
            memory: false,
            max_iterations: 5,
            assigns: %{
              spawn_agent_opts: [
                provider: :mock,
                mock: [responder: responder],
                memory: false
              ]
            }
          )
        end)

      assert_receive {:blocked, :level1, level1}, 10_000
      assert_receive {:blocked, :level2, level2}, 10_000

      ref1 = Process.monitor(level1)
      ref2 = Process.monitor(level2)

      Process.exit(run, :kill)

      # The grandchild is the one that used to survive: it is two links away
      # from the process that died.
      assert_receive {:DOWN, ^ref1, :process, ^level1, _}, 10_000
      assert_receive {:DOWN, ^ref2, :process, ^level2, _}, 10_000
    end
  end

  describe "deadline inheritance" do
    test "a worker's timeout is clamped by the deadline its parent already had", %{dir: dir} do
      responder = fn _request -> Process.sleep(:infinity) end

      ctx =
        ToolContext.new(
          cwd: dir,
          assigns: %{
            # 60s configured, but the run only has 2s of deadline left. The
            # deadline wins — before this, every level was granted the full
            # timeout afresh and a depth-4 worker could outlive its root.
            agent_deadline_at: System.monotonic_time(:millisecond) + 2_000,
            spawn_agent_opts: [
              provider: :mock,
              mock: [responder: responder],
              memory: false,
              timeout_ms: 60_000
            ]
          }
        )

      {elapsed_us, result} =
        :timer.tc(fn -> SpawnAgent.execute(%{"prompt" => "work"}, ctx) end)

      assert {:error, {:sub_agent_timeout, timeout}} = result
      assert timeout <= 2_000
      assert div(elapsed_us, 1_000) < 20_000
    end

    test "a spawn with no deadline left is refused rather than started", %{dir: dir} do
      ctx =
        ToolContext.new(
          cwd: dir,
          assigns: %{
            agent_deadline_at: System.monotonic_time(:millisecond) - 1,
            spawn_agent_opts: [provider: :mock, mock: [text: "hi"], memory: false]
          }
        )

      assert {:error, message} = SpawnAgent.execute(%{"prompt" => "work"}, ctx)
      assert message =~ "deadline"
    end

    test "the deadline is the earlier of the parent's and the configured timeout" do
      now = 1_000_000

      # No inherited deadline: the configured timeout stands on its own.
      assert {:ok, deadline} = SpawnAgent.deadline_for(%{}, 30_000, now)
      assert deadline == now + 30_000

      # A nearer parent deadline wins — this is what stops a nested worker
      # from being re-granted the full timeout at every level.
      assert {:ok, deadline} =
               SpawnAgent.deadline_for(%{agent_deadline_at: now + 5_000}, 30_000, now)

      assert deadline == now + 5_000

      # A parent deadline further out than our own budget does not extend us.
      assert {:ok, deadline} =
               SpawnAgent.deadline_for(%{agent_deadline_at: now + 90_000}, 30_000, now)

      assert deadline == now + 30_000

      # Already past: refuse rather than start a worker that cannot finish.
      assert :exhausted = SpawnAgent.deadline_for(%{agent_deadline_at: now}, 30_000, now)
      assert :exhausted = SpawnAgent.deadline_for(%{agent_deadline_at: now - 1}, 30_000, now)
    end
  end

  describe "timed-out workers hand back their progress" do
    test "the error carries the worker's todos and findings", %{dir: dir} do
      info = %AgentInfo{
        id: "sub",
        todos: [
          %{id: 1, content: "map the router", status: :completed, active_form: nil},
          %{id: 2, content: "trace the auth flow", status: :in_progress, active_form: nil}
        ],
        conclusions: [%{text: "routes live in router.ex", source: :stated, iteration: 1}]
      }

      ctx =
        ToolContext.new(
          cwd: dir,
          assigns: %{
            agent_progress_reader: fn _id -> {:ok, info} end,
            spawn_agent_opts: [
              provider: :mock,
              mock: [responder: fn _r -> Process.sleep(:infinity) end],
              memory: false,
              timeout_ms: 1_000
            ]
          }
        )

      assert {:error, message} = SpawnAgent.execute(%{"prompt" => "work"}, ctx)
      assert is_binary(message)
      assert message =~ "timed out"
      assert message =~ "routes live in router.ex"
      assert message =~ "map the router"
      assert message =~ "trace the auth flow"
    end

    test "falls back to the bare timeout when no progress was recorded", %{dir: dir} do
      ctx =
        ToolContext.new(
          cwd: dir,
          assigns: %{
            agent_progress_reader: fn _id -> {:error, :not_found} end,
            spawn_agent_opts: [
              provider: :mock,
              mock: [responder: fn _r -> Process.sleep(:infinity) end],
              memory: false,
              timeout_ms: 1_000
            ]
          }
        )

      assert {:error, {:sub_agent_timeout, 1_000}} =
               SpawnAgent.execute(%{"prompt" => "work"}, ctx)
    end
  end
end
