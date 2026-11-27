defmodule ExAthena.Loop.InferenceInstrumentationTest do
  @moduledoc """
  Issue #136 — every mode-internal inference (conclusion distillation,
  compaction summary) must
  go through the same instrumented path as ReAct's main turn: ChatParams
  hooks, the `[:ex_athena, :chat]` telemetry span, full cost extraction
  (including input_cost/output_cost splits), budget folding, and `{:usage}`
  events.

  Starvation policy: internal micro-calls (distillation, summary)
  must NOT surface `:error_thinking_starved` — the kernel's escalation
  4x-es the run's request-template `max_tokens` and re-runs the whole
  iteration, a disproportionate response to a fixed 256-token utility call.
  A starved micro-call is simply a failed micro-call with a graceful
  fallback.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Messages.ToolCall

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
