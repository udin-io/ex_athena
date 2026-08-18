defmodule ExAthena.Loop.InferenceInstrumentationTest do
  @moduledoc """
  Issue #136 — every mode-internal inference (Reflexion critique,
  PlanAndSolve planning, conclusion distillation, compaction summary) must
  go through the same instrumented path as ReAct's main turn: ChatParams
  hooks, the `[:ex_athena, :chat]` telemetry span, full cost extraction
  (including input_cost/output_cost splits), budget folding, and `{:usage}`
  events.

  Starvation policy: internal micro-calls (critique, distillation, summary)
  must NOT surface `:error_thinking_starved` — the kernel's escalation
  4x-es the run's request-template `max_tokens` and re-runs the whole
  iteration, a disproportionate response to a fixed 256-token utility call.
  A starved micro-call is simply a failed micro-call with a graceful
  fallback. The planning turn IS a full turn, so it keeps surfacing.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall

  @reflection_marker "Reflect on your last step"

  # ── Helpers ───────────────────────────────────────────────────────

  defp collector(pid) do
    fn event -> send(pid, {:event, event}) end
  end

  # Reflexion scenario: turn 1 makes a tool call (usage 11 tokens), the
  # critique follows (usage 10 tokens), turn 2 finishes (usage 22 tokens).
  defp reflexion_responder(test_pid, critique_response) do
    counter = :counters.new(1, [:atomics])

    fn request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      # The critique request ENDS with the reflection prompt (later main
      # turns merely carry it somewhere in history).
      reflection? =
        case List.last(request.messages) do
          %{content: c} when is_binary(c) -> String.contains?(c, @reflection_marker)
          _ -> false
        end

      cond do
        reflection? ->
          send(test_pid, {:critique_request, request})
          critique_response

        n == 1 ->
          %Response{
            text: "using a tool",
            tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "a.txt"}}],
            finish_reason: :tool_calls,
            provider: :mock,
            usage: %{input_tokens: 10, output_tokens: 1, total_tokens: 11}
          }

        true ->
          %Response{
            text: "done",
            finish_reason: :stop,
            provider: :mock,
            usage: %{input_tokens: 20, output_tokens: 2, total_tokens: 22}
          }
      end
    end
  end

  defp healthy_critique do
    %Response{
      text: "critique: on track",
      finish_reason: :stop,
      provider: :mock,
      usage: %{
        input_tokens: 7,
        output_tokens: 3,
        total_tokens: 10,
        input_cost: 0.5,
        output_cost: 0.25
      }
    }
  end

  defp run_reflexion(dir, responder, extra_opts \\ []) do
    File.write!(Path.join(dir, "a.txt"), "a")

    Loop.run(
      "go",
      Keyword.merge(
        [
          provider: :mock,
          mock: [responder: responder],
          cwd: dir,
          tools: [ExAthena.Tools.Read],
          mode: :reflexion,
          max_iterations: 5,
          memory: false
        ],
        extra_opts
      )
    )
  end

  defp attach_chat_spans(conversation_id) do
    test_pid = self()
    handler_id = "chat-spans-#{inspect(make_ref())}"

    :telemetry.attach(
      handler_id,
      [:ex_athena, :chat, :start],
      fn _name, _measurements, meta, _ ->
        if meta[:gen_ai_conversation_id] == conversation_id do
          send(test_pid, {:chat_span, meta})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # ── Reflexion critique ────────────────────────────────────────────

  describe "Reflexion critique instrumentation" do
    @describetag :tmp_dir

    test "the critique request passes through ChatParams hooks", %{tmp_dir: dir} do
      test_pid = self()

      hooks = %{
        ChatParams: [
          fn payload, _ ->
            send(test_pid, {:chat_params, payload.request})
            :ok
          end
        ]
      }

      assert {:ok, %Result{finish_reason: :stop}} =
               run_reflexion(dir, reflexion_responder(test_pid, healthy_critique()), hooks: hooks)

      assert_receive {:critique_request, _}

      # One of the ChatParams payloads must be the critique request.
      assert_receive {:chat_params, %{max_tokens: 256} = critique_req}

      assert Enum.any?(critique_req.messages, fn m ->
               is_binary(m.content) and String.contains?(m.content, @reflection_marker)
             end)
    end

    test "split input_cost/output_cost on the critique lands on Result.cost_usd", %{
      tmp_dir: dir
    } do
      assert {:ok, %Result{} = result} =
               run_reflexion(dir, reflexion_responder(self(), healthy_critique()))

      # 11 + 10 + 22 tokens across the three provider calls.
      assert result.usage.total_tokens == 43
      # Only the critique carried cost — as an input/output split.
      assert_in_delta result.cost_usd, 0.75, 0.0001
    end

    test "the critique emits a {:usage, _} loop event like every other call", %{tmp_dir: dir} do
      assert {:ok, %Result{}} =
               run_reflexion(dir, reflexion_responder(self(), healthy_critique()),
                 on_event: collector(self())
               )

      assert_receive {:event, {:usage, _}}
      assert_receive {:event, {:usage, _}}
      assert_receive {:event, {:usage, _}}
    end

    test "the critique fires an [:ex_athena, :chat] span tagged :reflection", %{tmp_dir: dir} do
      conversation_id = "refl-#{System.unique_integer([:positive])}"
      attach_chat_spans(conversation_id)

      assert {:ok, %Result{}} =
               run_reflexion(dir, reflexion_responder(self(), healthy_critique()),
                 conversation_id: conversation_id
               )

      # Three provider calls, three chat spans; one is the critique.
      assert_receive {:chat_span, meta1}
      assert_receive {:chat_span, meta2}
      assert_receive {:chat_span, meta3}
      refute_receive {:chat_span, _}, 50

      purposes = Enum.map([meta1, meta2, meta3], & &1[:purpose])
      assert Enum.count(purposes, &(&1 == :reflection)) == 1
    end

    test "a starved critique is tolerated: no escalation, budget kept, no empty message",
         %{tmp_dir: dir} do
      starved_critique = %Response{
        text: "",
        thinking: "endless critique reasoning…",
        finish_reason: :length,
        provider: :mock,
        usage: %{input_tokens: 7, output_tokens: 3, total_tokens: 10},
        starvation: %{completion_cap: 256, output_tokens: 0, reasoning_tokens: 256}
      }

      assert {:ok, %Result{} = result} =
               run_reflexion(dir, reflexion_responder(self(), starved_critique),
                 on_event: collector(self())
               )

      # The run completes normally — a starved 256-token critique must not
      # trigger the kernel's max_tokens escalation (which would 4x the main
      # turn's completion cap for the rest of the run).
      assert result.finish_reason == :stop
      refute_receive {:event, {:max_tokens_escalation, _}}

      # The starved attempt's token burn still lands on the budget.
      assert result.usage.total_tokens == 43

      # No empty assistant critique is appended to history.
      refute Enum.any?(result.messages, fn m ->
               m.role == :assistant and m.content == ""
             end)
    end

    test "a ChatParams halt on the critique skips reflection without killing the run",
         %{tmp_dir: dir} do
      hooks = %{
        ChatParams: [
          fn payload, _ ->
            reflection? =
              Enum.any?(payload.request.messages, fn m ->
                is_binary(m.content) and String.contains?(m.content, @reflection_marker)
              end)

            if reflection?, do: {:halt, :no_reflection_please}, else: :ok
          end
        ]
      }

      assert {:ok, %Result{finish_reason: :stop} = result} =
               run_reflexion(dir, reflexion_responder(self(), healthy_critique()), hooks: hooks)

      refute Enum.any?(result.messages, fn m ->
               m.role == :assistant and is_binary(m.content) and
                 String.contains?(m.content, "critique:")
             end)
    end
  end

  # ── PlanAndSolve planning turn ────────────────────────────────────

  describe "PlanAndSolve planning instrumentation" do
    defp planning_responder(test_pid) do
      counter = :counters.new(1, [:atomics])

      fn request ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            send(test_pid, {:planning_request, request})

            %Response{
              text: "plan: do the thing",
              finish_reason: :stop,
              provider: :mock,
              usage: %{
                input_tokens: 30,
                output_tokens: 5,
                total_tokens: 35,
                input_cost: 0.5,
                output_cost: 0.25
              }
            }

          _ ->
            %Response{
              text: "done",
              finish_reason: :stop,
              provider: :mock,
              usage: %{input_tokens: 40, output_tokens: 2, total_tokens: 42}
            }
        end
      end
    end

    defp run_plan_and_solve(responder, extra_opts \\ []) do
      Loop.run(
        "analyse",
        Keyword.merge(
          [
            provider: :mock,
            mock: [responder: responder],
            tools: [],
            mode: :plan_and_solve,
            max_iterations: 5,
            memory: false
          ],
          extra_opts
        )
      )
    end

    test "the planning request passes through ChatParams hooks" do
      test_pid = self()

      hooks = %{
        ChatParams: [
          fn payload, _ ->
            send(test_pid, {:chat_params_sp, payload.request.system_prompt})
            :ok
          end
        ]
      }

      assert {:ok, %Result{finish_reason: :stop}} =
               run_plan_and_solve(planning_responder(test_pid), hooks: hooks)

      assert_receive {:chat_params_sp, sp} when is_binary(sp)
      assert sp =~ "Planning phase"
    end

    test "split input_cost/output_cost on the planning turn lands on Result.cost_usd" do
      assert {:ok, %Result{} = result} = run_plan_and_solve(planning_responder(self()))

      assert result.usage.total_tokens == 77
      assert_in_delta result.cost_usd, 0.75, 0.0001
    end

    test "the planning turn emits a {:usage, _} loop event" do
      assert {:ok, %Result{}} =
               run_plan_and_solve(planning_responder(self()), on_event: collector(self()))

      assert_receive {:event, {:usage, _}}
      assert_receive {:event, {:usage, _}}
    end

    test "the planning turn fires an [:ex_athena, :chat] span" do
      conversation_id = "pas-#{System.unique_integer([:positive])}"
      attach_chat_spans(conversation_id)

      assert {:ok, %Result{}} =
               run_plan_and_solve(planning_responder(self()),
                 conversation_id: conversation_id
               )

      # Two provider calls, two chat spans.
      assert_receive {:chat_span, _}
      assert_receive {:chat_span, _}
      refute_receive {:chat_span, _}, 50
    end

    test "a ChatParams halt on the planning turn halts the run" do
      hooks = %{ChatParams: [fn _payload, _ -> {:halt, :stop_right_there} end]}

      assert {:ok, %Result{finish_reason: :error_halted, halted_reason: :stop_right_there}} =
               run_plan_and_solve(planning_responder(self()), hooks: hooks)
    end
  end

  # ── Conclusion distillation micro-call ────────────────────────────

  describe "conclusion distillation instrumentation" do
    @describetag :tmp_dir

    test "distillation usage + cost land on the run's budget", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "f.txt"), "x")
      counter = :counters.new(1, [:atomics])

      responder = fn request ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        first_content = request.messages |> List.first() |> Map.get(:content) |> to_string()

        cond do
          first_content =~ "Summarize this reasoning" ->
            %Response{
              text: "the services dir has 6 markdown files",
              finish_reason: :stop,
              provider: :mock,
              usage: %{
                input_tokens: 100,
                output_tokens: 20,
                total_tokens: 120,
                total_cost: 0.33
              }
            }

          n == 1 ->
            %Response{
              text: "",
              thinking: "long reasoning about services " <> String.duplicate("x", 300),
              tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "f.txt"}}],
              finish_reason: :tool_calls,
              provider: :mock,
              usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
            }

          true ->
            %Response{
              text: "done",
              finish_reason: :stop,
              provider: :mock,
              usage: %{input_tokens: 12, output_tokens: 4, total_tokens: 16}
            }
        end
      end

      assert {:ok, %Result{} = result} =
               Loop.run("go",
                 provider: :mock,
                 mock: [responder: responder],
                 cwd: dir,
                 tools: [ExAthena.Tools.Read],
                 conclusion_summarizer: true,
                 memory: false
               )

      # 15 (turn) + 120 (distillation) + 16 (final turn).
      assert result.usage.total_tokens == 151
      assert_in_delta result.cost_usd, 0.33, 0.0001
    end
  end
end
