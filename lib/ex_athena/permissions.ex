defmodule ExAthena.Permissions do
  @moduledoc """
  Decides whether a tool call is allowed.

  Every tool call runs through `check/4` before execution. The check combines
  three sources — in this order, first decisive wins:

    1. **`disallowed_tools`** — an explicit blocklist. Always denies.
    2. **`allowed_tools`** — an explicit allowlist. If non-nil, denies anything
       not in it.
    3. **`phase`** — the current permission mode:
       * `:plan` — read-only. Writes and shell execution are denied.
       * `:default` — read + write. `can_use_tool` callback (if supplied) can
         ask the user.
       * `:bypass_permissions` — everything allowed without asking.

  The `can_use_tool` callback is a function `(tool_name, arguments, ctx ->
  :allow | :deny | {:deny, reason})` that the loop calls in `:default` mode
  for anything the caller marked as sensitive. See `Permissions.Opts` below.
  """

  alias ExAthena.Messages.ToolCall
  alias ExAthena.ToolContext

  @readonly_tools ~w(read glob grep web_fetch plan_mode spawn_agent)
  @mutating_tools ~w(write edit bash todo_write)

  @type result ::
          :allow
          | {:deny, reason :: term()}

  @type opts :: %{
          optional(:phase) => ToolContext.phase(),
          optional(:allowed_tools) => [String.t()] | nil,
          optional(:disallowed_tools) => [String.t()] | nil,
          optional(:can_use_tool) => (String.t(), map(), ToolContext.t() -> result())
        }

  @doc """
  Check whether `tool_call` is allowed under `opts`. Returns `:allow` or
  `{:deny, reason}`.
  """
  @spec check(ToolCall.t(), ToolContext.t(), opts()) :: result()
  def check(%ToolCall{name: name, arguments: args}, %ToolContext{} = ctx, opts) do
    with :allow <- check_disallowed(name, opts),
         :allow <- check_allowed(name, opts),
         :allow <- check_phase(name, ctx.phase),
         :allow <- check_callback(name, args, ctx, opts) do
      :allow
    end
  end

  defp check_disallowed(name, opts) do
    case opts[:disallowed_tools] do
      nil -> :allow
      list when is_list(list) -> if name in list, do: {:deny, {:disallowed, name}}, else: :allow
    end
  end

  defp check_allowed(name, opts) do
    case opts[:allowed_tools] do
      nil ->
        :allow

      list when is_list(list) ->
        if name in list, do: :allow, else: {:deny, {:not_in_allowlist, name}}
    end
  end

  defp check_phase(name, :plan) do
    cond do
      name in @readonly_tools -> :allow
      name in @mutating_tools -> {:deny, {:mutation_in_plan_mode, name}}
      true -> :allow
    end
  end

  defp check_phase(_name, :bypass_permissions), do: :allow
  defp check_phase(_name, _), do: :allow

  defp check_callback(name, args, ctx, opts) do
    case opts[:can_use_tool] do
      nil -> :allow
      fun when is_function(fun, 3) -> normalize(fun.(name, args, ctx))
    end
  end

  defp normalize(:allow), do: :allow
  defp normalize({:allow, _}), do: :allow
  defp normalize(:deny), do: {:deny, :denied_by_callback}
  defp normalize({:deny, _} = result), do: result
  defp normalize(other), do: {:deny, {:unexpected_callback_result, other}}

  @doc "Static list of read-only tool names the `:plan` phase permits."
  @spec readonly_tools() :: [String.t()]
  def readonly_tools, do: @readonly_tools
end
