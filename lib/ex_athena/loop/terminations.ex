defmodule ExAthena.Loop.Terminations do
  @moduledoc """
  Typed termination subtypes for agent-loop runs.

  Every run ends with exactly one termination. Normal completions use `:stop`;
  everything else is an error subtype carrying enough context (usage, cost,
  duration) to drive retries and observability.

  Inspired by the Claude Agent SDK's typed termination subtypes — they keep
  accounting uniform across happy and sad paths.

  ## Subtypes

    * `:stop` — model returned text with no tool calls.
    * `:submitted` — model explicitly called the `finish` tool to declare
      completion. The `Result.deliverable` field carries the payload.
    * `:stopped` — a human interrupted the run (the UI's stop button). Not a
      fault and not a success: whatever the run had produced by then is kept
      and persisted, exactly as a completed run's output is.
    * `:error_max_turns` — iteration cap reached.
    * `:error_max_budget_usd` — cost ceiling tripped.
    * `:error_max_input_tokens` — cumulative input tokens crossed the cap.
      The cost ceiling is inert on a local provider (every call is free), so
      this is the spend rail that actually bites there. Category `:capacity`;
      `Result.conclusions`/`todos` still carry what the run learned, which is
      how `SpawnAgent` hands a capped worker's findings back to its parent.
    * `:error_during_execution` — unrecoverable tool / provider error.
    * `:error_max_structured_output_retries` — repair budget exhausted.
    * `:error_consecutive_mistakes` — mistake counter threshold hit.
    * `:error_halted` — hook or tool returned `:halt`.
    * `:error_compaction_failed` — context compaction failed.
    * `:error_prompt_too_long` — provider rejected the request because the
      assembled prompt exceeded the model's context window. Modes signal this
      to the kernel so the compaction pipeline can attempt reactive recovery
      before the run terminates.
    * `:error_no_progress` — consecutive-iteration productivity threshold
      exceeded; the last N iterations produced identical tool calls with no
      new text. The `Result.no_progress_snapshot` field carries the stuck
      message pairs for remediation reprompts.
    * `:error_schema_validation` — model output could not be parsed as valid
      structured output or tool calls. Category `:retryable`; caller may retry
      with a reformat prompt hint. `Result.error_diagnostic` carries the
      structured failure payload.
    * `:error_provider_auth` — provider returned HTTP 401 or 403. Category
      `:fatal`; blind retry will not help — operator must fix credentials.
    * `:error_thinking_starved` — a hybrid thinking model burned the
      per-turn completion budget on reasoning and produced no visible
      output, and the kernel's single escalated-budget retry was also
      starved (or there was no context-window headroom to escalate into).
      Category `:capacity`; raise `:max_tokens`, reduce prompt size, or use
      a non-thinking model. The `Result.halted_reason` message names the
      token counts; `Result.error_diagnostic` carries them structured.
  """

  @type subtype ::
          :stop
          | :submitted
          | :stopped
          | :error_max_turns
          | :error_max_budget_usd
          | :error_max_input_tokens
          | :error_during_execution
          | :error_max_structured_output_retries
          | :error_consecutive_mistakes
          | :error_halted
          | :error_compaction_failed
          | :error_prompt_too_long
          | :error_no_progress
          | :error_schema_validation
          | :error_provider_auth
          | :error_thinking_starved

  @all_subtypes [
    :stop,
    :submitted,
    :stopped,
    :error_max_turns,
    :error_max_budget_usd,
    :error_max_input_tokens,
    :error_during_execution,
    :error_max_structured_output_retries,
    :error_consecutive_mistakes,
    :error_halted,
    :error_compaction_failed,
    :error_prompt_too_long,
    :error_no_progress,
    :error_schema_validation,
    :error_provider_auth,
    :error_thinking_starved
  ]

  @doc "All known termination subtypes."
  @spec all() :: [subtype()]
  def all, do: @all_subtypes

  @doc "Is this a successful termination?"
  @spec success?(subtype()) :: boolean()
  def success?(:stop), do: true
  def success?(:submitted), do: true
  def success?(_), do: false

  @doc "Did a human end this run on purpose?"
  @spec interrupted?(subtype()) :: boolean()
  def interrupted?(:stopped), do: true
  def interrupted?(_), do: false

  @doc "Is this an error termination?"
  @spec error?(subtype()) :: boolean()
  def error?(:stop), do: false
  def error?(:submitted), do: false
  def error?(:stopped), do: false
  def error?(_), do: true

  @doc """
  Categorise a termination for retry classification. Returns one of:
  `:retryable`, `:capacity`, `:fatal`.

    * `:interrupted` — a human stopped it; retry only if they ask.
    * `:retryable` — transient; caller may retry on a new run.
    * `:capacity` — the run hit a configured limit; caller should increase
      the limit or reduce scope.
    * `:fatal` — don't retry without operator action.
  """
  @doc """
  Did this run stop because it ran out of room, rather than because it went
  wrong?

  Deliberately NOT `category/1 == :capacity`. That category also covers
  `:error_consecutive_mistakes`, `:error_no_progress` and
  `:error_max_structured_output_retries` — a run that hallucinated, went in
  circles, or could not produce parseable output. Those are faults, and a
  caller re-issuing the same work will reproduce them. The five below are
  budgets: the same work with more room, or less of it, would have finished.

  `SpawnAgent` uses this to decide whether a worker's termination should
  advance its parent's consecutive-mistake counter. Session 5906635b743d died
  on that counter with every deliverable already written, because a worker
  exhausting its token budget was scored as the parent hallucinating a tool
  call.
  """
  @spec budget_exhaustion?(subtype()) :: boolean()
  def budget_exhaustion?(:error_max_input_tokens), do: true
  def budget_exhaustion?(:error_max_budget_usd), do: true
  def budget_exhaustion?(:error_max_turns), do: true
  def budget_exhaustion?(:error_prompt_too_long), do: true
  def budget_exhaustion?(:error_thinking_starved), do: true
  def budget_exhaustion?(_), do: false

  @spec category(subtype()) :: :success | :interrupted | :retryable | :capacity | :fatal
  def category(:stop), do: :success
  def category(:submitted), do: :success
  def category(:stopped), do: :interrupted
  def category(:error_max_turns), do: :capacity
  def category(:error_max_budget_usd), do: :capacity
  def category(:error_max_input_tokens), do: :capacity
  def category(:error_max_structured_output_retries), do: :capacity
  def category(:error_consecutive_mistakes), do: :capacity
  def category(:error_during_execution), do: :retryable
  def category(:error_schema_validation), do: :retryable
  def category(:error_prompt_too_long), do: :capacity
  def category(:error_no_progress), do: :capacity
  def category(:error_thinking_starved), do: :capacity
  def category(:error_halted), do: :fatal
  def category(:error_compaction_failed), do: :fatal
  def category(:error_provider_auth), do: :fatal
end
