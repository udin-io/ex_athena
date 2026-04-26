defmodule ExAthena.Compactors.SummaryTest do
  use ExUnit.Case, async: true

  alias ExAthena.Compactors.Summary
  alias ExAthena.Loop.State
  alias ExAthena.Messages
  alias ExAthena.Response

  defp mock_state(messages, responder) do
    %State{
      messages: messages,
      provider_mod: ExAthena.Providers.Mock,
      provider_opts: [mock: [responder: responder]],
      request_template: %ExAthena.Request{messages: messages},
      budget: nil,
      meta: %{pinned_prefix_count: 1, live_suffix_count: 2, compact_at: 0.5}
    }
  end

  test "should_compact?/2 returns false below the threshold" do
    state = mock_state([], fn _ -> nil end)
    refute Summary.should_compact?(state, %{tokens: 100, max_tokens: 1_000})
  end

  test "should_compact?/2 returns true at or above the threshold" do
    state = mock_state([], fn _ -> nil end)
    assert Summary.should_compact?(state, %{tokens: 600, max_tokens: 1_000})
  end

  test "compact/2 replaces the middle with a summary, preserves prefix + suffix" do
    # pinned_prefix_count: 1, live_suffix_count: 2 (see mock_state).
    # Messages: [system] + [4 middle messages] + [last 2 live]
    # 4 middle are eligible for compaction.
    messages = [
      Messages.system("You are a helpful agent."),
      Messages.user("Q1"),
      Messages.assistant("A1"),
      Messages.user("Q2"),
      Messages.assistant("A2"),
      Messages.user("Q3"),
      Messages.assistant("A3 – recent")
    ]

    responder = fn _req ->
      %Response{
        text: "[compacted]: 3 Q&A turns summarised.",
        finish_reason: :stop,
        provider: :mock,
        usage: %{input_tokens: 50, output_tokens: 10, total_tokens: 60}
      }
    end

    state = mock_state(messages, responder)

    assert {:compact, new_messages, metadata} =
             Summary.compact(state, %{tokens: 800, max_tokens: 1_000})

    # Prefix (pinned) survives.
    assert hd(new_messages).role == :system

    # Last 2 live messages preserved at tail.
    assert Enum.at(new_messages, -1).content == "A3 – recent"
    assert Enum.at(new_messages, -2).content == "Q3"

    # One summary message replaces the middle.
    summary = Enum.at(new_messages, 1)
    assert summary.role == :assistant
    assert summary.name == "compactor_summary"
    assert summary.content =~ "compacted"

    assert metadata.before == 800
    assert metadata.dropped_count == 4
    assert metadata.reason == :token_budget
    assert is_integer(metadata.after) and metadata.after < 800
  end

  test "compact/2 skips when middle is too short to bother" do
    messages = [
      Messages.system("sys"),
      Messages.user("Q1"),
      Messages.assistant("A1")
    ]

    state = mock_state(messages, fn _ -> nil end)
    assert :skip = Summary.compact(state, %{tokens: 800, max_tokens: 1_000})
  end

  test "compact/2 surfaces provider errors as {:error, _}" do
    messages =
      [Messages.system("sys")] ++
        for i <- 1..6, do: Messages.user("turn #{i}")

    responder = fn _req -> %Response{text: "", finish_reason: :stop, provider: :mock} end

    state = mock_state(messages, responder)

    # Empty text → :empty_summary error.
    assert {:error, {:summary_failed, :empty_summary}} =
             Summary.compact(state, %{tokens: 800, max_tokens: 1_000})
  end

  test "compact/2 pins memory + skill messages even when middle is large" do
    # Memory user-context messages and pre-loaded skill system messages
    # live at the very front of the conversation. Compaction must
    # preserve them on top of the configured pinned_prefix_count.
    memory_msg = %ExAthena.Messages.Message{role: :user, content: "remember", name: "memory"}

    skill_msg = %ExAthena.Messages.Message{
      role: :system,
      content: "deploy steps",
      name: "skill:deploy"
    }

    messages =
      [memory_msg, skill_msg, Messages.system("sys-prompt")] ++
        [
          Messages.user("Q1"),
          Messages.assistant("A1"),
          Messages.user("Q2"),
          Messages.assistant("A2"),
          Messages.user("Q3"),
          Messages.assistant("A3")
        ]

    responder = fn _req ->
      %Response{
        text: "[compacted summary]",
        finish_reason: :stop,
        provider: :mock,
        usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
      }
    end

    state =
      %ExAthena.Loop.State{
        messages: messages,
        provider_mod: ExAthena.Providers.Mock,
        provider_opts: [mock: [responder: responder]],
        request_template: %ExAthena.Request{messages: messages},
        budget: nil,
        meta: %{
          pinned_prefix_count: 1,
          live_suffix_count: 2,
          compact_at: 0.5,
          memory_count: 1,
          preloaded_skill_count: 1
        }
      }

    assert {:compact, new_messages, _metadata} =
             Summary.compact(state, %{tokens: 800, max_tokens: 1_000})

    # The memory message AND the skill activation AND the original
    # pinned system prompt all survive untouched at the front.
    assert Enum.at(new_messages, 0) == memory_msg
    assert Enum.at(new_messages, 1) == skill_msg
    assert Enum.at(new_messages, 2).role == :system
    # Live suffix at the tail.
    assert Enum.at(new_messages, -1).content == "A3"
  end
end
