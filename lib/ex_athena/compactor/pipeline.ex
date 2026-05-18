defmodule ExAthena.Compactor.Pipeline do
  @moduledoc """
  Multi-stage context-compaction runner.

  The Claude Code paper describes Anthropic's compaction as a five-layer
  pipeline (Budget Reduction → Snip → Microcompact → Context Collapse →
  Auto-Compact / Summary), each layer cheaper than the next. The
  cheaper layers run first; the LLM-summary layer fires only when
  deterministic shrinkage couldn't get the conversation under target.

  The pipeline implements the existing `ExAthena.Compactor` behaviour,
  so `loop.ex` doesn't have to change — the kernel still calls
  `compactor.should_compact?/2` then `compactor.compact/2`. Internally
  this module dispatches across a list of `ExAthena.Compactor.Stage`
  modules.

  ## Configuration

  The stage list is read from `state.meta[:compaction_pipeline]`,
  falling back to `ExAthena.Compactor.Stage.default_pipeline/0`. Hosts
  can swap individual stages or replace the list entirely.

      Loop.run("hi",
        provider: ...,
        compactor: ExAthena.Compactor.Pipeline,
        compaction_pipeline: [MyApp.MyStage, ExAthena.Compactors.Summary]
      )

  ## Reactive recovery

  When a mode signals `:error_prompt_too_long`, the kernel re-invokes
  the pipeline with `force: true`, which runs every stage regardless
  of cost. See `run/3`.
  """

  @behaviour ExAthena.Compactor

  require Logger

  alias ExAthena.Compactor
  alias ExAthena.Compactor.Stage
  alias ExAthena.Loop.State
  alias ExAthena.Messages.Message
  alias ExAthena.Telemetry

  @impl ExAthena.Compactor
  def should_compact?(%State{} = state, %{tokens: tokens, max_tokens: max} = estimate) do
    threshold = compact_at(state)
    forced? = Map.get(estimate, :force, false)

    forced? or (max > 0 and tokens >= trunc(threshold * max))
  end

  @impl ExAthena.Compactor
  def compact(%State{} = state, estimate) do
    run(state, estimate, force: false)
  end

  @doc """
  Run the pipeline. `force: true` makes every stage attempt
  compaction unconditionally; this is the reactive-recovery path the
  loop uses after a context-window error from the provider.

  Returns `{:compact, messages, metadata}` if at least one stage
  reduced the conversation, `:skip` if every stage declined, or
  `{:error, reason}` on the first stage that surfaces an error.
  """
  @spec run(State.t(), Compactor.estimate(), keyword()) :: Compactor.decision()
  def run(%State{} = state, estimate, opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    stages = pipeline(state)

    initial = {state, estimate, []}

    {final_state, final_estimate, applied} =
      Enum.reduce(stages, initial, fn stage, {st, est, log} ->
        run_stage(stage, st, est, log, force?)
      end)
      |> case do
        {:error, _reason} = err -> err
        result -> result
      end
      |> case do
        {:error, _} = err -> throw({:pipeline_error, err})
        {st, est, log} -> {st, est, log}
      end

    case applied do
      [] ->
        :skip

      _ ->
        metadata = %{
          before: estimate.tokens,
          after: final_estimate.tokens,
          stages_applied: applied,
          dropped_count: length(state.messages) - length(final_state.messages),
          reason: if(force?, do: :reactive_recovery, else: :token_budget),
          budget: final_state.budget
        }

        {:compact, final_state.messages, metadata}
    end
  catch
    {:pipeline_error, err} -> err
  end

  # ── Per-stage execution ──────────────────────────────────────────

  defp run_stage(stage, state, estimate, log, force?) do
    target = trunc(compact_at(state) * estimate.max_tokens)

    cond do
      not force? and estimate.tokens <= target ->
        # Already under target — short-circuit.
        {state, estimate, log}

      true ->
        _ =
          ExAthena.Hooks.run_lifecycle(state.hooks, :PreCompactStage, %{
            stage: stage.name(),
            estimate: estimate
          })

        result =
          Telemetry.span(
            [:ex_athena, :compaction, stage.name()],
            %{stage: stage.name()},
            fn -> stage.compact_stage(state, estimate) end
          )

        case result do
          {:ok, new_state, new_estimate} ->
            {restore_pinned(new_state, state.messages), new_estimate, log ++ [stage.name()]}

          :skip ->
            {state, estimate, log}

          {:error, reason} ->
            {:error, {stage.name(), reason}}
        end
    end
  end

  # ── Pin protection ───────────────────────────────────────────────

  # After a stage runs, re-insert any pinned messages it dropped.
  # Pinned messages are re-inserted at proportional positions relative
  # to the original list.  We sort by target position descending before
  # inserting so that no insertion shifts the position of a later one
  # (inserting at a higher index first means all lower-index insertions
  # are unaffected).  When the stage dropped everything (new_total == 0)
  # we fall back to orig_idx directly so original relative order is kept.
  defp restore_pinned(%State{messages: new_messages} = state, original_messages) do
    orig_total = length(original_messages)

    missing =
      original_messages
      |> Enum.with_index()
      |> Enum.filter(fn {%Message{pin: pin}, _} -> pin end)
      |> Enum.reject(fn {msg, _} -> msg in new_messages end)

    case missing do
      [] ->
        state

      _ ->
        Logger.warning(
          "[ExAthena.Compactor.Pipeline] restore_pinned: re-inserting #{length(missing)} pinned message(s) dropped by a compaction stage"
        )

        new_total = length(new_messages)

        restored =
          missing
          |> Enum.map(fn {msg, orig_idx} ->
            insert_at =
              if new_total > 0 do
                round(orig_idx * new_total / orig_total)
              else
                orig_idx
              end

            {insert_at, msg}
          end)
          |> Enum.sort_by(&elem(&1, 0), :desc)
          |> Enum.reduce(new_messages, fn {pos, msg}, msgs ->
            List.insert_at(msgs, pos, msg)
          end)

        %{state | messages: restored}
    end
  end

  # ── Configuration ────────────────────────────────────────────────

  @doc false
  def pipeline(%State{meta: meta}) do
    Map.get(meta, :compaction_pipeline) || Stage.default_pipeline()
  end

  defp compact_at(%State{meta: meta}) do
    Map.get(meta, :compact_at) ||
      case Application.get_env(:ex_athena, :compactor) do
        kw when is_list(kw) -> Keyword.get(kw, :compact_at, 0.6)
        m when is_map(m) -> Map.get(m, :compact_at, 0.6)
        _ -> 0.6
      end
  end
end
