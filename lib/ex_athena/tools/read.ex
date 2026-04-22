defmodule ExAthena.Tools.Read do
  @moduledoc """
  Reads a file from the filesystem.

  Arguments:

    * `path` (required) — absolute path or a path relative to `ctx.cwd`.
    * `offset` (optional) — line number to start reading from (1-indexed).
    * `limit` (optional) — maximum number of lines to return.

  Result is the file contents with lines prefixed by `<lineno>\\t` so the model
  can reference specific lines the way Claude Code does.
  """

  @behaviour ExAthena.Tool

  alias ExAthena.ToolContext

  @max_bytes 2_000_000

  @impl true
  def name, do: "read"

  @impl true
  def description,
    do: "Read a file from the filesystem, optionally starting at a line offset with a line limit."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "absolute or cwd-relative path"},
        offset: %{type: "integer", description: "1-indexed line to start from"},
        limit: %{type: "integer", description: "max lines to return"}
      },
      required: ["path"]
    }
  end

  @impl true
  def parallel_safe?, do: true

  @impl true
  def execute(args, %ToolContext{} = ctx) do
    with {:ok, path} <- fetch_path(args, ctx),
         {:ok, stat} <- File.stat(path),
         :ok <- check_size(stat),
         :ok <- check_regular(stat),
         {:ok, body} <- File.read(path) do
      {:ok, format(body, args)}
    end
  end

  defp fetch_path(%{"path" => path}, ctx), do: ToolContext.resolve_path(ctx, path)
  defp fetch_path(_, _), do: {:error, :missing_path}

  defp check_size(%File.Stat{size: size}) when size > @max_bytes,
    do: {:error, {:file_too_large, size}}

  defp check_size(_), do: :ok

  defp check_regular(%File.Stat{type: :regular}), do: :ok
  defp check_regular(%File.Stat{type: type}), do: {:error, {:not_a_regular_file, type}}

  defp format(body, args) do
    body
    |> String.split("\n")
    |> slice(args)
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {line, idx} -> "#{idx}\t#{line}" end)
  end

  defp slice(lines, args) do
    offset = Map.get(args, "offset")
    limit = Map.get(args, "limit")

    lines =
      case offset do
        nil -> lines
        0 -> lines
        o when is_integer(o) and o > 0 -> Enum.drop(lines, o - 1)
        _ -> lines
      end

    case limit do
      nil -> lines
      l when is_integer(l) and l > 0 -> Enum.take(lines, l)
      _ -> lines
    end
  end
end
