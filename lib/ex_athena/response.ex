defmodule ExAthena.Response do
  @moduledoc """
  A normalised inference response.

  `:text` is the concatenated assistant text. `:tool_calls` holds any tool
  calls the model wants the runtime to execute (empty when the model just
  replied with text). `:usage` carries token accounting when the provider
  reports it; `:raw` keeps the provider's original payload for debugging.
  `:session_id` is the provider-side conversation identifier when the
  provider maintains its own session state (e.g. the Claude Code CLI) —
  hosts pass it back as `resume:` to continue that conversation; `nil` for
  stateless providers.

  `:starvation` is a typed capacity signal set by adapters when the turn
  was output-starved: the model burned the whole per-turn completion budget
  (typically on hidden reasoning) and produced no visible text and no tool
  calls. Carries the token counts so the loop can escalate the budget and
  callers can diagnose the failure. `nil` for every healthy turn.
  """

  alias ExAthena.Messages.ToolCall

  defstruct [
    :text,
    :thinking,
    :tool_calls,
    :finish_reason,
    :usage,
    :model,
    :provider,
    :session_id,
    :starvation,
    :raw
  ]

  @type usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer(),
          optional(:reasoning_tokens) => non_neg_integer()
        }

  @type starvation :: %{
          required(:completion_cap) => pos_integer() | nil,
          required(:output_tokens) => non_neg_integer() | nil,
          required(:reasoning_tokens) => non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          text: String.t() | nil,
          thinking: String.t() | nil,
          tool_calls: [ToolCall.t()],
          finish_reason: :stop | :length | :tool_calls | :content_filter | :error | nil,
          usage: usage() | nil,
          model: String.t() | nil,
          provider: atom() | module() | nil,
          session_id: String.t() | nil,
          starvation: starvation() | nil,
          raw: term() | nil
        }
end
