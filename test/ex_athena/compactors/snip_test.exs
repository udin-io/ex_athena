defmodule ExAthena.Compactors.SnipTest do
  use ExUnit.Case, async: true

  alias ExAthena.Compactors.Snip
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

  defp tool_msg(id, content),
    do: %Message{
      role: :tool,
      tool_results: [%ToolResult{tool_call_id: id, content: content, is_error: false}]
    }

  test "name/0 reports :snip" do
    assert Snip.name() == :snip
  end

  test "skips when no tool result is old enough" do
    # Recent tool messages — the live suffix carve-out keeps them.
    messages = [
      Messages.system("sp"),
      tool_msg("c1", "result"),
      Messages.assistant("ok")
    ]

    state = state_with(messages, snip_age_iterations: 4, pinned_prefix_count: 1)
    assert :skip = Snip.compact_stage(state, %{tokens: 10, max_tokens: 1_000})
  end

  test "replaces stale tool-result bodies with a marker" do
    # Layout: pinned (1) + 8 turns including tool messages + 1 final assistant.
    # The early tool messages should be 4+ turns from the last assistant.
    # Assistant + tool turn (these are old relative to last_assistant)
    messages =
      [Messages.system("sp")] ++
        for i <- 1..8 do
          if rem(i, 2) == 1 do
            Messages.assistant("turn #{i}")
          else
            tool_msg("c#{i}", "stale tool body #{i}")
          end
        end ++
        [Messages.assistant("final")]

    # Bypass the live-suffix protection by using a long enough conversation.
    state =
      state_with(messages,
        snip_age_iterations: 2,
        pinned_prefix_count: 1
      )

    assert {:ok, new_state, _estimate} =
             Snip.compact_stage(state, %{tokens: 1_000, max_tokens: 10_000})

    # At least one tool-result was replaced with a snip marker.
    snipped =
      Enum.count(new_state.messages, fn
        %Message{role: :tool, tool_results: [%ToolResult{content: c} | _]} ->
          String.contains?(to_string(c), "snipped: stale")

        _ ->
          false
      end)

    assert snipped >= 1
  end
end
