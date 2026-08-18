defmodule ExAthena.Loop.Inference do
  @moduledoc """
  The single instrumented path for every provider call made inside a run.

  ReAct's main turn, PlanAndSolve's planning turn, Reflexion's critique,
  the conclusion-distillation micro-call, and the compaction summary all
  route through `call/3`, which uniformly applies:

    * **Request queue** — the call holds a `ExAthena.RequestQueue` slot for
      its full lifetime (per-provider concurrency gating for scarce local
      GPU slots), with `{:queue_wait, …}` loop events emitted on real waits.
    * **ChatParams hooks** — hosts adjusting params per call (or halting)
      see every conversational inference, not just the main turn. Disable
      with `chat_params: false` for runtime utility calls whose fixed
      micro-budgets must not be reshaped by conversational hooks.
    * **Telemetry** — the `[:ex_athena, :chat]` span fires for every call,
      with GenAI-semconv metadata plus a `:purpose` tag
      (`:turn`, `:planning`, `:reflection`, `:conclusion_distillation`,
      `:compaction_summary`) so metering hosts can attribute cost.
    * **Budget accounting** — usage and cost fold into `state.budget` with
      full cost extraction (`total_cost`, or `input_cost`/`output_cost`
      summed on the fly), and a `{:usage, usage}` loop event is emitted.

  ## Starvation policy (`:starvation` — required)

  Adapters flag output-starved turns (`response.starvation`) so the kernel
  can retry the iteration once with an escalated `max_tokens`
  (see `ExAthena.Loop`, issue #194). That escalation raises the run's
  request-template completion cap ~4x for the REST of the run and re-runs
  the whole iteration — the right response when a full turn starves, and a
  disproportionate one when a fixed 256-token utility call does.

  Every call site must therefore state its policy explicitly:

    * `starvation: :surface` — full, turn-shaped calls (main turn,
      planning). A starved response returns
      `{:error, {:error_thinking_starved, info, folded_state}}` so the
      kernel escalates; the folded state keeps the starved attempt's token
      burn on the budget across the retry.
    * `starvation: :tolerate` — internal micro-calls (critique,
      distillation, summary). A starved response returns `{:ok, response,
      folded_state}` like any other; the caller treats the blank text as a
      failed micro-call and falls back gracefully. The kernel's escalation
      must never fire for these — a mis-sized micro-call must not inflate
      the main turn's completion cap.
  """

  alias ExAthena.{Budget, Telemetry}
  alias ExAthena.Loop.{Events, State}

  @type option ::
          {:purpose, atom()}
          | {:starvation, :surface | :tolerate}
          | {:chat_params, boolean()}
          | {:stream_cb, (term() -> term()) | nil}

  @doc """
  Run one provider inference through the shared instrumented path.

  Options:

    * `:purpose` (required) — atom tag for telemetry attribution.
    * `:starvation` (required) — `:surface` or `:tolerate`; see moduledoc.
    * `:chat_params` — fire ChatParams hooks (default `true`). ReAct passes
      `false` because it applies them once per iteration itself (via
      `apply_chat_params/2`) so a transient-error retry cannot double-fire
      hooks or double-append `{:inject, …}` messages.
    * `:stream_cb` — provider stream callback (from
      `ExAthena.Modes.ReAct.stream_callback/1`); `nil` for one-shot
      `query/2` calls.

  Returns:

    * `{:ok, response, state}` — usage + cost folded into `state.budget`,
      `{:usage, _}` emitted.
    * `{:halt, reason}` — a ChatParams hook halted before the call.
    * `{:error, {:error_thinking_starved, info, state}}` — starved response
      under `starvation: :surface`; state carries the folded budget.
    * `{:error, reason}` — provider error, unchanged.
  """
  @spec call(State.t(), ExAthena.Request.t(), [option()]) ::
          {:ok, ExAthena.Response.t(), State.t()}
          | {:halt, term()}
          | {:error, {:error_thinking_starved, map(), State.t()}}
          | {:error, term()}
  def call(%State{} = state, request, opts) do
    purpose = Keyword.fetch!(opts, :purpose)
    starvation = Keyword.fetch!(opts, :starvation)
    stream_cb = Keyword.get(opts, :stream_cb)

    with {:ok, request, state} <- maybe_chat_params(state, request, opts) do
      chat_meta =
        Telemetry.genai_meta(
          operation: "chat",
          provider: state.provider_mod,
          request_model: request.model,
          conversation_id: Map.get(state.meta, :conversation_id),
          purpose: purpose
        )

      result =
        Telemetry.span([:ex_athena, :chat], chat_meta, fn ->
          queued_call(state, request, stream_cb)
        end)

      case result do
        {:ok, response} -> handle_response(state, response, starvation)
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Fire ChatParams hooks for `request`. Returns `{:ok, request, state}`
  (with any `{:inject, msg}` returns appended to both the request's and the
  state's messages) or `{:halt, reason}` when a hook bailed.

  Exposed for callers that must fire hooks exactly once outside `call/3`
  (ReAct fires them per iteration, before its transient-error retry path).
  """
  @spec apply_chat_params(State.t(), ExAthena.Request.t()) ::
          {:ok, ExAthena.Request.t(), State.t()} | {:halt, term()}
  def apply_chat_params(%State{} = state, request) do
    payload = %{
      request: request,
      session_id: state.session_id,
      messages: request.messages
    }

    outputs = ExAthena.Hooks.run_lifecycle_with_outputs(state.hooks, :ChatParams, payload)

    case outputs.halt do
      {:halt, reason} ->
        {:halt, reason}

      _ ->
        request_with_injects =
          case outputs.injects do
            [] -> request
            list -> %{request | messages: request.messages ++ list}
          end

        state =
          case outputs.injects do
            [] -> state
            list -> %{state | messages: state.messages ++ list}
          end

        {:ok, request_with_injects, state}
    end
  end

  # ── Internal ──────────────────────────────────────────────────────

  # Fold usage first — the starved attempt's token burn stays on the
  # budget whichever way the starvation policy sends the result.
  defp handle_response(state, response, starvation_mode) do
    state = fold_usage(state, response)

    case {response.starvation, starvation_mode} do
      {%{} = info, :surface} -> {:error, {:error_thinking_starved, info, state}}
      _ -> {:ok, response, state}
    end
  end

  defp maybe_chat_params(state, request, opts) do
    if Keyword.get(opts, :chat_params, true) do
      apply_chat_params(state, request)
    else
      {:ok, request, state}
    end
  end

  # Every provider call goes through the request queue (per-call granularity)
  # so concurrent loops — especially subagents — serialize on the provider's
  # scarce slots (local GPUs serve 1-3 concurrent requests). The slot is held
  # for the full call/stream lifetime and released on every exit path; the
  # provider's own timeout_ms only starts once the slot is acquired.
  defp queued_call(state, request, stream_cb) do
    ExAthena.RequestQueue.with_slot(
      state.meta[:provider_atom],
      fn -> provider_call(state, request, stream_cb) end,
      Keyword.merge(
        state.meta[:queue_opts] || [],
        on_wait: Events.queue_wait_emitter(state.on_event, state.meta[:provider_atom])
      )
    )
  end

  defp provider_call(state, request, nil),
    do: state.provider_mod.query(request, state.provider_opts)

  defp provider_call(state, request, stream_cb),
    do: state.provider_mod.stream(request, stream_cb, state.provider_opts)

  defp fold_usage(state, response) do
    budget = state.budget || Budget.new()
    cost = extract_cost(response.usage)
    new_budget = Budget.add(budget, response.usage, cost)

    if response.usage do
      Events.emit(state.on_event, {:usage, response.usage})
    end

    %{state | budget: new_budget}
  end

  defp extract_cost(nil), do: nil

  defp extract_cost(usage) when is_map(usage) do
    # req_llm uses :total_cost (in USD). Some providers may emit
    # input_cost/output_cost split with no total — sum them on the fly.
    cond do
      cost = Map.get(usage, :total_cost) ->
        cost

      cost = Map.get(usage, "total_cost") ->
        cost

      ic = Map.get(usage, :input_cost) || Map.get(usage, "input_cost") ->
        oc = Map.get(usage, :output_cost) || Map.get(usage, "output_cost") || 0
        ic + oc

      true ->
        nil
    end
  end

  defp extract_cost(_), do: nil
end
