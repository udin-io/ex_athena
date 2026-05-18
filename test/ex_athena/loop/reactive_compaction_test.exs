defmodule ExAthena.Loop.ReactiveCompactionTest do
  @moduledoc """
  PR2 — verifies the kernel's reactive recovery path: a mode that returns
  `{:error, :error_prompt_too_long}` triggers a forced pipeline pass and
  retries the same iteration once.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Loop.State
  alias ExAthena.Messages.{Message, ToolCall, ToolResult}

  # Stub mode whose first call returns `{:error, :error_prompt_too_long}`
  # and whose second call (after recovery) halts cleanly.
  defmodule FlakyMode do
    @behaviour ExAthena.Loop.Mode

    @impl true
    def init(state) do
      counter = :counters.new(1, [:atomics])
      {:ok, %{state | mode_state: %{counter: counter}}}
    end

    @impl true
    def iterate(%State{mode_state: %{counter: counter}} = state) do
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 -> {:error, :error_prompt_too_long}
        _ -> {:halt, set_finish(state, :stop)}
      end
    end

    defp set_finish(state, reason), do: put_in(state.meta[:finish_reason], reason)
  end

  # Recovery-disabled stub mode — same as FlakyMode but the kernel
  # should immediately classify as `:error_prompt_too_long` since
  # `:reactive_compact` is set to false.
  defmodule AlwaysOverflowMode do
    @behaviour ExAthena.Loop.Mode
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def iterate(_state), do: {:error, :error_prompt_too_long}
  end

  test "reactive recovery retries the iteration once after forcing the pipeline" do
    responder = fn _req ->
      %Response{text: "ok", finish_reason: :stop, provider: :mock}
    end

    {:ok, %Result{} = result} =
      Loop.run("hi",
        provider: :mock,
        mock: [responder: responder],
        tools: [],
        mode: FlakyMode,
        memory: false,
        skills: %{}
      )

    assert result.finish_reason == :stop
  end

  # A compactor spy that captures the messages it receives during
  # force_compact and stores them in a process dictionary so the test
  # can inspect them after the loop finishes.
  defmodule SpyCompactor do
    @behaviour ExAthena.Compactor

    @impl true
    def should_compact?(_state, _estimate), do: false

    @impl true
    def compact(%State{messages: messages}, _estimate) do
      Process.put(:spy_messages, messages)
      # Return the messages with a modest token reduction so the loop accepts it.
      {:compact, messages, %{before: 1000, after: 500, dropped_count: 0, reason: :token_budget}}
    end
  end

  defmodule FlakyModeWithSpy do
    @behaviour ExAthena.Loop.Mode

    @impl true
    def init(state) do
      counter = :counters.new(1, [:atomics])
      {:ok, %{state | mode_state: %{counter: counter}}}
    end

    @impl true
    def iterate(%State{mode_state: %{counter: counter}} = state) do
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 -> {:error, :error_prompt_too_long}
        _ -> {:halt, put_in(state.meta[:finish_reason], :stop)}
      end
    end
  end

  test "auto_pin stamps pin: true on matching tool-result messages before force_compact" do
    tc = %ToolCall{id: "tc_exit", name: "ExitPlanMode", arguments: %{}}

    exit_plan_tool_result = %Message{
      role: :tool,
      pin: false,
      tool_results: [
        %ToolResult{tool_call_id: "tc_exit", content: "the plan text", is_error: false}
      ]
    }

    initial_messages = [
      %Message{role: :assistant, content: nil, tool_calls: [tc]},
      exit_plan_tool_result
    ]

    {:ok, %Result{}} =
      Loop.run("hi",
        provider: :mock,
        mock: [
          responder: fn _req ->
            %Response{text: "ok", finish_reason: :stop, provider: :mock}
          end
        ],
        tools: [],
        mode: FlakyModeWithSpy,
        memory: false,
        skills: %{},
        messages: initial_messages,
        compactor: SpyCompactor,
        auto_pin: %{tool_names: ["ExitPlanMode"]}
      )

    spy_msgs = Process.get(:spy_messages)
    assert spy_msgs != nil, "SpyCompactor was never called"

    pinned_ids =
      spy_msgs
      |> Enum.flat_map(fn
        %Message{role: :tool, pin: true, tool_results: trs} -> Enum.map(trs, & &1.tool_call_id)
        _ -> []
      end)

    assert "tc_exit" in pinned_ids,
           "Expected ExitPlanMode tool-result to be pinned before compaction"
  end

  test "with reactive compaction disabled, prompt-too-long terminates immediately" do
    responder = fn _req ->
      %Response{text: "x", finish_reason: :stop, provider: :mock}
    end

    {:ok, %Result{} = result} =
      Loop.run("hi",
        provider: :mock,
        mock: [responder: responder],
        tools: [],
        mode: AlwaysOverflowMode,
        reactive_compact: false,
        memory: false,
        skills: %{}
      )

    assert result.finish_reason == :error_prompt_too_long
    assert Result.category(result) == :capacity
  end
end
