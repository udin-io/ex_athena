defmodule ExAthena.Compactor.Config do
  @moduledoc """
  Single resolution path for compaction settings.

  Every compaction stage resolves its knobs through the same cascade:

    1. `state.meta[key]` — per-run override, set by the host via loop
       options.
    2. `Application.get_env(:ex_athena, :compactor)` — global config,
       accepted as a keyword list or a map.
    3. The caller-supplied default.

  Extracted here because the cascade was copy-pasted across five stage
  modules and had already started to drift (issue #148).
  """

  alias ExAthena.Loop.State

  @doc """
  Resolve `key` through the meta → app env → default cascade.

  Matches the `||` semantics every stage used before extraction: a
  falsy meta value falls through to the app env, then the default.
  """
  @spec get(State.t(), atom(), term()) :: term()
  def get(%State{meta: meta}, key, default) do
    Map.get(meta, key) || app_env(key, default)
  end

  @doc """
  Resolve `key` from the `:compactor` app env alone (no per-run meta
  override). For settings that are deliberately global, like the summary
  system prompt.
  """
  @spec app_env(atom(), term()) :: term()
  def app_env(key, default) do
    case Application.get_env(:ex_athena, :compactor) do
      kw when is_list(kw) -> Keyword.get(kw, key, default)
      m when is_map(m) -> Map.get(m, key, default)
      _ -> default
    end
  end
end
