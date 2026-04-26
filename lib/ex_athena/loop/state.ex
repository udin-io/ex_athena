defmodule ExAthena.Loop.State do
  @moduledoc """
  Internal state of a running agent loop.

  Opaque to consumers. `ExAthena.Loop.Mode` implementations receive and
  return this struct as they drive iterations. The public result of a run
  is `ExAthena.Result`, which is built from the terminal `State`.

  ## Fields

  - `messages` — running conversation history.
  - `tool_modules` — resolved tool modules for this run.
  - `capabilities` — provider capabilities map.
  - `provider_mod`, `provider_opts` — inference entry point.
  - `request_template` — base request overlaid each iteration with fresh
    messages + tool schemas.
  - `permissions_opts` — fed to `ExAthena.Permissions`.
  - `hooks` — lifecycle matcher/callback sets.
  - `ctx` — `ExAthena.ToolContext` threaded to every tool execution.
  - `on_event` — user-supplied callback for stream events.
  - `budget` — `ExAthena.Budget` accumulator.
  - `max_iterations`, `max_consecutive_mistakes`, `max_budget_usd`,
    `tool_timeout_ms`, `max_concurrency` — reliability knobs.
  - `iterations`, `tool_calls_made`, `consecutive_mistakes` — counters.
  - `mode`, `mode_state` — Mode module + its private state.
  - `halted_reason` — populated when a tool / hook returns `:halt`.
  - `session_id` — stable id for this run. Distinct from `ctx.session_id`,
    which is what tools see; this one is what the loop / hooks / storage
    use. Generated automatically when not supplied.
  - `parent_session_id` — when this run was spawned as a subagent, the
    parent's `session_id`. `nil` for top-level runs. Used by sidechain
    storage and session-resume (PR4 + PR5).
  - `meta` — free-form map for Mode-specific data that doesn't fit
    anywhere else.
  """

  alias ExAthena.{Budget, ToolContext}
  alias ExAthena.Messages.Message

  defstruct messages: [],
            tool_modules: [],
            capabilities: %{},
            provider_mod: nil,
            provider_opts: [],
            request_template: nil,
            permissions_opts: %{},
            hooks: %{},
            ctx: nil,
            on_event: nil,
            budget: nil,
            max_iterations: 25,
            max_consecutive_mistakes: 3,
            max_budget_usd: nil,
            tool_timeout_ms: 60_000,
            max_concurrency: 4,
            iterations: 0,
            tool_calls_made: 0,
            consecutive_mistakes: 0,
            mode: nil,
            mode_state: %{},
            halted_reason: nil,
            session_id: nil,
            parent_session_id: nil,
            meta: %{}

  @type t :: %__MODULE__{
          messages: [Message.t()],
          tool_modules: [module()],
          capabilities: map(),
          provider_mod: module() | nil,
          provider_opts: keyword(),
          request_template: term(),
          permissions_opts: map(),
          hooks: map(),
          ctx: ToolContext.t() | nil,
          on_event: (term() -> term()) | nil,
          budget: Budget.t() | nil,
          max_iterations: non_neg_integer(),
          max_consecutive_mistakes: non_neg_integer(),
          max_budget_usd: float() | nil,
          tool_timeout_ms: pos_integer(),
          max_concurrency: pos_integer(),
          iterations: non_neg_integer(),
          tool_calls_made: non_neg_integer(),
          consecutive_mistakes: non_neg_integer(),
          mode: module() | nil,
          mode_state: map(),
          halted_reason: term() | nil,
          session_id: String.t() | nil,
          parent_session_id: String.t() | nil,
          meta: map()
        }
end
