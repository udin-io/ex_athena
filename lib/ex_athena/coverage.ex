defmodule ExAthena.Coverage do
  @moduledoc """
  Decide whether a run's tests actually **executed** the code it changed.

  A green test suite proves a test exists, not that it covers the change: a
  test written for a private helper passes while the feature it was meant to
  cover is never executed at all.

  ## Why zero, and never a threshold

  Percentages lie for declarative code: a module whose body is compile-time
  DSL reports full coverage merely for being loaded, while a module full of
  real branches reports a low number for being partly tested. A threshold is
  therefore both unfair to the first and meaningless for the second. "Never
  executed at all" is the only claim a coverage table supports unambiguously.

  ## Scope

  The parser targets the `NN.NN% | Module.Name` table that `mix test --cover`
  prints, read out of a worker's report rather than run by the harness (tools
  execute commands; the harness only sees their output). Projects in other
  ecosystems simply produce no parseable data — reported as `:no_data`, which
  callers should treat as "ask for coverage", not "fail".
  """

  # Rows of the summary table, e.g. "     0.00% | MyApp.Some.Module".
  @row ~r/^\s*(\d+(?:\.\d+)?)\s*%\s*\|\s*([A-Za-z_][\w.]*)\s*$/m

  @doc """
  Module-name => percentage, parsed from a coverage table anywhere in `text`.

  The `Total` row is dropped: it is a summary, not a module.
  """
  @spec parse(String.t() | nil) :: %{String.t() => float()}
  def parse(text) when is_binary(text) do
    @row
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.reduce(%{}, fn [pct, mod], acc ->
      if mod == "Total", do: acc, else: Map.put(acc, mod, to_float(pct))
    end)
  end

  def parse(_), do: %{}

  @doc "Modules a source file defines, in source order."
  @spec modules_in(String.t()) :: [String.t()]
  def modules_in(path) do
    case File.read(path) do
      {:ok, source} ->
        ~r/^\s*defmodule\s+([A-Za-z_][\w.]*)\s+do/m
        |> Regex.scan(source, capture: :all_but_first)
        |> List.flatten()

      _ ->
        []
    end
  end

  @doc """
  Which of `changed_files` no test executed, given a worker's `transcript`.

  Returns `:no_data` when the transcript carries no coverage table at all —
  the caller cannot conclude anything, and should ask for one rather than
  treat silence as failure. Files defining no module (assets, config) are
  skipped: coverage has nothing to say about them.

  A module absent from the report counts as unexercised — it was never even
  loaded.
  """
  @spec unexercised([String.t()], String.t() | nil, String.t()) ::
          {:ok, [String.t()]} | :no_data
  def unexercised(changed_files, transcript, cwd) do
    case parse(transcript) do
      report when map_size(report) == 0 ->
        :no_data

      report ->
        {:ok, Enum.filter(changed_files, &unexercised?(&1, report, cwd))}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp unexercised?(file, report, cwd) do
    case modules_in(absolute(file, cwd)) do
      # Nothing to measure (assets, config, data files).
      [] -> false
      modules -> Enum.all?(modules, &(Map.get(report, &1, 0.0) == 0.0))
    end
  end

  defp absolute(file, cwd) do
    if Path.type(file) == :absolute, do: file, else: Path.join(cwd, file)
  end

  defp to_float(pct) do
    case Float.parse(pct) do
      {value, _} -> value
      :error -> 0.0
    end
  end
end
