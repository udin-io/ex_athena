defmodule ExAthena.Tuning do
  @moduledoc """
  Runtime lookup for the tunable limits that govern orchestration, workers,
  and the web run record.

  These started as module attributes chosen against one local model. Every
  time a different model was tried — a smaller context, a chattier planner,
  a slower delegator — the numbers had to be edited in source and the app
  recompiled. They are now config keys whose defaults are the original
  attributes, so nothing changes for a host that configures nothing.

  Each namespace maps to one application-config entry:

      config :ex_athena, :orchestrate,
        max_planning_turns: 12,
        max_turns_without_spawn: 3

      config :ex_athena, :agents, result_chars: 32_000
      config :ex_athena, :web, agent_prompt_chars: 4_000
      config :ex_athena, :bash, max_output_chars: 24_000

  A namespace accepts a keyword list (what `config.exs` produces) or a map
  (what runtime-assembled config produces).

  ## Why not `Compactor.Config`

  That module resolves with `||`, so a configured `0` or `false` falls
  through to the default. Its keys are sizes and prompts where that is
  harmless. These keys are counts and caps where `0` is a meaningful
  setting — `max_turns_without_spawn: 0` means "delegate immediately" — so
  resolution here is presence-based via `Keyword.get/3` and `Map.get/3`.
  """

  @doc """
  Resolve `key` from the `namespace` config entry, falling back to `default`.

  Returns `default` when the namespace is unset, holds no such key, or is
  neither a keyword list nor a map — a malformed config degrades to the
  built-in behaviour instead of crashing a run.
  """
  @spec get(atom(), atom(), term()) :: term()
  def get(namespace, key, default) when is_atom(namespace) and is_atom(key) do
    case Application.get_env(:ex_athena, namespace) do
      kw when is_list(kw) ->
        if Keyword.keyword?(kw), do: Keyword.get(kw, key, default), else: default

      m when is_map(m) ->
        Map.get(m, key, default)

      _ ->
        default
    end
  end
end
