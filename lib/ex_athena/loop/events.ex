defmodule ExAthena.Loop.Events do
  @moduledoc """
  Flat, pattern-matchable event tuples the loop emits to `:on_event`.

  Event shape inspired by `ash_ai`'s `ToolLoop.stream/2` — one tuple per
  logical event, exhaustive, easy to match on in LiveView handlers, OTel
  emitters, and cost trackers. Same events feed the OpenTelemetry span
  emitter (landing in PR 4).

  Events:

    * `{:content, text}` — partial or full assistant text.
    * `{:tool_call, ToolCall.t()}` — model requested a tool call.
    * `{:tool_result, ToolResult.t()}` — tool produced a result (or error).
    * `{:iteration, n}` — a new iteration is starting.
    * `{:compaction, %{before:, after:, reason:}}` — context compacted.
    * `{:subagent_spawn, %{id:, prompt:}}` — a sub-agent started.
    * `{:subagent_result, %{id:, text:}}` — sub-agent returned.
    * `{:usage, usage_map}` — partial usage report from the provider.
    * `{:structured_retry, %{attempt:, error:}}` — extract_structured
      retry.
    * `{:error, reason}` — non-fatal warning (the loop continues).
    * `{:done, Result.t()}` — terminal event. Always the last event
      emitted; the Result carries the finish_reason.
  """

  alias ExAthena.Messages.{ToolCall, ToolResult}
  alias ExAthena.Result

  @type t ::
          {:content, String.t()}
          | {:tool_call, ToolCall.t()}
          | {:tool_result, ToolResult.t()}
          | {:iteration, non_neg_integer()}
          | {:compaction, %{required(:before) => integer(), required(:after) => integer(), required(:reason) => term()}}
          | {:subagent_spawn, %{required(:id) => term(), required(:prompt) => String.t()}}
          | {:subagent_result, %{required(:id) => term(), required(:text) => String.t()}}
          | {:usage, map()}
          | {:structured_retry, %{required(:attempt) => non_neg_integer(), required(:error) => term()}}
          | {:error, term()}
          | {:done, Result.t()}

  @doc "Emit an event via the supplied callback (nil is a no-op)."
  @spec emit((t() -> term()) | nil, t()) :: :ok
  def emit(nil, _event), do: :ok
  def emit(callback, event) when is_function(callback, 1) do
    callback.(event)
    :ok
  end
end
