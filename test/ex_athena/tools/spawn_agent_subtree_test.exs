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
  alias ExAthena.Agents.Quota
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

      # `:uncounted` — a worker killed at its deadline ran out of room; it did
      # not make a mistake the parent should be charged for.
      assert {:error, :uncounted, message} = result
      assert message =~ "timed out after"
      assert [timeout] = Regex.run(~r/after (\d+)ms/, message, capture: :all_but_first)
      assert String.to_integer(timeout) <= 2_000
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

    # The arithmetic itself lives in ExAthena.Agents.DeadlineTest.
  end

  describe "the run's worker allowance" do
    test "a run stops delegating once its allowance is spent", %{dir: dir} do
      test_pid = self()

      # Always delegates, never finishes on its own — the shape that ran away
      # live, where nothing but the depth rail stood between it and 39 agents.
      responder = fn request ->
        case Enum.find(Enum.reverse(request.messages), &(&1.role == :tool)) do
          %{tool_results: [result | _]} -> send(test_pid, {:spawn_outcome, result})
          _ -> :ok
        end

        call("spawn_agent", %{"prompt" => "another slice of work"})
      end

      worker = fn _request -> %Response{text: "did it", finish_reason: :stop, provider: :mock} end

      Loop.run("go",
        provider: :mock,
        mock: [responder: responder],
        tools: [SpawnAgent],
        cwd: dir,
        memory: false,
        max_iterations: 6,
        assigns:
          Quota.install(%{
            max_agents_per_run: 2,
            spawn_agent_opts: [provider: :mock, mock: [responder: worker], memory: false]
          })
      )

      # Two workers ran; the third request was refused rather than spawned.
      assert_receive {:spawn_outcome, %{content: "did it" <> _}}, 10_000
      assert_receive {:spawn_outcome, %{content: "did it" <> _}}, 10_000
      assert_receive {:spawn_outcome, %{is_error: true, content: refusal}}, 10_000
      assert refusal =~ "allowance"
      assert refusal =~ "2 workers"
    end
  end

  # Wall clock was a worker's only spend rail, and 30 minutes holds a lot of
  # context: live, one implementer reached 1,992,051 input tokens over 38
  # iterations and completed none of its eight sub-steps, and its replacement
  # spent another 920,357 hitting the same wall. Across 41 workers that DID
  # finish, the most any used was 701,896.
  describe "the worker spend rail" do
    test "a worker past its input-token ceiling stops and hands back findings",
         %{dir: dir} do
      # Never stops on its own; each turn adds usage until the cap trips.
      responder = fn _request ->
        %Response{
          text: "still going\nCONCLUSION: the engine lives in llama_cpp.ex",
          tool_calls: [
            %ToolCall{
              id: "c#{System.unique_integer([:positive])}",
              name: "todo_write",
              arguments: %{"todos" => [%{"content" => "keep going", "status" => "in_progress"}]}
            }
          ],
          finish_reason: :tool_calls,
          provider: :mock,
          usage: %{input_tokens: 40_000, output_tokens: 100}
        }
      end

      ctx =
        ToolContext.new(
          cwd: dir,
          assigns: %{
            spawn_agent_opts: [
              provider: :mock,
              mock: [responder: responder],
              memory: false,
              max_iterations: 50,
              max_input_tokens: 100_000
            ]
          }
        )

      # Budget exhaustion comes back `:uncounted`: the parent must READ the
      # failure and re-plan, but must not be charged a mistake for a worker
      # that ran out of tokens.
      assert {:error, :uncounted, message} = SpawnAgent.execute(%{"prompt" => "work"}, ctx)
      assert is_binary(message)
      assert message =~ "stopped on its budget"
      assert message =~ "error_max_input_tokens"
      # The point of stopping early is that the parent still gets the work.
      assert message =~ "the engine lives in llama_cpp.ex"
    end

    test "a worker under the ceiling is untouched", %{dir: dir} do
      responder = fn _request ->
        %Response{
          text: "done here",
          finish_reason: :stop,
          provider: :mock,
          usage: %{input_tokens: 40_000, output_tokens: 100}
        }
      end

      ctx =
        ToolContext.new(
          cwd: dir,
          assigns: %{
            spawn_agent_opts: [
              provider: :mock,
              mock: [responder: responder],
              memory: false,
              max_input_tokens: 100_000
            ]
          }
        )

      assert {:ok, text, _ui} = SpawnAgent.execute(%{"prompt" => "work"}, ctx)
      assert text =~ "done here"
    end
  end

  describe "timed-out workers hand back their progress" do
    defp timeout_ctx(dir, reader) do
      ToolContext.new(
        cwd: dir,
        assigns: %{
          agent_progress_reader: reader,
          spawn_agent_opts: [
            provider: :mock,
            mock: [responder: fn _r -> Process.sleep(:infinity) end],
            memory: false,
            timeout_ms: 1_000
          ]
        }
      )
    end

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

      assert {:error, :uncounted, message} = SpawnAgent.execute(%{"prompt" => "work"}, ctx)
      assert is_binary(message)
      assert message =~ "timed out"
      assert message =~ "routes live in router.ex"
      assert message =~ "map the router"
      assert message =~ "trace the auth flow"
    end

    # The live handoff read "Findings: - Let me check how the response body is
    # parsed… - Let me check how the response body is decoded…" — three
    # intentions under a heading that says findings. The conclusion protocol
    # asks for findings, the model gave intentions, and the digest presented
    # them as fact to whoever picks the step up next.
    test "labels the fallback when the worker stated no findings", %{dir: dir} do
      info = %AgentInfo{
        id: "sub",
        todos: [],
        conclusions: [
          %{text: "Let me check how the response body is parsed", source: :tail, iteration: 1},
          %{text: "Let's check decode_success_response", source: :thinking, iteration: 2}
        ]
      }

      ctx = timeout_ctx(dir, fn _id -> {:ok, info} end)

      assert {:error, :uncounted, message} = SpawnAgent.execute(%{"prompt" => "work"}, ctx)
      assert message =~ "No stated findings"
      assert message =~ "leads, not facts"
      assert message =~ "Let me check how the response body is parsed"
    end

    test "a worker that stated findings gets them presented as findings", %{dir: dir} do
      info = %AgentInfo{
        id: "sub",
        todos: [],
        conclusions: [
          %{text: "Let me check the parser", source: :tail, iteration: 1},
          %{text: "routes live in router.ex", source: :stated, iteration: 2}
        ]
      }

      ctx = timeout_ctx(dir, fn _id -> {:ok, info} end)

      assert {:error, :uncounted, message} = SpawnAgent.execute(%{"prompt" => "work"}, ctx)
      assert message =~ "Findings:"
      assert message =~ "routes live in router.ex"
      refute message =~ "leads, not facts"
      # An intention is not promoted alongside a real finding.
      refute message =~ "Let me check the parser"
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

      # Was `{:error, {:sub_agent_timeout, 1000}}` — an Elixir tuple the model
      # saw as `error: {:sub_agent_timeout, 1000}`. It now says what happened
      # and what to do about it, and is `:uncounted` like every other timeout.
      assert {:error, :uncounted, message} =
               SpawnAgent.execute(%{"prompt" => "work"}, ctx)

      assert message =~ "timed out after 1000ms"
      assert message =~ "no progress recorded"
    end
  end
end
