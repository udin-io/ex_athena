defmodule ExAthena.Loop.ThinkingStarvedTest do
  @moduledoc """
  Issue #194 — output-starved turns (a hybrid thinking model burns the whole
  completion budget on reasoning and emits no text) must not terminate as
  `:stop` success. The kernel retries the iteration once with an escalated
  `max_tokens` (mirroring the `:error_prompt_too_long` → force-compact →
  retry template); a second starved attempt terminates with the typed
  `:error_thinking_starved` capacity failure naming the token counts.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}

  # Provider whose every turn is starved: blank text, finish_reason :length,
  # the whole completion budget burned in the reasoning channel. Mirrors what
  # the ReqLLM adapter produces for a starved turn (starvation signal set).
  defmodule AlwaysStarvedProvider do
    @behaviour ExAthena.Provider

    @impl true
    def capabilities, do: %{native_tool_calls: true, streaming: false, max_tokens: 128_000}

    @impl true
    def query(request, opts) do
      if pid = Keyword.get(opts, :notify), do: send(pid, {:request, request})
      if counter = Keyword.get(opts, :counter), do: :counters.add(counter, 1, 1)
      cap = request.max_tokens || 8_192

      {:ok,
       %Response{
         text: "",
         thinking: "endless reasoning…",
         tool_calls: [],
         finish_reason: :length,
         provider: :test,
         usage: %{input_tokens: 40, output_tokens: cap, reasoning_tokens: cap},
         starvation: %{completion_cap: cap, output_tokens: cap, reasoning_tokens: cap}
       }}
    end
  end

  # First call starved at the default cap; any later call (escalated budget)
  # completes normally — a model that CAN finish stops when done.
  defmodule StarvedThenRecoverProvider do
    @behaviour ExAthena.Provider

    @impl true
    def capabilities, do: %{native_tool_calls: true, streaming: false, max_tokens: 128_000}

    @impl true
    def query(request, opts) do
      counter = Keyword.fetch!(opts, :counter)
      if pid = Keyword.get(opts, :notify), do: send(pid, {:request, request})
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          cap = request.max_tokens || 8_192

          {:ok,
           %Response{
             text: "",
             thinking: "…",
             tool_calls: [],
             finish_reason: :length,
             provider: :test,
             usage: %{input_tokens: 40, output_tokens: cap, reasoning_tokens: cap},
             starvation: %{completion_cap: cap, output_tokens: cap, reasoning_tokens: cap}
           }}

        _ ->
          {:ok,
           %Response{
             text: "finished with room to think",
             tool_calls: [],
             finish_reason: :stop,
             provider: :test,
             usage: %{input_tokens: 40, output_tokens: 900, reasoning_tokens: 700}
           }}
      end
    end
  end

  test "a starved turn never terminates as :stop success" do
    {:ok, %Result{} = result} =
      Loop.run("hi",
        provider: AlwaysStarvedProvider,
        tools: [],
        memory: false,
        skills: %{}
      )

    assert result.finish_reason == :error_thinking_starved
    assert Result.category(result) == :capacity
    refute Result.success?(result)
    # The starved run produced no visible output — no stale/blank text may
    # be reported as the answer.
    assert result.text == nil
  end

  test "the terminal error names the token counts (output vs reasoning vs cap)" do
    {:ok, %Result{} = result} =
      Loop.run("hi",
        provider: AlwaysStarvedProvider,
        tools: [],
        memory: false,
        skills: %{}
      )

    assert {:thinking_starved, message} = result.halted_reason
    assert message =~ "output_tokens="
    assert message =~ "reasoning_tokens="
    assert message =~ "completion_cap="

    assert %{completion_cap: cap, output_tokens: out, reasoning_tokens: reasoning} =
             result.error_diagnostic

    assert is_integer(cap) and cap >= 8_192
    assert is_integer(out) and out >= 8_192
    assert is_integer(reasoning) and reasoning >= 8_192
  end

  test "the starved attempt's token burn still lands on the run's budget" do
    {:ok, %Result{} = result} =
      Loop.run("hi",
        provider: AlwaysStarvedProvider,
        tools: [],
        memory: false,
        skills: %{}
      )

    assert result.usage.output_tokens >= 8_192
    # reasoning_tokens survive Budget.merge_usage so callers can see WHERE
    # the budget went (the starvation diagnostic) from Result.usage alone.
    assert result.usage.reasoning_tokens >= 8_192
  end

  describe "escalating retry (mirrors the prompt-too-long force-compact template)" do
    test "retries the same iteration once with an escalated max_tokens and succeeds" do
      counter = :counters.new(1, [:atomics])
      parent = self()

      {:ok, %Result{} = result} =
        Loop.run("hi",
          provider: StarvedThenRecoverProvider,
          counter: counter,
          notify: parent,
          tools: [],
          memory: false,
          skills: %{},
          on_event: fn event -> send(parent, {:event, event}) end
        )

      assert result.finish_reason == :stop
      assert result.text == "finished with room to think"

      assert :counters.get(counter, 1) == 2,
             "expected exactly one escalated retry of the starved iteration"

      # First attempt ran with the run's own (unset) cap; the retry ran with
      # 4x the adapter default (8_192 -> 32_768), bounded by context headroom.
      assert_received {:request, %ExAthena.Request{max_tokens: nil}}
      assert_received {:request, %ExAthena.Request{max_tokens: 32_768}}
    end

    test "the escalation emits a host-visible event with the caps and token counts" do
      counter = :counters.new(1, [:atomics])
      parent = self()

      {:ok, %Result{}} =
        Loop.run("hi",
          provider: StarvedThenRecoverProvider,
          counter: counter,
          tools: [],
          memory: false,
          skills: %{},
          on_event: fn event -> send(parent, {:event, event}) end
        )

      assert_received {:event,
                       {:max_tokens_escalation,
                        %{
                          from: 8_192,
                          to: 32_768,
                          output_tokens: 8_192,
                          reasoning_tokens: 8_192
                        }}}
    end

    test "a still-starved escalated attempt terminates typed, naming the escalated cap" do
      counter = :counters.new(1, [:atomics])

      {:ok, %Result{} = result} =
        Loop.run("hi",
          provider: AlwaysStarvedProvider,
          counter: counter,
          tools: [],
          memory: false,
          skills: %{}
        )

      assert result.finish_reason == :error_thinking_starved

      assert :counters.get(counter, 1) == 2,
             "expected exactly one escalated retry before terminating"

      assert {:thinking_starved, message} = result.halted_reason
      assert message =~ "completion_cap=32768"
      assert message =~ "escalated_cap=32768"

      # Both attempts' burn lands on the budget: 8_192 + 32_768.
      assert result.usage.output_tokens == 8_192 + 32_768
    end

    # Provider whose CONTEXT WINDOW equals the completion cap — escalating
    # the completion budget would leave no room for the prompt, so the
    # kernel must terminate typed without a doomed retry.
    defmodule TinyContextStarvedProvider do
      @behaviour ExAthena.Provider

      @impl true
      def capabilities, do: %{native_tool_calls: true, streaming: false, max_tokens: 8_192}

      @impl true
      def query(request, opts) do
        if counter = Keyword.get(opts, :counter), do: :counters.add(counter, 1, 1)
        cap = request.max_tokens || 8_192

        {:ok,
         %ExAthena.Response{
           text: "",
           tool_calls: [],
           finish_reason: :length,
           provider: :test,
           usage: %{input_tokens: 40, output_tokens: cap, reasoning_tokens: cap},
           starvation: %{completion_cap: cap, output_tokens: cap, reasoning_tokens: cap}
         }}
      end
    end

    test "terminates without retry when the context window leaves no escalation headroom" do
      counter = :counters.new(1, [:atomics])

      {:ok, %Result{} = result} =
        Loop.run("hi",
          provider: TinyContextStarvedProvider,
          counter: counter,
          tools: [],
          memory: false,
          skills: %{}
        )

      assert result.finish_reason == :error_thinking_starved
      assert :counters.get(counter, 1) == 1, "no headroom means no escalated retry"
    end
  end
end
