defmodule ExAthena.Tools.Grep do
  @moduledoc """
  Search file contents with a regex under `ctx.cwd`.

  Shells out to `rg` (ripgrep) when available for speed + sanity; falls back
  to a pure-Elixir scan using `Path.wildcard` + `File.read` when not.

  Arguments:

    * `pattern` (required) — regex.
    * `path_glob` (optional) — restrict the scan to files matching this glob.
    * `max_results` (optional, default 200) — cap on matching lines returned.
  """

  @behaviour ExAthena.Tool

  @default_max 200
  @hard_cap 2_000

  @impl true
  def name, do: "grep"

  @impl true
  def description,
    do: "Search file contents with a regex under the working directory. Optionally narrow by glob."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        pattern: %{type: "string"},
        path_glob: %{type: "string"},
        max_results: %{type: "integer"}
      },
      required: ["pattern"]
    }
  end

  @impl true
  def execute(%{"pattern" => pattern} = args, %{cwd: cwd}) when is_binary(pattern) do
    max = clamp(Map.get(args, "max_results", @default_max))
    glob = Map.get(args, "path_glob")

    case System.find_executable("rg") do
      nil -> elixir_grep(pattern, glob, cwd, max)
      rg -> rg_grep(rg, pattern, glob, cwd, max)
    end
  end

  def execute(_, _), do: {:error, :missing_pattern}

  defp clamp(n) when is_integer(n) and n > 0, do: min(n, @hard_cap)
  defp clamp(_), do: @default_max

  defp rg_grep(rg, pattern, glob, cwd, max) do
    # Pass `.` explicitly — rg hangs on stdin when it can't detect a path arg
    # and runs under Port.
    args =
      ["--no-heading", "--line-number", "--max-count", to_string(max), pattern, "."]
      |> maybe_prepend_glob(glob)

    case System.cmd(rg, args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, take_lines(output, max)}
      # ripgrep exit 1 = no matches
      {"", 1} -> {:ok, "(no matches)"}
      {output, 1} -> {:ok, take_lines(output, max)}
      {output, code} -> {:error, {:rg_failed, code, output}}
    end
  end

  defp maybe_prepend_glob(args, nil), do: args
  defp maybe_prepend_glob(args, glob), do: ["--glob", glob | args]

  defp elixir_grep(pattern, glob, cwd, max) do
    with {:ok, regex} <- Regex.compile(pattern) do
      files =
        cwd
        |> Path.join(glob || "**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)

      matches =
        files
        |> Stream.flat_map(fn path ->
          case File.read(path) do
            {:ok, body} -> scan_file(path, body, regex, cwd)
            _ -> []
          end
        end)
        |> Enum.take(max)

      {:ok, if(matches == [], do: "(no matches)", else: Enum.join(matches, "\n"))}
    else
      {:error, {msg, _offset}} -> {:error, {:invalid_regex, to_string(msg)}}
    end
  end

  defp scan_file(path, body, regex, cwd) do
    rel = Path.relative_to(path, cwd)

    body
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, idx} ->
      if Regex.match?(regex, line), do: ["#{rel}:#{idx}:#{line}"], else: []
    end)
  end

  defp take_lines(output, max) do
    output
    |> String.split("\n", trim: true)
    |> Enum.take(max)
    |> Enum.join("\n")
  end
end
