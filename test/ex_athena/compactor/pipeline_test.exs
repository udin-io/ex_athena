defmodule ExAthena.Compactor.PipelineTest do
  use ExUnit.Case, async: true

  alias ExAthena.Compactor.Pipeline
  alias ExAthena.Loop.State
  alias ExAthena.Messages
  alias ExAthena.Messages.{Message, ToolResult}

  # A trivial test stage that drops the second message of the conversation
  # and shaves 100 tokens off the estimate. Used to assert the pipeline
  # actually walks its stage list and aggregates results.
  defmodule TestStage do
    @behaviour ExAthena.Compactor.Stage

    @impl true
    def name, do: :test_stage

    @impl true
    def compact_stage(%State{messages: [first | rest]} = state, estimate) do
      case rest do
        [_ | tail] ->
          new_messages = [first | tail]
          {:ok, %{state | messages: new_messages}, %{estimate | tokens: estimate.tokens - 100}}

        _ ->
          :skip
      end
    end
  end

  defmodule SkipStage do
    @behaviour ExAthena.Compactor.Stage

    @impl true
    def name, do: :skip_stage

    @impl true
    def compact_stage(_state, _estimate), do: :skip
  end

  defmodule FailStage do
    @behaviour ExAthena.Compactor.Stage

    @impl true
    def name, do: :fail_stage

    @impl true
    def compact_stage(_state, _estimate), do: {:error, :boom}
  end

  defp state_with(messages, opts) do
    %State{
      messages: messages,
      provider_mod: ExAthena.Providers.Mock,
      provider_opts: [],
      request_template: %ExAthena.Request{messages: messages},
      meta: Enum.into(opts, %{})
    }
  end

  test "should_compact?/2 honours the threshold" do
    state = state_with([], compact_at: 0.6)
    refute Pipeline.should_compact?(state, %{tokens: 100, max_tokens: 1_000})
    assert Pipeline.should_compact?(state, %{tokens: 700, max_tokens: 1_000})
  end

  test "should_compact?/2 returns true unconditionally when force: true" do
    state = state_with([], compact_at: 0.99)
    assert Pipeline.should_compact?(state, %{tokens: 1, max_tokens: 1_000, force: true})
  end

  test "compact/2 walks the stage list and reports per-stage application" do
    messages = [
      Messages.system("sp"),
      Messages.user("Q1"),
      Messages.user("Q2"),
      Messages.user("Q3")
    ]

    state =
      state_with(messages,
        compaction_pipeline: [TestStage, SkipStage],
        compact_at: 0.5
      )

    assert {:compact, new_messages, metadata} =
             Pipeline.compact(state, %{tokens: 800, max_tokens: 1_000})

    # TestStage dropped one message, SkipStage was a no-op.
    assert length(new_messages) == length(messages) - 1
    assert metadata.stages_applied == [:test_stage]
    assert metadata.before == 800
    assert metadata.after == 700
    assert metadata.reason == :token_budget
  end

  test "compact/2 returns :skip when every stage skips" do
    messages = [Messages.user("hi")]

    state =
      state_with(messages,
        compaction_pipeline: [SkipStage],
        compact_at: 0.5
      )

    assert :skip = Pipeline.compact(state, %{tokens: 800, max_tokens: 1_000})
  end

  test "compact/2 stops + surfaces an error when a stage fails" do
    messages = [
      Messages.system("sp"),
      Messages.user("Q1"),
      Messages.user("Q2"),
      Messages.user("Q3")
    ]

    state =
      state_with(messages,
        compaction_pipeline: [TestStage, FailStage],
        compact_at: 0.5
      )

    assert {:error, {:fail_stage, :boom}} =
             Pipeline.compact(state, %{tokens: 800, max_tokens: 1_000})
  end

  test "run/3 with force: true runs every stage even when under the threshold" do
    messages = [
      Messages.system("sp"),
      Messages.user("Q1"),
      Messages.user("Q2")
    ]

    state =
      state_with(messages,
        compaction_pipeline: [TestStage],
        compact_at: 0.99
      )

    estimate = %{tokens: 100, max_tokens: 1_000}

    # Without force, we'd skip (under threshold).
    assert :skip = Pipeline.run(state, estimate, force: false)

    # With force, the stage runs.
    assert {:compact, _msgs, metadata} = Pipeline.run(state, estimate, force: true)
    assert metadata.reason == :reactive_recovery
    assert :test_stage in metadata.stages_applied
  end

  test "tool-result archive entries from BudgetReduction land in state.meta after pipeline runs" do
    big = String.duplicate("Z", 25_000)

    messages = [
      Messages.user("hi"),
      %Message{
        role: :tool,
        tool_results: [%ToolResult{tool_call_id: "c1", content: big, is_error: false}]
      }
    ]

    state =
      state_with(messages,
        compaction_pipeline: [ExAthena.Compactors.BudgetReduction],
        per_tool_result_max_chars: 16_000,
        compact_at: 0.1
      )

    assert {:compact, new_messages, metadata} =
             Pipeline.compact(state, %{tokens: 7_000, max_tokens: 10_000})

    [_user, %Message{tool_results: [tr]}] = new_messages
    assert tr.content =~ "[truncated"
    assert metadata.stages_applied == [:budget_reduction]
  end
end
