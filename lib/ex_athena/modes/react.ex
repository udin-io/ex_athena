defmodule ExAthena.Modes.ReAct do
  @moduledoc """
  Default mode: Reason-Act cycle.

  Each iteration:

    1. Build a Request from current messages + tools + system prompt.
    2. Call the provider (one-shot, not streaming — streaming is an
       optimisation landing in PR 4).
    3. Extract tool calls (native, or TextTagged fallback via
       `ExAthena.ToolCalls`).
    4. If no tool calls: emit `{:content, text}`, set `finish_reason:
       :stop`, and halt.
    5. If tool calls: run them (parallel-safe ones concurrently, mutating
       ones serially), append results, continue.

  Budget + mistake-counter checks happen between iterations in the kernel.
  This mode only implements the turn-by-turn behaviour.
  """

  @behaviour ExAthena.Loop.Mode

  alias ExAthena.{Budget, Messages}
  alias ExAthena.Loop.{Events, Parallel, State}
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Tools

  @impl true
  def init(%State{} = state), do: {:ok, state}

  @impl true
  def iterate(%State{} = state) do
    request = build_request(state)

    case state.provider_mod.query(request, state.provider_opts) do
      {:ok, response} ->
        # Accumulate usage + cost before considering termination.
        state = fold_usage(state, response)

        case ExAthena.ToolCalls.extract(
               %{tool_calls: response.tool_calls, text: response.text},
               state.capabilities
             ) do
          {:ok, []} ->
            # Terminal: model returned plain text with no tool calls.
            Events.emit(state.on_event, {:content, response.text || ""})

            state =
              %{
                state
                | messages: state.messages ++ [Messages.assistant(response.text)]
              }
              |> set_finish_reason(:stop)

            {:halt, state}

          {:ok, tool_calls} ->
            Events.emit(state.on_event, {:content, response.text || ""})

            assistant_msg = Messages.assistant(response.text, tool_calls)
            state = %{state | messages: state.messages ++ [assistant_msg]}

            runner = fn call, st -> run_single_tool_call(call, st) end

            case Parallel.run(tool_calls, state, runner) do
              {:ok, tool_messages, state} ->
                state = %{
                  state
                  | messages: state.messages ++ tool_messages,
                    tool_calls_made: state.tool_calls_made + length(tool_calls)
                }

                {:continue, state}

              {:halt, reason, state} ->
                state =
                  %{state | halted_reason: reason}
                  |> set_finish_reason(:error_halted)

                {:halt, state}
            end

          {:error, reason} ->
            state =
              %{state | halted_reason: {:tool_call_parse_failed, reason}}
              |> set_finish_reason(:error_during_execution)

            {:halt, state}
        end

      {:error, reason} ->
        state =
          %{state | halted_reason: reason}
          |> set_finish_reason(:error_during_execution)

        {:halt, state}
    end
  end

  # ── Tool execution for one call ───────────────────────────────────

  defp run_single_tool_call(%ToolCall{} = call, state) do
    case Parallel.pre_tool_gate(call, state) do
      :allow ->
        do_execute(call, state)

      {:deny, reason} ->
        result = Messages.tool_result(call.id, "permission denied: #{inspect(reason)}", true)
        state = bump_mistake(state)
        Parallel.emit_events(state, call, result)
        {result, state}

      {:halt, reason} ->
        {{:halt, reason}, state}
    end
  end

  defp do_execute(%ToolCall{} = call, state) do
    ctx = %{state.ctx | tool_call_id: call.id}

    case Tools.find(state.tool_modules, call.name) do
      nil ->
        result = Messages.tool_result(call.id, "unknown tool: #{call.name}", true)
        state = bump_mistake(state)
        Parallel.emit_events(state, call, result)
        {result, state}

      mod ->
        case mod.execute(call.arguments, ctx) do
          {:ok, %{phase_transition: new_phase} = payload} ->
            # Phase transition sentinel — special-case only in the single-tool runner.
            msg = Map.get(payload, :message, "phase -> #{new_phase}")
            state = %{state | ctx: %{state.ctx | phase: new_phase}} |> reset_mistakes()
            result = Messages.tool_result(call.id, to_string(msg))
            after_post_hook(state, call, result)

          {:ok, payload} ->
            result = Messages.tool_result(call.id, stringify(payload))
            state = reset_mistakes(state)
            after_post_hook(state, call, result)

          {:error, reason} ->
            result = Messages.tool_result(call.id, "error: #{stringify(reason)}", true)
            state = bump_mistake(state)
            after_post_hook(state, call, result)

          {:halt, reason} ->
            {{:halt, reason}, state}

          other ->
            result = Messages.tool_result(call.id, "invalid tool return: #{inspect(other)}", true)
            state = bump_mistake(state)
            after_post_hook(state, call, result)
        end
    end
  end

  # Run PostToolUse hooks then emit events.
  defp after_post_hook(state, call, result) do
    case ExAthena.Hooks.run_post_tool_use(state.hooks, call.name, %{result: result}, call.id) do
      {:halt, reason} -> {{:halt, reason}, state}
      _ -> emit_and_return(state, call, result)
    end
  end

  defp emit_and_return(state, call, result) do
    Parallel.emit_events(state, call, result)
    {result, state}
  end

  # ── State helpers ─────────────────────────────────────────────────

  defp bump_mistake(%State{consecutive_mistakes: n} = state),
    do: %{state | consecutive_mistakes: n + 1}

  defp reset_mistakes(state), do: %{state | consecutive_mistakes: 0}

  defp set_finish_reason(state, reason) do
    put_in(state.meta[:finish_reason], reason)
  end

  defp fold_usage(state, response) do
    budget = state.budget || Budget.new()
    new_budget = Budget.add(budget, response.usage, nil)

    if response.usage do
      Events.emit(state.on_event, {:usage, response.usage})
    end

    %{state | budget: new_budget}
  end

  # ── Request building ──────────────────────────────────────────────

  defp build_request(state) do
    %{
      state.request_template
      | messages: state.messages,
        tools: tool_schemas(state.tool_modules, state.capabilities),
        system_prompt: effective_system_prompt(state)
    }
  end

  defp tool_schemas(modules, %{native_tool_calls: true}), do: Tools.describe_for_provider(modules)
  defp tool_schemas(_modules, _caps), do: nil

  defp effective_system_prompt(%State{capabilities: %{native_tool_calls: true}} = state),
    do: state.request_template.system_prompt

  defp effective_system_prompt(state) do
    ExAthena.ToolCalls.augment_system_prompt(
      state.request_template.system_prompt,
      Tools.describe_for_prompt(state.tool_modules)
    )
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value, pretty: true, limit: :infinity)
end
