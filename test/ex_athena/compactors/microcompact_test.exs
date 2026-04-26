defmodule ExAthena.Compactors.MicrocompactTest do
  use ExUnit.Case, async: true

  alias ExAthena.Compactors.Microcompact
  alias ExAthena.Loop.State
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

  defp tool_msg(id, content),
    do: %Message{
      role: :tool,
      tool_results: [%ToolResult{tool_call_id: id, content: content, is_error: false}]
    }

  test "name/0 reports :microcompact" do
    assert Microcompact.name() == :microcompact
  end

  test "skips when there is no run of 3+ adjacent tool messages" do
    messages = [
      tool_msg("c1", "a"),
      %Message{role: :assistant, content: "thoughts"},
      tool_msg("c2", "b")
    ]

    state = state_with(messages, microcompact_run_threshold: 3, pinned_prefix_count: 0)
    assert :skip = Microcompact.compact_stage(state, %{tokens: 10, max_tokens: 1_000})
  end

  test "collapses a run of 3+ adjacent tool messages into a single summary" do
    messages =
      [
        %Message{role: :user, content: "go"},
        tool_msg("c1", "alpha-result"),
        tool_msg("c2", "beta-result"),
        tool_msg("c3", "gamma-result"),
        tool_msg("c4", "delta-result"),
        %Message{role: :assistant, content: "ok"},
        # Live suffix — stays untouched.
        %Message{role: :user, content: "more"},
        %Message{role: :assistant, content: "yep"}
      ]

    state =
      state_with(messages,
        microcompact_run_threshold: 3,
        microcompact_excerpt_chars: 20,
        pinned_prefix_count: 1
      )

    assert {:ok, new_state, new_estimate} =
             Microcompact.compact_stage(state, %{tokens: 1_000, max_tokens: 10_000})

    # The 3-message run inside the work window (live-suffix takes the 4th)
    # collapses into a single summary message.
    summary = Enum.find(new_state.messages, &match?(%Message{name: "microcompact"}, &1))
    assert summary
    assert summary.content =~ "[microcompact: 3 tool results elided]"
    assert summary.content =~ "alpha-result"
    assert summary.content =~ "gamma-result"

    # Token budget went down.
    assert new_estimate.tokens < 1_000
  end
end
