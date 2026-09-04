defmodule ExAthena.Tools.Glob do
  @moduledoc """
  Finds files matching a glob pattern, relative to `ctx.cwd`.

  Arguments:

    * `pattern` (required) — `Path.wildcard/1`-compatible pattern, e.g. `lib/**/*.ex`.
    * `max_results` (optional, default 200) — cap on the number of paths returned.
    * `include_artifacts` (optional, default false) — when true, returns paths under
      `_build/`, `deps/`, `node_modules/`, `.git/`, `priv/static/`, and `tmp/` too.

  Result is a newline-separated list of paths relative to `ctx.cwd`.
  """

  @behaviour ExAthena.Tool

  alias ExAthena.Tuning

  @default_max 200
  @hard_cap 5_000

  @artifact_dirs ExAthena.Permissions.artifact_dirs()

  @impl true
  def name, do: "glob"

  @impl true
  def description,
    do: "Find files matching a glob pattern (e.g. `lib/**/*.ex`) under the working directory."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        pattern: %{type: "string", description: "Path.wildcard pattern"},
        max_results: %{type: "integer", description: "cap on results (default 200)"},
        include_artifacts: %{
          type: "boolean",
          description:
            "Include `_build/`, `deps/`, `node_modules/`, `.git/`, `priv/static/`, `tmp/` paths (default false)"
        }
      },
      required: ["pattern"]
    }
  end

  @impl true
  def parallel_safe?, do: true

  @impl true
  def read_only?, do: true

  @impl true
  def execute(%{"pattern" => pattern} = args, ctx) when is_binary(pattern) do
    cwd = ctx.cwd
    max = clamp(Map.get(args, "max_results", Tuning.get(:tools, :glob_default_max, @default_max)))
    include_artifacts = Map.get(args, "include_artifacts", false) == true

    # `**` can reach the same file by more than one route when a segment name
    # repeats at two depths (`**/ortex/**/*.ex` over deps/ortex/lib/ortex/) —
    # the duplicate reached the model and the count.
    found =
      cwd
      |> Path.join(pattern)
      |> Path.wildcard()
      |> Enum.uniq()
      |> confine(ctx.allowed_roots)
      |> Enum.map(&Path.relative_to(&1, cwd))

    allowed = filter_artifacts(found, include_artifacts)
    kept = Enum.take(allowed, max)
    excluded = length(found) - length(allowed)

    ui = %{
      kind: :matches,
      payload: %{
        pattern: pattern,
        count: length(kept),
        items: kept
      }
    }

    {:ok, format(kept, excluded), ui}
  end

  def execute(_, _), do: {:error, :missing_pattern}

  defp clamp(n) when is_integer(n) and n > 0,
    do: min(n, Tuning.get(:tools, :glob_hard_cap, @hard_cap))

  defp clamp(_), do: Tuning.get(:tools, :glob_default_max, @default_max)

  # When confined, drop matches that a `..` pattern resolved outside the roots.
  defp confine(paths, nil), do: paths

  defp confine(paths, roots) when is_list(roots),
    do: Enum.filter(paths, &ExAthena.ToolContext.within_roots?(&1, roots))

  defp filter_artifacts(paths, true), do: paths

  defp filter_artifacts(paths, false) do
    Enum.reject(paths, &artifact_path?/1)
  end

  defp artifact_path?(path) do
    Enum.any?(@artifact_dirs, fn dir ->
      # Matches at root (`_build/...`) and nested (`web/_build/...`) — the
      # leading-slash check is what catches Phoenix-in-subdir layouts.
      String.starts_with?(path, dir) or String.contains?(path, "/" <> dir)
    end)
  end

  # A path that was SKIPPED must never look like one that is not there. A
  # worker globbed `deps/ortex/**`, got a bare "(no matches)", and concluded
  # its own tool was broken with `**` patterns — the filter was the answer.
  # The worker contract tells workers to treat a repeated "no matches" as
  # settled absence, which makes a silent filter actively misleading.
  defp format([], 0), do: "(no matches)"

  defp format([], excluded) do
    "(no matches — #{excluded} path(s) excluded as build artifacts; " <>
      "pass include_artifacts: true to search them)"
  end

  defp format(results, _excluded), do: Enum.join(results, "\n")
end
