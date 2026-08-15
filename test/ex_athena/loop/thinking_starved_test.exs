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
    assert message =~ "completion_cap=8192"

    assert %{completion_cap: 8_192, output_tokens: 8_192, reasoning_tokens: 8_192} =
             result.error_diagnostic
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
  end
end
