defmodule ExAthena.Permissions do
  @moduledoc """
  Decides whether a tool call is allowed.

  Every tool call runs through `check/4` before execution. The check combines
  four sources — in this order, first decisive wins:

    1. **`disallowed_tools`** — an explicit blocklist. Always denies.
    2. **`allowed_tools`** — an explicit allowlist. If non-nil, denies anything
       not in it.
    3. **`phase`** — the current permission mode:
       * `:plan` — read-only. Writes and shell execution are denied.
       * `:default` — read + write. `can_use_tool` callback (if supplied) can
         ask the user.
       * `:accept_edits` — auto-allow Read/Edit/Write/Glob/Grep/WebFetch
         + `plan_mode` / `spawn_agent`; still consults `can_use_tool` for
         everything else (e.g. `bash`, custom tools).
       * `:trusted` — skip the `can_use_tool` callback for every tool.
         Still respects the disallow / allowlist by default; pass
         `respect_denylist: false` to disable that too (equivalent to
         `:bypass_permissions`).
       * `:bypass_permissions` — everything allowed without asking.
    4. **`can_use_tool`** — caller-supplied callback (only in `:default`
       and unconditionally-allowed-tool slots of `:accept_edits`).

  The `can_use_tool` callback is a function `(tool_name, arguments, ctx ->
  :allow | :deny | {:deny, reason})` that the loop calls in `:default` mode
  for anything the caller marked as sensitive. See `Permissions.Opts` below.

  Reserved name: `:auto` is reserved for the future ML safety classifier
  mode the Claude Code paper describes; do not use it.

  ## Deny-first ordering

  The check chain is **disallowed → allowed → phase → callback**, with the
  first decisive answer winning. A blocked tool stays blocked even when
  `:bypass_permissions` would otherwise allow everything:

      iex> alias ExAthena.{Permissions, ToolContext}
      iex> alias ExAthena.Messages.ToolCall
      iex> tc = %ToolCall{id: "1", name: "bash", arguments: %{}}
      iex> ctx = ToolContext.new(cwd: "/tmp", phase: :bypass_permissions)
      iex> Permissions.check(tc, ctx, %{disallowed_tools: ["bash"]})
      {:deny, {:disallowed, "bash"}}

  Likewise, an allowlist denies everything outside it even if a callback
  would have allowed:

      iex> alias ExAthena.{Permissions, ToolContext}
      iex> alias ExAthena.Messages.ToolCall
      iex> tc = %ToolCall{id: "1", name: "bash", arguments: %{}}
      iex> ctx = ToolContext.new(cwd: "/tmp", phase: :default)
      iex> opts = %{allowed_tools: ["read"], can_use_tool: fn _, _, _ -> :allow end}
      iex> Permissions.check(tc, ctx, opts)
      {:deny, {:not_in_allowlist, "bash"}}
  """

  alias ExAthena.Messages.ToolCall
  alias ExAthena.ToolContext

  @readonly_tools ~w(read glob grep web_fetch plan_mode spawn_agent)
  @mutating_tools ~w(write edit bash todo_write)
  # `:accept_edits` auto-allows file edits + every read-only tool,
  # but still falls through to the callback for everything else
  # (bash, custom tools).
  @auto_allow_in_accept_edits ~w(read glob grep web_fetch plan_mode spawn_agent write edit todo_write)

  @type result ::
          :allow
          | {:deny, reason :: term()}

  @type opts :: %{
          optional(:phase) => ToolContext.phase(),
          optional(:allowed_tools) => [String.t()] | nil,
          optional(:disallowed_tools) => [String.t()] | nil,
          optional(:can_use_tool) => (String.t(), map(), ToolContext.t() -> result()),
          optional(:respect_denylist) => boolean()
        }

  @doc """
  Check whether `tool_call` is allowed under `opts`. Returns `:allow` or
  `{:deny, reason}`.
  """
  @spec check(ToolCall.t(), ToolContext.t(), opts()) :: result()
  def check(%ToolCall{name: name, arguments: args}, %ToolContext{} = ctx, opts) do
    with :allow <- check_disallowed(name, ctx.phase, opts),
         :allow <- check_allowed(name, opts),
         :allow <- check_phase(name, ctx.phase),
         :allow <- check_callback(name, args, ctx, ctx.phase, opts) do
      :allow
    end
  end

  # Deny-first ordering is preserved. The denylist always wins, including
  # in `:bypass_permissions` mode (the "absolutely never" list is the
  # user's explicit veto). The only escape hatch is `:trusted` with
  # `respect_denylist: false` — opt-in for very-trusted automation
  # contexts where the host is sure no per-tool denials should apply.
  defp check_disallowed(name, :trusted, opts) do
    if opts[:respect_denylist] == false do
      :allow
    else
      check_disallowed_list(name, opts)
    end
  end

  defp check_disallowed(name, _phase, opts), do: check_disallowed_list(name, opts)

  defp check_disallowed_list(name, opts) do
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
  defp check_phase(_name, :trusted), do: :allow
  defp check_phase(_name, :accept_edits), do: :allow
  defp check_phase(_name, _), do: :allow

  # `:trusted`, `:bypass_permissions`, and the auto-allow set of
  # `:accept_edits` skip the callback. Everything else (default mode +
  # the non-auto-allow tools in accept_edits) consults it.
  defp check_callback(_name, _args, _ctx, :bypass_permissions, _opts), do: :allow
  defp check_callback(_name, _args, _ctx, :trusted, _opts), do: :allow

  defp check_callback(name, args, ctx, :accept_edits, opts) do
    if name in @auto_allow_in_accept_edits do
      :allow
    else
      do_callback(name, args, ctx, opts)
    end
  end

  defp check_callback(name, args, ctx, _phase, opts), do: do_callback(name, args, ctx, opts)

  defp do_callback(name, args, ctx, opts) do
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
