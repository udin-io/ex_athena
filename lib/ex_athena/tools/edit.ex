defmodule ExAthena.Tools.Edit do
  @moduledoc """
  Exact-string replacement in a file.

  Mirrors the semantics of Claude Code's `Edit` tool:

    * `old_string` must appear in the file.
    * Unless `replace_all` is `true`, `old_string` must be unique.
    * If unique, exactly one occurrence is replaced by `new_string`.

  This is intentionally strict. An agent that passes ambiguous `old_string`
  should be told to add surrounding context until it's unique — never silently
  replace the first match.
  """

  @behaviour ExAthena.Tool

  alias ExAthena.ToolContext

  @impl true
  def name, do: "edit"

  @impl true
  def description,
    do:
      "Replace a unique string in a file. Set replace_all: true to replace every occurrence."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string"},
        old_string: %{type: "string"},
        new_string: %{type: "string"},
        replace_all: %{type: "boolean"}
      },
      required: ["path", "old_string", "new_string"]
    }
  end

  @impl true
  def execute(args, %ToolContext{} = ctx) do
    with {:ok, path} <- fetch_path(args, ctx),
         {:ok, old_s} <- fetch_string(args, "old_string"),
         {:ok, new_s} <- fetch_string(args, "new_string"),
         replace_all? = Map.get(args, "replace_all", false),
         {:ok, body} <- File.read(path),
         {:ok, updated} <- replace(body, old_s, new_s, replace_all?),
         :ok <- File.write(path, updated) do
      count = if replace_all?, do: occurrences(body, old_s), else: 1
      {:ok, "edited #{Path.relative_to(path, ctx.cwd)} (#{count} replacement#{if count == 1, do: "", else: "s"})"}
    end
  end

  defp fetch_path(%{"path" => path}, ctx), do: ToolContext.resolve_path(ctx, path)
  defp fetch_path(_, _), do: {:error, :missing_path}

  defp fetch_string(args, key) do
    case Map.get(args, key) do
      nil -> {:error, {:missing, key}}
      "" when key == "old_string" -> {:error, :empty_old_string}
      s when is_binary(s) -> {:ok, s}
      _ -> {:error, {:invalid, key}}
    end
  end

  defp replace(body, old_s, new_s, true) do
    if String.contains?(body, old_s) do
      {:ok, String.replace(body, old_s, new_s)}
    else
      {:error, :old_string_not_found}
    end
  end

  defp replace(body, old_s, new_s, false) do
    case occurrences(body, old_s) do
      0 -> {:error, :old_string_not_found}
      1 -> {:ok, String.replace(body, old_s, new_s, global: false)}
      n -> {:error, {:ambiguous_match, n}}
    end
  end

  defp occurrences(body, old_s), do: body |> String.split(old_s) |> length() |> Kernel.-(1)
end
