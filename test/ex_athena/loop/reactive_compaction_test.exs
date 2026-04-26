defmodule ExAthena.Loop.ReactiveCompactionTest do
  @moduledoc """
  PR2 — verifies the kernel's reactive recovery path: a mode that returns
  `{:error, :error_prompt_too_long}` triggers a forced pipeline pass and
  retries the same iteration once.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response, Result}
  alias ExAthena.Loop.State

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
