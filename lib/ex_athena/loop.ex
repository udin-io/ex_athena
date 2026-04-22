defmodule ExAthena.Loop do
  @moduledoc """
  Multi-turn agent loop.

  Orchestrates:

    * `infer` — hand the current message list to the provider
    * `parse_tool_calls` — pull tool calls out of the response (native +
      TextTagged fallback)
    * `permission + hooks` — deny via `Permissions` or `PreToolUse` hooks
    * `execute` — run each approved tool and append its result to the
      messages
    * `replay` — loop back to `infer` with the updated messages
    * `stop` — when the model emits text with no tool calls, or we hit the
      `:max_iterations` cap, or a hook asks to halt

  ## Options

    * `:provider` — any `ExAthena.Config.provider_module/1`-compatible value.
    * `:model`, `:temperature`, `:top_p`, `:max_tokens`, `:stop`,
      `:system_prompt`, `:messages` — forwarded to `ExAthena.Request.new/2`.
    * `:tools` — list of modules implementing `ExAthena.Tool`, or `:all`,
      or `nil` to use `config :ex_athena, tools: ...`. Defaults to builtins.
    * `:cwd` — working directory for tool execution (default: `File.cwd!/0`).
    * `:phase` — `:plan | :default | :bypass_permissions` (default `:default`).
    * `:allowed_tools` / `:disallowed_tools` — string lists passed to
      `Permissions`.
    * `:can_use_tool` — `(name, args, ctx -> :allow | :deny | {:deny, reason})`.
    * `:hooks` — see `ExAthena.Hooks`.
    * `:max_iterations` — hard stop on loop depth (default 25).
    * `:on_event` — optional `(Streaming.Event -> term())` callback that fires
      for text deltas AND synthetic tool-lifecycle events; useful for
      LiveView updates.
    * `:assigns` — a map threaded through `ctx.assigns` to every tool.

  Returns `{:ok, %{text: final_text, messages: [Message.t()], usage: map() | nil}}`
  or `{:error, reason}`.
  """

  alias ExAthena.{Config, Hooks, Messages, Permissions, Request, Tools, ToolCalls, ToolContext}
  alias ExAthena.Messages.ToolCall

  @default_max_iterations 25

  @type run_result :: {:ok, map()} | {:error, term()}

  @spec run(String.t() | nil, keyword()) :: run_result()
  def run(prompt, opts \\ []) do
    {provider_mod, opts} = Config.pop_provider!(opts)

    cwd = Keyword.get(opts, :cwd, File.cwd!())
    phase = Keyword.get(opts, :phase, :default)
    assigns = Keyword.get(opts, :assigns, %{})
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    on_event = Keyword.get(opts, :on_event)

    tool_modules = opts |> Tools.resolve() |> normalize_tool_list()

    Tools.validate!(tool_modules)

    permissions_opts = %{
      phase: phase,
      allowed_tools: Keyword.get(opts, :allowed_tools),
      disallowed_tools: Keyword.get(opts, :disallowed_tools),
      can_use_tool: Keyword.get(opts, :can_use_tool)
    }

    hooks = Keyword.get(opts, :hooks, %{})
    session_id = Keyword.get(opts, :session_id)

    ctx_base = %ToolContext{
      cwd: cwd,
      phase: phase,
      session_id: session_id,
      assigns: assigns
    }

    capabilities = provider_mod.capabilities()
    initial_request = Request.new(prompt, opts)

    initial_messages = prepend_system_prompt(initial_request, tool_modules, capabilities)

    state = %{
      messages: initial_messages,
      tool_modules: tool_modules,
      capabilities: capabilities,
      provider_mod: provider_mod,
      provider_opts: Config.provider_opts(provider_mod, opts),
      request_template: initial_request,
      permissions_opts: permissions_opts,
      hooks: hooks,
      ctx: ctx_base,
      on_event: on_event,
      usage: nil,
      final_text: nil,
      iterations: 0,
      max_iterations: max_iterations
    }

    _ = Hooks.run_lifecycle(hooks, :SessionStart, %{session_id: session_id})

    result = iterate(state)

    _ = Hooks.run_lifecycle(hooks, :SessionEnd, %{session_id: session_id})

    result
  end

  # ── Main loop ──────────────────────────────────────────────────────

  defp iterate(%{iterations: i, max_iterations: m}) when i >= m do
    {:error, {:max_iterations_exceeded, m}}
  end

  defp iterate(state) do
    request = %{
      state.request_template
      | messages: state.messages,
        tools: tool_schemas(state.tool_modules, state.capabilities),
        system_prompt: effective_system_prompt(state)
    }

    case state.provider_mod.query(request, state.provider_opts) do
      {:ok, response} ->
        emit(state.on_event, %ExAthena.Streaming.Event{type: :text_delta, data: response.text || ""})
        handle_response(response, state)

      {:error, _} = err ->
        err
    end
  end

  defp handle_response(response, state) do
    usage = response.usage || state.usage

    case extract_tool_calls(response, state.capabilities) do
      {:ok, []} ->
        {:ok,
         %{
           text: response.text,
           messages: state.messages ++ [Messages.assistant(response.text)],
           usage: usage,
           finish_reason: response.finish_reason,
           iterations: state.iterations
         }}

      {:ok, tool_calls} ->
        assistant_msg = Messages.assistant(response.text, tool_calls)

        state = %{state | messages: state.messages ++ [assistant_msg], usage: usage}

        case execute_tool_calls(tool_calls, state) do
          {:ok, tool_messages, state} ->
            iterate(%{
              state
              | messages: state.messages ++ tool_messages,
                iterations: state.iterations + 1
            })

          {:halt, reason, state} ->
            {:ok,
             %{
               text: response.text,
               messages: state.messages,
               usage: state.usage,
               finish_reason: :error,
               iterations: state.iterations,
               halted: reason
             }}
        end

      {:error, reason} ->
        {:error, {:tool_call_parse_failed, reason}}
    end
  end

  # Execute every tool call in order, appending each result to `messages`.
  # Any `{:halt, reason}` return short-circuits the loop.
  defp execute_tool_calls(calls, state) do
    Enum.reduce_while(calls, {:ok, [], state}, fn call, {:ok, acc, state} ->
      case run_one(call, state) do
        {:ok, message, state} -> {:cont, {:ok, acc ++ [message], state}}
        {:halt, reason, state} -> {:halt, {:halt, reason, state}}
      end
    end)
  end

  defp run_one(%ToolCall{name: name, arguments: args, id: id} = call, state) do
    ctx = %{state.ctx | tool_call_id: id}

    with :allow <- Permissions.check(call, ctx, state.permissions_opts),
         :ok <- Hooks.run_pre_tool_use(state.hooks, name, args, id),
         {:ok, result, state} <- dispatch_and_execute(name, args, ctx, state),
         :ok <- Hooks.run_post_tool_use(state.hooks, name, %{result: result}, id) do
      {:ok, Messages.tool_result(id, stringify(result)), state}
    else
      {:deny, reason} ->
        {:ok, Messages.tool_result(id, "permission denied: #{inspect(reason)}", true), state}

      {:halt, reason} ->
        {:halt, reason, state}

      {:error, reason, state_after} when is_map(state_after) ->
        {:ok, Messages.tool_result(id, "error: #{inspect(reason)}", true), state_after}

      {:error, reason} ->
        {:ok, Messages.tool_result(id, "error: #{inspect(reason)}", true), state}
    end
  end

  defp dispatch_and_execute(name, args, ctx, state) do
    case Tools.find(state.tool_modules, name) do
      nil ->
        {:error, {:unknown_tool, name}, state}

      mod ->
        case mod.execute(args, ctx) do
          {:ok, %{phase_transition: new_phase} = result} ->
            new_ctx = %{state.ctx | phase: new_phase}
            {:ok, Map.get(result, :message, "phase -> #{new_phase}"), %{state | ctx: new_ctx}}

          {:ok, result} ->
            {:ok, result, state}

          {:error, reason} ->
            {:error, reason, state}

          {:halt, reason} ->
            {:halt, reason}

          other ->
            {:error, {:invalid_tool_return, other}, state}
        end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp extract_tool_calls(response, capabilities) do
    ToolCalls.extract(%{tool_calls: response.tool_calls, text: response.text}, capabilities)
  end

  defp tool_schemas(modules, %{native_tool_calls: true}), do: Tools.describe_for_provider(modules)
  defp tool_schemas(_modules, _caps), do: nil

  # For providers without native tool calls, bake tool instructions into the
  # system prompt so the model knows the TextTagged protocol.
  defp effective_system_prompt(%{capabilities: %{native_tool_calls: true}} = state),
    do: state.request_template.system_prompt

  defp effective_system_prompt(state) do
    tools = Tools.describe_for_prompt(state.tool_modules)
    ToolCalls.augment_system_prompt(state.request_template.system_prompt, tools)
  end

  # If there's a system_prompt + initial messages don't include one, don't
  # inject — providers handle :system_prompt natively. But keep a hook for
  # future work that wants it inline.
  defp prepend_system_prompt(%Request{messages: messages}, _tools, _caps), do: messages

  defp normalize_tool_list(list) do
    Enum.map(list, fn
      mod when is_atom(mod) ->
        mod

      name when is_binary(name) ->
        case Tools.find(Tools.builtins(), name) do
          nil -> raise ArgumentError, "no built-in tool named #{inspect(name)}"
          mod -> mod
        end
    end)
  end

  defp stringify(s) when is_binary(s), do: s
  defp stringify(other), do: inspect(other, pretty: true, limit: :infinity)

  defp emit(nil, _event), do: :ok

  defp emit(callback, event) when is_function(callback, 1) do
    callback.(event)
    :ok
  end
end
