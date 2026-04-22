defmodule ExAthena.Hooks do
  @moduledoc """
  Lifecycle hooks the loop fires at key transitions.

  Shape mirrors Claude Code's SDK so existing hook code ports cleanly:

      hooks = %{
        PreToolUse: [%{matcher: "Write|Edit", hooks: [&deny_protected_paths/2]}],
        PostToolUse: [%{matcher: "Bash", hooks: [&capture_test_output/2]}],
        Stop: [&log_stop/2]
      }

  Each hook callback receives `(input_map, tool_use_id)` and returns either:

    * `:ok` / `{:allow, []}` — continue
    * `{:deny, permission_decision_reason: reason}` — deny the tool call
    * `{:halt, reason}` — stop the loop

  Hooks are matched by `:matcher` (regex run against `tool_name`); a `nil`
  matcher or a missing `:matcher` key fires for every tool. Lifecycle-only
  hooks (`Stop`, `SessionStart`, `SessionEnd`, `Notification`, `PreCompact`)
  are passed as plain function lists, not wrapped in matcher maps.
  """

  @type matcher :: String.t() | Regex.t() | nil
  @type hook_fun :: (map(), String.t() -> term())
  @type matcher_group :: %{matcher: matcher(), hooks: [hook_fun()]}

  @type t :: %{
          optional(:PreToolUse) => [matcher_group()],
          optional(:PostToolUse) => [matcher_group()],
          optional(:PostToolUseFailure) => [matcher_group()],
          optional(:Stop) => [hook_fun()],
          optional(:Notification) => [hook_fun()],
          optional(:PreCompact) => [hook_fun()],
          optional(:SessionStart) => [hook_fun()],
          optional(:SessionEnd) => [hook_fun()]
        }

  @doc "Fire `PreToolUse` hooks matching `tool_name`."
  @spec run_pre_tool_use(t(), String.t(), map(), String.t() | nil) ::
          :ok | {:deny, term()} | {:halt, term()}
  def run_pre_tool_use(hooks, tool_name, input, tool_use_id) do
    run_tool_phase(hooks[:PreToolUse] || [], tool_name, input, tool_use_id)
  end

  @doc "Fire `PostToolUse` hooks matching `tool_name`."
  @spec run_post_tool_use(t(), String.t(), map(), String.t() | nil) :: :ok | {:halt, term()}
  def run_post_tool_use(hooks, tool_name, result, tool_use_id) do
    groups = hooks[:PostToolUse] || []
    # PostToolUse denies are ignored (too late) — only :halt is honoured.
    case run_tool_phase(groups, tool_name, result, tool_use_id) do
      {:halt, _} = halt -> halt
      _ -> :ok
    end
  end

  @doc "Fire lifecycle hooks that aren't scoped to a tool (Stop, SessionStart, etc.)."
  @spec run_lifecycle(t(), atom(), map()) :: :ok | {:halt, term()}
  def run_lifecycle(hooks, event, payload) do
    fns = hooks[event] || []

    Enum.reduce_while(fns, :ok, fn fun, _acc ->
      case safe_call(fun, payload, nil) do
        {:halt, _} = h -> {:halt, h}
        _ -> {:cont, :ok}
      end
    end)
  end

  defp run_tool_phase(groups, tool_name, input, tool_use_id) do
    groups
    |> Enum.flat_map(fn
      %{hooks: fns} = group when is_list(fns) ->
        matcher = Map.get(group, :matcher)
        if matches?(matcher, tool_name), do: fns, else: []

      fun when is_function(fun, 2) ->
        [fun]
    end)
    |> Enum.reduce_while(:ok, fn fun, _acc ->
      case safe_call(fun, Map.put_new(input, :tool_name, tool_name), tool_use_id) do
        {:deny, _} = deny -> {:halt, deny}
        {:halt, _} = halt -> {:halt, halt}
        _ -> {:cont, :ok}
      end
    end)
  end

  defp matches?(nil, _name), do: true

  defp matches?(pattern, name) when is_binary(pattern),
    do: Regex.match?(Regex.compile!(pattern), name)

  defp matches?(%Regex{} = rx, name), do: Regex.match?(rx, name)

  defp safe_call(fun, input, tool_use_id) do
    try do
      fun.(input, tool_use_id)
    rescue
      e ->
        {:halt, {:hook_crashed, Exception.message(e)}}
    end
  end
end
