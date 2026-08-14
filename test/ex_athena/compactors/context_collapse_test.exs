defmodule ExAthena.Compactors.ContextCollapseTest do
  use ExUnit.Case, async: true

  alias ExAthena.Compactors.ContextCollapse
  alias ExAthena.Loop.State
  alias ExAthena.Messages.{Message, ToolCall, ToolResult}

  defp state_with(messages, opts) do
    %State{
      messages: messages,
      provider_mod: ExAthena.Providers.Mock,
      provider_opts: [],
      request_template: %ExAthena.Request{messages: messages},
      meta: Enum.into(opts, %{})
    }
  end

  test "name/0 reports :context_collapse" do
    assert ContextCollapse.name() == :context_collapse
  end

  test "skips when no patterns match" do
    msgs = [
      %Message{role: :user, content: "hi"},
      %Message{role: :assistant, content: "ok"}
    ]

    state = state_with(msgs, [])
    assert :skip = ContextCollapse.compact_stage(state, %{tokens: 100, max_tokens: 1_000})
  end

  test "marks repeated identical assistant tool-calls" do
    call = %ToolCall{id: "c1", name: "glob", arguments: %{"pattern" => "**/*.ex"}}

    msgs = [
      %Message{role: :assistant, tool_calls: [call]},
      %Message{role: :tool, tool_results: [%ToolResult{tool_call_id: "c1", content: "x"}]},
      %Message{role: :assistant, tool_calls: [%{call | id: "c2"}]},
      %Message{role: :tool, tool_results: [%ToolResult{tool_call_id: "c2", content: "y"}]}
    ]

    state = state_with(msgs, [])

    # ContextCollapse should detect the duplicate call signature and mark
    # the second call with `(repeat)`.
    assert {:ok, new_state, _est} =
             ContextCollapse.compact_stage(state, %{tokens: 100, max_tokens: 1_000})

    assert new_state.meta[:compact_view]
  end

  test "recomputed estimate includes the system-prompt cost (issue #148)" do
    sys = String.duplicate("S", 4_000)
    call = %ToolCall{id: "c1", name: "glob", arguments: %{"pattern" => "**/*.ex"}}

    msgs = [
      %Message{role: :assistant, tool_calls: [call]},
      %Message{role: :tool, tool_results: [%ToolResult{tool_call_id: "c1", content: "x"}]},
      %Message{role: :assistant, tool_calls: [%{call | id: "c2"}]},
      %Message{role: :tool, tool_results: [%ToolResult{tool_call_id: "c2", content: "y"}]}
    ]

    state = %{
      state_with(msgs, [])
      | request_template: %ExAthena.Request{messages: msgs, system_prompt: sys}
    }

    assert {:ok, new_state, est} =
             ContextCollapse.compact_stage(state, %{tokens: 100, max_tokens: 1_000})

    view = new_state.meta[:compact_view]
    assert est.tokens == ExAthena.Compactor.estimate_tokens(view, sys)
  end

  test "does not rewrite a pinned repeated assistant tool-call (ADR-0027)" do
    call = %ToolCall{id: "c1", name: "glob", arguments: %{"pattern" => "**/*.ex"}}

    msgs = [
      %Message{role: :assistant, tool_calls: [call]},
      %Message{role: :tool, tool_results: [%ToolResult{tool_call_id: "c1", content: "x"}]},
      %Message{role: :assistant, pin: true, tool_calls: [%{call | id: "c2"}]},
      %Message{role: :tool, tool_results: [%ToolResult{tool_call_id: "c2", content: "y"}]},
      %Message{role: :assistant, tool_calls: [%{call | id: "c3"}]},
      %Message{role: :tool, tool_results: [%ToolResult{tool_call_id: "c3", content: "z"}]}
    ]

    state = state_with(msgs, [])

    assert {:ok, new_state, _est} =
             ContextCollapse.compact_stage(state, %{tokens: 100, max_tokens: 1_000})

    # The stage writes its collapsed output into meta[:compact_view].
    # The pinned assistant keeps its content verbatim; the non-pinned
    # repeat is still detected and marked.
    view = new_state.meta[:compact_view]
    pinned_after = Enum.at(view, 2)
    non_pinned_after = Enum.at(view, 4)

    refute (pinned_after.content || "") =~ "(repeat)"
    assert (non_pinned_after.content || "") =~ "(repeat)"
  end
end
