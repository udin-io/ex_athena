defmodule ExAthena.Agents.Definition do
  @moduledoc """
  A single named agent loaded from a markdown+frontmatter file.

  See `ExAthena.Agents` for the file layout.
  """

  @enforce_keys [:name, :description]
  defstruct [
    :name,
    :description,
    :model,
    :provider,
    :tools,
    :system_prompt,
    :path,
    permissions: :default,
    mode: :react,
    isolation: :in_process
  ]

  @type isolation :: :in_process | :worktree

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          model: String.t() | nil,
          provider: atom() | nil,
          tools: [String.t()] | nil,
          permissions: atom(),
          mode: atom(),
          isolation: isolation(),
          system_prompt: String.t() | nil,
          path: String.t() | nil
        }

  @doc false
  def from_parsed(parsed, body, path) do
    body = String.trim(body)

    %__MODULE__{
      name: parsed["name"] || raise(ArgumentError, "agent at #{path} has no `name`"),
      description: parsed["description"] || "(no description)",
      model: parsed["model"],
      provider: maybe_atom(parsed["provider"]),
      tools: parsed["tools"],
      permissions: maybe_atom(parsed["permissions"]) || :default,
      mode: maybe_atom(parsed["mode"]) || :react,
      isolation: maybe_atom(parsed["isolation"]) || :in_process,
      system_prompt: if(body == "", do: nil, else: body),
      path: path
    }
  end

  defp maybe_atom(nil), do: nil
  defp maybe_atom(s) when is_binary(s), do: String.to_atom(s)
  defp maybe_atom(other), do: other
end
