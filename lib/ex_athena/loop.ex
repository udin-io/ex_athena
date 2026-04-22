defmodule ExAthena.Loop do
  @moduledoc """
  Agent-loop kernel. Dispatches to a `ExAthena.Loop.Mode` implementation
  and handles everything around it: caps, budget, hooks, counters, events,
  and termination accounting.

  Public entry point: `run/2`, returning `{:ok, %ExAthena.Result{}} |
  {:error, reason}`.

  ## v0.3 breaking change

  The return shape is now an `ExAthena.Result` struct instead of a loose
  map. Every termination — success or error — produces a Result with the
  typed `finish_reason` (see `ExAthena.Loop.Terminations` for the
  enumeration). Callers can dispatch on `Result.category/1`
  (`:success | :retryable | :capacity | :fatal`) instead of pattern-matching
  individual atoms.

  ## Options

    * `:provider` — required. Provider atom (`:ollama`, `:openai`,
      `:claude`, `:mock`, `:req_llm`) or a module implementing
      `ExAthena.Provider`.
    * `:model`, `:system_prompt`, `:messages`, `:temperature`, `:top_p`,
      `:max_tokens`, `:stop`, `:timeout_ms`, `:tool_choice`,
      `:response_format`, `:provider_opts`, `:metadata` — forwarded to
      `ExAthena.Request.new/2`.
    * `:tools` — list of modules implementing `ExAthena.Tool` or `:all`
      (default — all builtins). `nil` falls back to `config :ex_athena,
      tools: …`.
    * `:mode` — atom (`:react`, `:plan_and_solve`, `:reflexion`) or module.
      Defaults to `:react`.
    * `:cwd`, `:phase`, `:assigns` — threaded into every tool's
      `ExAthena.ToolContext`.
    * `:allowed_tools`, `:disallowed_tools`, `:can_use_tool` — see
      `ExAthena.Permissions`.
    * `:hooks` — see `ExAthena.Hooks`.
    * `:max_iterations` (default 25) — hard iteration cap.
    * `:max_consecutive_mistakes` (default 3) — counter threshold at
      which the loop terminates with `:error_consecutive_mistakes`.
    * `:max_budget_usd` — optional float. Trips
      `:error_max_budget_usd` when cumulative cost crosses it.
    * `:tool_timeout_ms` (default 60_000) — per-call timeout for parallel
      tool execution.
    * `:max_concurrency` (default 4) — `Task.async_stream` concurrency
      cap for parallel-safe tool calls in a single iteration.
    * `:on_event` — `(ExAthena.Loop.Events.t -> term)` callback for
      streaming. Events are flat tuples (`{:content, text}`,
      `{:tool_call, tc}`, `{:tool_result, tr}`, `{:iteration, n}`,
      `{:usage, u}`, `{:error, reason}`, `{:done, Result}`).

  ## Returns

    * `{:ok, Result.t()}` — ran to termination (possibly with an error
      subtype like `:error_max_turns`; the Result contains the
      classification).
    * `{:error, reason}` — unexpected failure before the loop started
      (e.g. unknown provider, bad tool module).
  """

  alias ExAthena.{Budget, Config, Error, Request, Result, Tools}
  alias ExAthena.Loop.{Events, Mode, State}

  @default_max_iterations 25
  @default_max_mistakes 3
  @default_max_concurrency 4
  @default_tool_timeout_ms 60_000

  @spec run(String.t() | nil, keyword()) :: {:ok, Result.t()} | {:error, term()}
  def run(prompt, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, state} <- build_initial_state(prompt, opts),
         {:ok, state} <- state.mode.init(state) do
      state |> loop() |> to_result(started_at)
    end
  end

  # ── Loop body ─────────────────────────────────────────────────────

  defp loop(%State{} = state) do
    cond do
      state.iterations >= state.max_iterations ->
        state
        |> set_finish_reason(:error_max_turns)

      state.consecutive_mistakes >= state.max_consecutive_mistakes ->
        state
        |> set_finish_reason(:error_consecutive_mistakes)

      Budget.exceeded?(state.budget, state.max_budget_usd) ->
        state
        |> set_finish_reason(:error_max_budget_usd)

      true ->
        Events.emit(state.on_event, {:iteration, state.iterations})

        case state.mode.iterate(state) do
          {:continue, new_state} ->
            loop(%{new_state | iterations: new_state.iterations + 1})

          {:halt, new_state} ->
            new_state

          {:error, reason} ->
            state
            |> Map.put(:halted_reason, reason)
            |> set_finish_reason(:error_during_execution)
        end
    end
  end

  defp set_finish_reason(%State{} = state, reason) do
    put_in(state.meta[:finish_reason], reason)
  end

  # ── Result construction ───────────────────────────────────────────

  defp to_result({:error, _} = err, _), do: err

  defp to_result(%State{} = state, started_at) do
    finish_reason = state.meta[:finish_reason] || :stop
    final_text = extract_final_text(state)

    duration_ms = System.monotonic_time(:millisecond) - started_at

    result = %Result{
      text: final_text,
      messages: state.messages,
      finish_reason: finish_reason,
      halted_reason: state.halted_reason,
      iterations: state.iterations,
      tool_calls_made: state.tool_calls_made,
      usage: state.budget && state.budget.usage,
      cost_usd: state.budget && state.budget.cost_usd,
      duration_ms: duration_ms,
      model: state.request_template && state.request_template.model,
      provider: state.provider_mod,
      telemetry: %{}
    }

    Events.emit(state.on_event, {:done, result})

    {:ok, result}
  end

  defp extract_final_text(%State{messages: messages}) do
    # The last assistant message's content is the final text. Errors with no
    # final assistant message leave text nil (callers can still inspect
    # halted_reason / finish_reason).
    messages
    |> Enum.reverse()
    |> Enum.find_value(nil, fn
      %{role: :assistant, content: c} when is_binary(c) -> c
      _ -> nil
    end)
  end

  # ── Initial state assembly ────────────────────────────────────────

  defp build_initial_state(prompt, opts) do
    {provider_mod, opts} = Config.pop_provider!(opts)

    cwd = Keyword.get(opts, :cwd, File.cwd!())
    phase = Keyword.get(opts, :phase, :default)
    assigns = Keyword.get(opts, :assigns, %{})
    mode = opts |> Keyword.get(:mode, :react) |> Mode.resolve()

    tool_modules = opts |> Tools.resolve() |> normalize_tool_list()

    with :ok <- validate_tools(tool_modules) do
      capabilities = provider_mod.capabilities()
      request_template = Request.new(prompt, opts)

      permissions_opts = %{
        phase: phase,
        allowed_tools: Keyword.get(opts, :allowed_tools),
        disallowed_tools: Keyword.get(opts, :disallowed_tools),
        can_use_tool: Keyword.get(opts, :can_use_tool)
      }

      ctx =
        ExAthena.ToolContext.new(
          cwd: cwd,
          phase: phase,
          session_id: Keyword.get(opts, :session_id),
          assigns: assigns
        )

      state = %State{
        messages: request_template.messages,
        tool_modules: tool_modules,
        capabilities: capabilities,
        provider_mod: provider_mod,
        provider_opts: Config.provider_opts(provider_mod, opts),
        request_template: request_template,
        permissions_opts: permissions_opts,
        hooks: Keyword.get(opts, :hooks, %{}),
        ctx: ctx,
        on_event: Keyword.get(opts, :on_event),
        budget: Budget.new(),
        max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
        max_consecutive_mistakes:
          Keyword.get(opts, :max_consecutive_mistakes, @default_max_mistakes),
        max_budget_usd: Keyword.get(opts, :max_budget_usd),
        tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms, @default_tool_timeout_ms),
        max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
        mode: mode,
        mode_state: %{},
        meta: %{}
      }

      _ = ExAthena.Hooks.run_lifecycle(state.hooks, :SessionStart, %{})

      {:ok, state}
    end
  end

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

  defp validate_tools(tool_modules) do
    try do
      Tools.validate!(tool_modules)
      :ok
    rescue
      e in ArgumentError ->
        {:error, Error.new(:bad_request, Exception.message(e), provider: :loop)}
    end
  end
end
