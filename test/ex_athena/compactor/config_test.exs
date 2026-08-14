defmodule ExAthena.Compactor.ConfigTest do
  # Mutates the :ex_athena, :compactor application env, which every
  # compaction stage reads as its fallback — must not run concurrently
  # with other tests.
  use ExUnit.Case, async: false

  alias ExAthena.Compactor.Pipeline
  alias ExAthena.Compactors.{BudgetReduction, Summary}
  alias ExAthena.Loop.State
  alias ExAthena.Messages
  alias ExAthena.Messages.{Message, ToolResult}
  alias ExAthena.Response

  setup do
    original = Application.fetch_env(:ex_athena, :compactor)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:ex_athena, :compactor, value)
        :error -> Application.delete_env(:ex_athena, :compactor)
      end
    end)

    :ok
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

  defp tool_result_msg(id, content) do
    %Message{
      role: :tool,
      tool_results: [%ToolResult{tool_call_id: id, content: content, is_error: false}]
    }
  end

  # ── Unit: the shared resolution path ─────────────────────────────

  describe "Config.get/3" do
    alias ExAthena.Compactor.Config

    test "meta wins over app env and default" do
      Application.put_env(:ex_athena, :compactor, compact_at: 0.3)
      state = state_with([], compact_at: 0.8)
      assert Config.get(state, :compact_at, 0.6) == 0.8
    end

    test "app env (keyword and map forms) wins over the default" do
      Application.put_env(:ex_athena, :compactor, compact_at: 0.3)
      assert Config.get(state_with([], []), :compact_at, 0.6) == 0.3

      Application.put_env(:ex_athena, :compactor, %{compact_at: 0.4})
      assert Config.get(state_with([], []), :compact_at, 0.6) == 0.4
    end

    test "falls back to the default when nothing is configured" do
      Application.delete_env(:ex_athena, :compactor)
      assert Config.get(state_with([], []), :compact_at, 0.6) == 0.6
    end

    test "a malformed app env falls back to the default" do
      Application.put_env(:ex_athena, :compactor, :not_a_config)
      assert Config.get(state_with([], []), :compact_at, 0.6) == 0.6
    end
  end

  describe "Config.app_env/2" do
    alias ExAthena.Compactor.Config

    test "ignores meta entirely and reads only the app env" do
      Application.put_env(:ex_athena, :compactor, summary_system_prompt: "from env")
      assert Config.app_env(:summary_system_prompt, "default") == "from env"

      Application.delete_env(:ex_athena, :compactor)
      assert Config.app_env(:summary_system_prompt, "default") == "default"
    end
  end

  # ── Characterization: stages resolve settings meta → app env → default ──

  describe "config cascade through stage behaviour" do
    test "BudgetReduction falls back to the app env (keyword form) when meta has no override" do
      Application.put_env(:ex_athena, :compactor, per_tool_result_max_chars: 100)

      msgs = [tool_result_msg("c1", String.duplicate("X", 200))]
      state = state_with(msgs, [])

      # 200 chars > 100-char env limit → the stage applies.
      assert {:ok, _state, _est} =
               BudgetReduction.compact_stage(state, %{tokens: 100, max_tokens: 1_000})
    end

    test "BudgetReduction falls back to the app env (map form) when meta has no override" do
      Application.put_env(:ex_athena, :compactor, %{per_tool_result_max_chars: 100})

      msgs = [tool_result_msg("c1", String.duplicate("X", 200))]
      state = state_with(msgs, [])

      assert {:ok, _state, _est} =
               BudgetReduction.compact_stage(state, %{tokens: 100, max_tokens: 1_000})
    end

    test "a meta override beats the app env" do
      Application.put_env(:ex_athena, :compactor, per_tool_result_max_chars: 100)

      msgs = [tool_result_msg("c1", String.duplicate("X", 200))]
      state = state_with(msgs, per_tool_result_max_chars: 16_000)

      # meta says 16k → the 200-char result is under the limit → skip.
      assert :skip = BudgetReduction.compact_stage(state, %{tokens: 100, max_tokens: 1_000})
    end

    test "the built-in default applies when neither meta nor app env is set" do
      Application.delete_env(:ex_athena, :compactor)

      # 200 chars is far under the 16_000-char default → skip.
      msgs = [tool_result_msg("c1", String.duplicate("X", 200))]
      state = state_with(msgs, [])

      assert :skip = BudgetReduction.compact_stage(state, %{tokens: 100, max_tokens: 1_000})
    end

    test "Pipeline.should_compact?/2 reads :compact_at from the app env" do
      Application.put_env(:ex_athena, :compactor, compact_at: 0.2)

      state = state_with([], [])

      # 300/1_000 = 0.3 ≥ env threshold 0.2, but < default 0.6.
      assert Pipeline.should_compact?(state, %{tokens: 300, max_tokens: 1_000})

      Application.put_env(:ex_athena, :compactor, compact_at: 0.9)
      refute Pipeline.should_compact?(state, %{tokens: 300, max_tokens: 1_000})
    end

    test "Summary reads :summary_system_prompt from the app env" do
      marker = "CUSTOM SUMMARY PROMPT MARKER #{System.unique_integer([:positive])}"
      Application.put_env(:ex_athena, :compactor, summary_system_prompt: marker)

      parent = self()

      responder = fn req ->
        send(parent, {:summary_request, req})

        %Response{
          text: "[compacted]",
          finish_reason: :stop,
          provider: :mock,
          usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
        }
      end

      messages =
        [Messages.system("sys")] ++
          for i <- 1..6 do
            if rem(i, 2) == 1, do: Messages.user("Q#{i}"), else: Messages.assistant("A#{i}")
          end

      state = %{
        state_with(messages, pinned_prefix_count: 1, live_suffix_count: 2)
        | provider_opts: [mock: [responder: responder]]
      }

      assert {:compact, _msgs, _meta} = Summary.compact(state, %{tokens: 800, max_tokens: 1_000})

      assert_receive {:summary_request, req}
      assert [%Message{content: content}] = req.messages
      assert content =~ marker
    end
  end
end
