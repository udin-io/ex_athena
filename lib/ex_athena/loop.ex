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
    * `:session_id` — stable identifier for this run. Threaded into the
      `ToolContext` and used by hooks / storage / sidechain transcripts.
      Auto-generated when omitted.
    * `:parent_session_id` — when this run is a subagent of another run,
      the parent's `session_id`. `nil` for top-level runs. Used by
      `ExAthena.Sessions.Stores.Jsonl` (PR5) to write subagent
      sidechains and by `ExAthena.Agents` (PR4) to scope worktrees.
    * `:memory` — `:auto` (default — discover `AGENTS.md`/`CLAUDE.md`
      from `cwd` and `~/.config/ex_athena/`), `false` (skip memory
      entirely), or an explicit list of `Message.t()` to prepend.
    * `:skills` — `:auto` (default — discover skills from
      `<cwd>/.exathena/skills/` and `~/.config/ex_athena/skills/`),
      `false` (skip), or an explicit `%{name => %Skill{}}` map.
    * `:preload_skills` — list of skill names whose bodies should be
      activated up-front (skips the `[skill: name]` sentinel
      round-trip).

  ## Returns

    * `{:ok, Result.t()}` — ran to termination (possibly with an error
      subtype like `:error_max_turns`; the Result contains the
      classification).
    * `{:error, reason}` — unexpected failure before the loop started
      (e.g. unknown provider, bad tool module).
  """

  alias ExAthena.{Budget, Config, Error, Memory, Request, Result, Skills, Telemetry, Tools}
  alias ExAthena.Loop.{Events, Mode, State}

  @default_max_iterations 25
  @default_max_mistakes 3
  @default_max_concurrency 4
  @default_tool_timeout_ms 60_000

  @spec run(String.t() | nil, keyword()) :: {:ok, Result.t()} | {:error, term()}
  def run(prompt, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)

    meta =
      Telemetry.genai_meta(
        operation: "invoke_agent",
        provider: Keyword.get(opts, :provider),
        request_model: Keyword.get(opts, :model),
        agent_id: Keyword.get(opts, :agent_id),
        conversation_id: Keyword.get(opts, :conversation_id)
      )

    Telemetry.span([:ex_athena, :loop], meta, fn ->
      with {:ok, state} <- build_initial_state(prompt, opts),
           {:ok, state} <- state.mode.init(state) do
        state |> loop() |> to_result(started_at)
      end
    end)
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
        case maybe_compact(state) do
          {:ok, state} ->
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

          {:error, reason} ->
            state
            |> Map.put(:halted_reason, reason)
            |> set_finish_reason(:error_compaction_failed)
        end
    end
  end

  # ── Compaction ────────────────────────────────────────────────────

  defp maybe_compact(%State{} = state) do
    compactor = compactor_module(state)

    estimate = %{
      tokens: ExAthena.Compactor.estimate_tokens(state.messages),
      max_tokens: state.capabilities[:max_tokens] || 128_000
    }

    if function_exported?(compactor, :should_compact?, 2) and
         compactor.should_compact?(state, estimate) do
      _ = ExAthena.Hooks.run_lifecycle(state.hooks, :PreCompact, %{estimate: estimate})

      case compactor.compact(state, estimate) do
        {:compact, new_messages, metadata} ->
          new_budget = Map.get(metadata, :budget, state.budget)

          Events.emit(state.on_event, {:compaction, metadata})

          Telemetry.event(
            [:ex_athena, :compaction, :stop],
            %{
              before_tokens: Map.get(metadata, :before),
              after_tokens: Map.get(metadata, :after),
              dropped_count: Map.get(metadata, :dropped_count)
            },
            %{reason: Map.get(metadata, :reason)}
          )

          {:ok, %{state | messages: new_messages, budget: new_budget}}

        :skip ->
          {:ok, state}

        {:error, _} = err ->
          err
      end
    else
      {:ok, state}
    end
  end

  defp compactor_module(%State{meta: meta}) do
    Map.get(meta, :compactor) ||
      Application.get_env(:ex_athena, :compactor_module) ||
      ExAthena.Compactors.Summary
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
    session_id = Keyword.get(opts, :session_id) || generate_session_id()
    parent_session_id = Keyword.get(opts, :parent_session_id)

    tool_modules = opts |> Tools.resolve() |> normalize_tool_list()

    with :ok <- validate_tools(tool_modules) do
      capabilities = provider_mod.capabilities()

      memory_messages = resolve_memory(cwd, opts)
      skills = resolve_skills(cwd, opts)

      request_template =
        prompt
        |> Request.new(opts)
        |> apply_skills_catalog(skills)

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
          session_id: session_id,
          assigns: assigns
        )

      preloaded_skills =
        []
        |> Skills.preload(skills, Keyword.get(opts, :preload_skills, []))

      initial_messages =
        memory_messages ++ preloaded_skills ++ request_template.messages

      state = %State{
        messages: initial_messages,
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
        session_id: session_id,
        parent_session_id: parent_session_id,
        meta:
          opts
          |> compaction_meta()
          |> Map.put(:skills, skills)
          |> Map.put(:memory_count, length(memory_messages))
          |> Map.put(:preloaded_skill_count, length(preloaded_skills))
      }

      _ =
        ExAthena.Hooks.run_lifecycle(state.hooks, :SessionStart, %{
          session_id: session_id,
          parent_session_id: parent_session_id
        })

      {:ok, state}
    end
  end

  defp generate_session_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  # ── Memory + skills resolution ────────────────────────────────────

  defp resolve_memory(_cwd, opts) do
    case Keyword.get(opts, :memory, :auto) do
      false -> []
      :auto -> Memory.discover(opts |> Keyword.get(:cwd) || File.cwd!())
      list when is_list(list) -> list
    end
  end

  defp resolve_skills(_cwd, opts) do
    case Keyword.get(opts, :skills, :auto) do
      false -> %{}
      :auto -> Skills.discover(opts |> Keyword.get(:cwd) || File.cwd!())
      map when is_map(map) -> map
    end
  end

  defp apply_skills_catalog(%Request{} = request, skills) when map_size(skills) == 0,
    do: request

  defp apply_skills_catalog(%Request{system_prompt: sp} = request, skills) do
    catalog = Skills.catalog_section(skills)

    new_sp =
      case {sp, catalog} do
        {_, ""} -> sp
        {nil, c} -> c
        {prefix, c} -> prefix <> "\n\n" <> c
      end

    %{request | system_prompt: new_sp}
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

  defp compaction_meta(opts) do
    [
      :compactor,
      :compact_at,
      :pinned_prefix_count,
      :live_suffix_count,
      :conversation_id,
      :agent_id
    ]
    |> Enum.reduce(%{}, fn key, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end
end
