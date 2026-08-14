defmodule ExAthena.Compactors.BudgetReductionTest do
  use ExUnit.Case, async: true

  alias ExAthena.Compactors.BudgetReduction
  alias ExAthena.Loop.State
  alias ExAthena.Messages
  alias ExAthena.Messages.{Message, ToolResult}

  defp state_with(messages, opts) do
    %State{
      messages: messages,
      provider_mod: ExAthena.Providers.Mock,
      provider_opts: [],
      request_template: %ExAthena.Request{messages: messages},
      meta: Enum.into(opts, %{})
    }
  end

  defp tool_result_msg(id, content) do
    %Message{
      role: :tool,
      tool_results: [%ToolResult{tool_call_id: id, content: content, is_error: false}]
    }
  end

  test "name/0 reports :budget_reduction" do
    assert BudgetReduction.name() == :budget_reduction
  end

  test "skips when no tool result exceeds the limit" do
    msgs = [tool_result_msg("c1", "small")]
    state = state_with(msgs, per_tool_result_max_chars: 1_000)
    assert :skip = BudgetReduction.compact_stage(state, %{tokens: 100, max_tokens: 1_000})
  end

  test "replaces oversized tool-result content with a reference pointer" do
    big = String.duplicate("X", 20_000)
    msgs = [Messages.user("hi"), tool_result_msg("c1", big)]
    state = state_with(msgs, per_tool_result_max_chars: 16_000)

    assert {:ok, new_state, new_estimate} =
             BudgetReduction.compact_stage(state, %{tokens: 5_000, max_tokens: 100_000})

    [_user, %Message{tool_results: [tr]}] = new_state.messages
    assert tr.content =~ "[old output cleared to save context (20000 chars, ref="
    assert new_estimate.tokens < 5_000

    # Archive holds the original payload, keyed by the generated ref.
    archive = new_state.meta[:tool_result_archive]
    assert is_map(archive)
    assert map_size(archive) == 1
    [{_ref, entry}] = Enum.to_list(archive)
    assert entry.tool_call_id == "c1"
    assert entry.content == big
  end

  test "leaves under-the-limit results untouched in a mixed message list" do
    big = String.duplicate("Y", 20_000)
    small = "fine"

    msgs = [
      tool_result_msg("c1", small),
      tool_result_msg("c2", big),
      Messages.assistant("done"),
      tool_result_msg("c3", small)
    ]

    state = state_with(msgs, per_tool_result_max_chars: 16_000)

    assert {:ok, new_state, _est} =
             BudgetReduction.compact_stage(state, %{tokens: 5_000, max_tokens: 100_000})

    [first, second, _assistant, fourth] = new_state.messages
    assert hd(first.tool_results).content == small
    assert hd(second.tool_results).content =~ "[old output cleared"
    assert hd(fourth.tool_results).content == small
  end

  test "recomputed estimate includes the system-prompt cost (issue #148)" do
    sys = String.duplicate("S", 4_000)
    big = String.duplicate("X", 20_000)
    msgs = [Messages.user("hi"), tool_result_msg("c1", big)]

    state = %{
      state_with(msgs, per_tool_result_max_chars: 16_000)
      | request_template: %ExAthena.Request{messages: msgs, system_prompt: sys}
    }

    initial = ExAthena.Compactor.estimate_tokens(msgs, sys)

    assert {:ok, new_state, est} =
             BudgetReduction.compact_stage(state, %{tokens: initial, max_tokens: 100_000})

    assert est.tokens == ExAthena.Compactor.estimate_tokens(new_state.messages, sys)
    assert est.tokens < initial
  end

  test "leaves a pinned oversized tool result untouched (ADR-0027)" do
    big = String.duplicate("P", 20_000)
    msgs = [Messages.user("hi"), %{tool_result_msg("pin1", big) | pin: true}]
    state = state_with(msgs, per_tool_result_max_chars: 16_000)

    # The pinned message is the only oversized candidate, so the stage
    # must decline entirely — pinned artifacts (plan text, PR URLs) are
    # compaction-immune.
    assert :skip = BudgetReduction.compact_stage(state, %{tokens: 5_000, max_tokens: 100_000})
  end

  test "replaces non-pinned oversized results while preserving pinned ones" do
    big = String.duplicate("Q", 20_000)

    msgs = [
      %{tool_result_msg("pin1", big) | pin: true},
      tool_result_msg("c1", big)
    ]

    state = state_with(msgs, per_tool_result_max_chars: 16_000)

    assert {:ok, new_state, _est} =
             BudgetReduction.compact_stage(state, %{tokens: 5_000, max_tokens: 100_000})

    [pinned, normal] = new_state.messages
    assert hd(pinned.tool_results).content == big
    assert hd(normal.tool_results).content =~ "[old output cleared"

    # Only the non-pinned payload is archived.
    archive = new_state.meta[:tool_result_archive]
    assert map_size(archive) == 1
    [{_ref, entry}] = Enum.to_list(archive)
    assert entry.tool_call_id == "c1"
  end
end
