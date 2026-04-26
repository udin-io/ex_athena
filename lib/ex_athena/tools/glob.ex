defmodule ExAthena.Tools.Glob do
  @moduledoc """
  Finds files matching a glob pattern, relative to `ctx.cwd`.

  Arguments:

    * `pattern` (required) — `Path.wildcard/1`-compatible pattern, e.g. `lib/**/*.ex`.
    * `max_results` (optional, default 200) — cap on the number of paths returned.

  Result is a newline-separated list of paths relative to `ctx.cwd`.
  """

  @behaviour ExAthena.Tool

  @default_max 200
  @hard_cap 5_000

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
        max_results: %{type: "integer", description: "cap on results (default 200)"}
      },
      required: ["pattern"]
    }
  end

  @impl true
  def parallel_safe?, do: true

  @impl true
  def execute(%{"pattern" => pattern} = args, %{cwd: cwd}) when is_binary(pattern) do
    max = clamp(Map.get(args, "max_results", @default_max))

    results =
      cwd
      |> Path.join(pattern)
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, cwd))
      |> Enum.take(max)

    ui = %{
      kind: :matches,
      payload: %{
        pattern: pattern,
        count: length(results),
        items: results
      }
    }

    {:ok, format(results), ui}
  end

  def execute(_, _), do: {:error, :missing_pattern}

  defp clamp(n) when is_integer(n) and n > 0, do: min(n, @hard_cap)
  defp clamp(_), do: @default_max

  defp format([]), do: "(no matches)"
  defp format(results), do: Enum.join(results, "\n")
end
