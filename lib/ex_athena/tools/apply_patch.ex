defmodule ExAthena.Tools.ApplyPatch do
  @moduledoc """
  Apply a unified diff patch across one or more files atomically.

  All hunks across all files are validated in memory first (pure-Elixir backend)
  before any file is written to disk — partial mutations on error are impossible.

  Backend selection:
  - Inside a git work-tree: delegates to `git apply --whitespace=nowarn`, which
    is itself atomic on failure.
  - Otherwise: pure-Elixir two-pass parser/applier.

  v1 limitations: no binary diffs, no `/dev/null` create/delete hunks, no fuzzy
  context matching.
  """

  @behaviour ExAthena.Tool

  require Logger

  alias ExAthena.ToolContext

  @impl true
  def name, do: "apply_patch"

  @impl true
  def description,
    do:
      "Apply a unified diff patch across one or more files atomically. " <>
        "All hunks either succeed or none are written to disk."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        patch: %{
          type: "string",
          description: "Unified diff in git-apply format."
        },
        dry_run: %{
          type: "boolean",
          description: "Validate the patch without writing to disk. Default false."
        }
      },
      required: ["patch"]
    }
  end

  @impl true
  def execute(args, %ToolContext{} = ctx) do
    with {:ok, patch} <- fetch_patch(args),
         dry_run? = Map.get(args, "dry_run", false),
         {:ok, file_sections} <- parse_diff(patch),
         {:ok, resolved} <- resolve_paths(file_sections, ctx),
         :ok <- maybe_snapshot_all(ctx, resolved),
         {:ok, results} <- dispatch(patch, resolved, dry_run?, ctx) do
      llm =
        Enum.map_join(results, "\n", fn %{path: p, hunks_applied: h} ->
          rel = Path.relative_to(p, ctx.cwd)
          "applied #{h} hunk#{if h == 1, do: "", else: "s"} to #{rel}"
        end)

      ui = %{kind: :patch, payload: %{files: results}}
      {:ok, llm, ui}
    end
  end

  # ---------------------------------------------------------------------------
  # Fetch
  # ---------------------------------------------------------------------------

  defp fetch_patch(%{"patch" => patch}) when is_binary(patch) and patch != "",
    do: {:ok, patch}

  defp fetch_patch(%{"patch" => ""}), do: {:error, :empty_patch}
  defp fetch_patch(%{"patch" => _}), do: {:error, :invalid_patch}
  defp fetch_patch(_), do: {:error, :missing_patch}

  # ---------------------------------------------------------------------------
  # Diff parser
  # ---------------------------------------------------------------------------

  @doc false
  def parse_diff(patch) do
    lines = String.split(patch, "\n")
    sections = group_into_file_sections(lines)

    if sections == [] do
      {:error, :no_file_sections_found}
    else
      Enum.reduce_while(sections, {:ok, []}, fn section, {:ok, acc} ->
        case parse_file_section(section) do
          {:ok, fs} -> {:cont, {:ok, [fs | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, list} -> {:ok, Enum.reverse(list)}
        err -> err
      end
    end
  end

  # Split a flat line list into per-file chunks. Each file's diff starts with
  # "--- "; anything before the first such line (git preamble) is discarded.
  defp group_into_file_sections(lines) do
    lines
    |> Enum.chunk_while(
      [],
      fn line, acc ->
        if String.starts_with?(line, "--- ") and acc != [] do
          {:cont, Enum.reverse(acc), [line]}
        else
          {:cont, [line | acc]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.filter(fn section ->
      Enum.any?(section, &String.starts_with?(&1, "--- "))
    end)
  end

  defp parse_file_section(lines) do
    with {:ok, raw_path} <- extract_target_path(lines),
         {:ok, hunks} <- parse_hunks(lines) do
      {:ok, %{raw_path: raw_path, hunks: hunks, hunk_count: length(hunks)}}
    end
  end

  defp extract_target_path(lines) do
    plus_line = Enum.find(lines, &String.starts_with?(&1, "+++ "))
    minus_line = Enum.find(lines, &String.starts_with?(&1, "--- "))

    cond do
      is_nil(plus_line) ->
        {:error, :no_target_path}

      String.starts_with?(plus_line, "+++ /dev/null") ->
        {:error, {:unsupported_diff_feature, :file_deletion}}

      not is_nil(minus_line) and String.starts_with?(minus_line, "--- /dev/null") ->
        {:error, {:unsupported_diff_feature, :file_creation}}

      String.starts_with?(plus_line, "+++ b/") ->
        {:ok, plus_line |> String.slice(6, String.length(plus_line)) |> tab_strip()}

      true ->
        {:ok, plus_line |> String.slice(4, String.length(plus_line)) |> tab_strip()}
    end
  end

  # Strip optional tab-separated timestamp that some diff tools append.
  defp tab_strip(s), do: s |> String.split("\t") |> hd() |> String.trim()

  defp parse_hunks(lines) do
    indexed = Enum.with_index(lines)

    hunk_starts =
      Enum.filter(indexed, fn {line, _} -> String.starts_with?(line, "@@ ") end)

    if hunk_starts == [] do
      {:error, :no_hunks_found}
    else
      total = length(lines)

      hunks =
        hunk_starts
        |> Enum.with_index()
        |> Enum.map(fn {{header, start_idx}, hunk_idx} ->
          next_start =
            case Enum.at(hunk_starts, hunk_idx + 1) do
              nil -> total
              {_, idx} -> idx
            end

          body = Enum.slice(lines, (start_idx + 1)..(next_start - 1))
          parse_hunk_header(header, body)
        end)

      errors = Enum.filter(hunks, &match?({:error, _}, &1))

      if errors == [] do
        {:ok, Enum.map(hunks, fn {:ok, h} -> h end)}
      else
        hd(errors)
      end
    end
  end

  @hunk_re ~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

  defp parse_hunk_header(header, body_lines) do
    case Regex.run(@hunk_re, header) do
      [_, old_start_s, old_count_s, new_start_s, new_count_s] ->
        {:ok,
         %{
           old_start: String.to_integer(old_start_s),
           old_count: parse_count(old_count_s),
           new_start: String.to_integer(new_start_s),
           new_count: parse_count(new_count_s),
           lines: body_lines
         }}

      _ ->
        {:error, {:invalid_hunk_header, header}}
    end
  end

  defp parse_count(nil), do: 1
  defp parse_count(""), do: 1
  defp parse_count(s), do: String.to_integer(s)

  # ---------------------------------------------------------------------------
  # Path resolution
  # ---------------------------------------------------------------------------

  defp resolve_paths(file_sections, ctx) do
    Enum.reduce_while(file_sections, {:ok, []}, fn section, {:ok, acc} ->
      case ToolContext.resolve_path(ctx, section.raw_path) do
        {:ok, abs_path} -> {:cont, {:ok, [Map.put(section, :path, abs_path) | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Snapshot
  # ---------------------------------------------------------------------------

  defp maybe_snapshot_all(ctx, file_sections) do
    Enum.each(file_sections, fn section -> maybe_snapshot(ctx, section.path) end)
    :ok
  end

  defp maybe_snapshot(%ToolContext{session_id: sid, cwd: cwd}, path)
       when is_binary(sid) and sid != "" do
    _ = ExAthena.Checkpoint.snapshot(cwd, sid, path)
    :ok
  rescue
    e ->
      Logger.error("[ApplyPatch] checkpoint snapshot failed for #{path}: #{Exception.message(e)}")
      :ok
  end

  defp maybe_snapshot(_, _), do: :ok

  # ---------------------------------------------------------------------------
  # Backend dispatch
  # ---------------------------------------------------------------------------

  defp dispatch(patch, file_sections, dry_run?, ctx) do
    if git_repo?(ctx.cwd) do
      apply_with_git(patch, file_sections, dry_run?, ctx.cwd)
    else
      apply_with_elixir(file_sections, dry_run?)
    end
  end

  @git_timeout 30_000

  defp git_repo?(cwd) do
    task =
      Task.async(fn ->
        System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
          cd: cwd,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, @git_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {"true\n", 0}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # ---------------------------------------------------------------------------
  # Git backend
  # ---------------------------------------------------------------------------

  defp apply_with_git(patch, file_sections, dry_run?, cwd) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "apply_patch_#{System.unique_integer([:positive])}.patch"
      )

    try do
      File.write!(tmp, patch)

      args =
        if dry_run? do
          ["apply", "--check", "--whitespace=nowarn", tmp]
        else
          ["apply", "--whitespace=nowarn", tmp]
        end

      task = Task.async(fn -> System.cmd("git", args, cd: cwd, stderr_to_stdout: true) end)

      case Task.yield(task, @git_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {_, 0}} ->
          results =
            Enum.map(file_sections, fn s ->
              %{path: s.path, hunks_applied: s.hunk_count, hunks_skipped: 0}
            end)

          {:ok, results}

        {:ok, {stderr, _}} ->
          {:error, {:git_apply_failed, String.trim(stderr)}}

        nil ->
          {:error, :git_timeout}
      end
    after
      File.rm(tmp)
    end
  end

  # ---------------------------------------------------------------------------
  # Pure-Elixir backend (two-pass: validate all in memory, then write all)
  # ---------------------------------------------------------------------------

  defp apply_with_elixir(file_sections, dry_run?) do
    computed =
      Enum.reduce_while(file_sections, {:ok, []}, fn section, {:ok, acc} ->
        case compute_new_content(section) do
          {:ok, new_content} -> {:cont, {:ok, [{section, new_content} | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case computed do
      {:error, _} = err ->
        err

      {:ok, pairs} ->
        pairs = Enum.reverse(pairs)

        unless dry_run? do
          Enum.each(pairs, fn {section, new_content} ->
            File.mkdir_p!(Path.dirname(section.path))
            File.write!(section.path, new_content)
          end)
        end

        results =
          Enum.map(pairs, fn {section, _} ->
            %{path: section.path, hunks_applied: section.hunk_count, hunks_skipped: 0}
          end)

        {:ok, results}
    end
  end

  defp compute_new_content(%{path: path, hunks: hunks}) do
    raw =
      case File.read(path) do
        {:ok, content} -> content
        {:error, :enoent} -> ""
      end

    file_lines = String.split(raw, "\n", trim: false)

    # Apply in reverse order so earlier hunks' line numbers remain valid
    Enum.reduce_while(Enum.reverse(hunks), {:ok, file_lines}, fn hunk, {:ok, lines} ->
      case apply_hunk(hunk, lines) do
        {:ok, new_lines} -> {:cont, {:ok, new_lines}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, final_lines} -> {:ok, Enum.join(final_lines, "\n")}
      err -> err
    end
  end

  defp apply_hunk(%{old_start: old_start, old_count: old_count, lines: hunk_lines}, file_lines) do
    expected =
      hunk_lines
      |> Enum.filter(&(String.starts_with?(&1, " ") or String.starts_with?(&1, "-")))
      |> Enum.map(&String.slice(&1, 1, String.length(&1)))

    start_idx = old_start - 1
    actual = Enum.slice(file_lines, start_idx, old_count)

    if actual != expected do
      {:error, {:context_mismatch, expected: expected, actual: actual, old_start: old_start}}
    else
      replacement =
        hunk_lines
        |> Enum.filter(&(String.starts_with?(&1, " ") or String.starts_with?(&1, "+")))
        |> Enum.map(&String.slice(&1, 1, String.length(&1)))

      before = Enum.slice(file_lines, 0, start_idx)
      rest = Enum.slice(file_lines, start_idx + old_count, length(file_lines))
      {:ok, before ++ replacement ++ rest}
    end
  end
end
