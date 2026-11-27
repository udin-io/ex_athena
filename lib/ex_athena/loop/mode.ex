defmodule ExAthena.Loop.Mode do
  @moduledoc """
  Pluggable control-flow strategy for the agent loop.

  Modes decide *what to do each turn*. The kernel handles everything else —
  tool dispatch, permissions, hooks, events, accounting. The one builtin,
  `ExAthena.Modes.ReAct`, is the chat: "infer → tool → loop", with the model
  choosing when to plan, keep a to-do list or send a helper. How much it may
  do without asking is the run's `:phase`, not its mode (issue 322).

  ## Writing a mode

      defmodule MyMode do
        @behaviour ExAthena.Loop.Mode

        @impl true
        def init(state), do: {:ok, state}

        @impl true
        def iterate(state) do
          # Run inference, handle tool calls, update state, decide continue/halt.
          # Return {:continue, state} to keep looping, {:halt, state} to stop.
          {:continue, state}
        end
      end

  The builtin `ExAthena.Modes.ReAct` is a reference implementation.

  ## Atom shortcuts

  `:react` resolves to `ExAthena.Modes.ReAct`. `:plan_and_solve`,
  `:reflexion` and `:orchestrate` were removed in issue 322 and resolve to an
  error that names what replaces each one. Any other atom or a module
  reference is used verbatim.
  """

  alias ExAthena.Loop.State

  @doc "Called once before the first iteration. Use to prime mode-specific state."
  @callback init(State.t()) :: {:ok, State.t()} | {:error, term()}

  @doc """
  Drive one iteration. Return one of:

    * `{:continue, State.t()}` — keep looping (kernel checks caps + budget).
    * `{:halt, State.t()}` — stop looping; the kernel produces a `Result`
      from the terminal state's `finish_reason` (which the mode should set
      via `ExAthena.Loop.set_finish_reason/2` before returning).
    * `{:error, reason}` — abort with an unrecoverable error. The kernel
      wraps this in `:error_during_execution`, except for the typed
      capacity signals it can recover from: `{:error, :error_prompt_too_long}`
      (force-compact the context, retry the iteration once) and
      `{:error, {:error_thinking_starved, info, state}}` (retry the
      iteration once with an escalated `max_tokens`; the usage-folded state
      rides on the tuple so the starved attempt's token burn stays on the
      run's budget).
  """
  @callback iterate(State.t()) :: {:continue, State.t()} | {:halt, State.t()} | {:error, term()}

  @doc """
  Optional. Called after each `{:continue, new_state}` to determine whether
  the iteration was productive. Return `true` if the run made progress (new
  tool name+args pair OR new assistant text), `false` otherwise. When not
  implemented, the kernel uses its own default check.
  """
  @callback productivity_signal(prev_state :: State.t(), new_state :: State.t()) :: boolean()

  @optional_callbacks [productivity_signal: 2]

  @removed %{
    plan_and_solve:
      "the :plan_and_solve mode was removed; start the run with phase: :plan " <>
        "and the chat shows a plan for approval before it changes anything",
    reflexion:
      "the :reflexion mode was removed; the chat's finish checks stop a run " <>
        "from claiming done without proof (ExAthena.Loop.FinishChecks)",
    orchestrate:
      "the :orchestrate mode was removed; every chat can send helpers with " <>
        "spawn_agent, under the same limits"
  }

  @doc """
  Resolve an atom shortcut or module to the Mode module.

  Returns `{:error, {:removed_mode, mode, hint}}` for a mode issue 322
  removed, `hint` saying what replaces it.
  """
  @spec resolve(atom() | module()) :: module() | {:error, {:removed_mode, atom(), String.t()}}
  def resolve(:react), do: ExAthena.Modes.ReAct

  def resolve(mode) when is_map_key(@removed, mode),
    do: {:error, {:removed_mode, mode, Map.fetch!(@removed, mode)}}

  def resolve(mode) when is_atom(mode), do: mode
end
