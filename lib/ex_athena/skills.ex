defmodule ExAthena.Skills do
  @moduledoc """
  Claude Code-style skills with progressive disclosure.

  A *skill* is a directory containing a `SKILL.md` markdown file with YAML
  frontmatter. The frontmatter is cheap (a sentence) and is injected into
  the system prompt as a one-line catalog entry. The body is loaded into
  context only when the model decides it needs the skill — either by
  emitting a `[skill: <name>]` sentinel in its response, or by the host
  pre-attaching it via `preload/2`.

  This means dozens of skills can be available at ~50 tokens each in
  catalog form; only the ones the model actually wants pay the full body
  cost.

  ## Layout

      ~/.config/ex_athena/skills/<name>/SKILL.md   # user-level skills
      <cwd>/.exathena/skills/<name>/SKILL.md       # project-level skills

  Project skills override user skills with the same `name`.

  ## Frontmatter schema

      ---
      name: my-skill
      description: short description used in the catalog
      disable-model-invocation: false
      allowed-tools: [read, glob, grep]
      ---

      # Body
      …whatever instructions the agent should follow when this skill is
      active. Anthropic recommends keeping bodies under 500 lines and
      splitting into linked files for anything larger.

  Only `name` and `description` are required. `disable-model-invocation`
  hides the skill from the catalog (host can still `preload/2` it).
  `allowed-tools` (when set) restricts the tool list while the skill is
  loaded; PR3a wires this into `Permissions.check/4`.

  ## Catalog rendering

      Skills.catalog_section([%Skill{name: "deploy", description: "Deploy
      this app to staging"}, ...])
      #=>
      ## Available Skills

      Use `[skill: <name>]` to load a skill's full instructions.

        - `deploy` — Deploy this app to staging
  """

  alias ExAthena.Messages.Message

  @user_dir Path.expand("~/.config/ex_athena/skills")
  @project_subdir ".exathena/skills"

  defmodule Skill do
    @moduledoc """
    A discovered skill. `body` is the markdown after the frontmatter,
    loaded only when needed; the catalog only ever uses `name` and
    `description`.
    """

    @enforce_keys [:name, :description, :body, :path]
    defstruct [
      :name,
      :description,
      :body,
      :path,
      disable_model_invocation: false,
      allowed_tools: nil
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            body: String.t(),
            path: String.t(),
            disable_model_invocation: boolean(),
            allowed_tools: [String.t()] | nil
          }
  end

  @doc """
  Discover all skills available for a given working directory. Returns a
  map keyed by skill name; later sources override earlier ones (project
  beats user).

  ## Options

    * `:user_dir` — override the user-level skills directory.
    * `:project_dir` — override the project-level skills directory
      (default: `<cwd>/.exathena/skills`).
  """
  @spec discover(String.t(), keyword()) :: %{String.t() => Skill.t()}
  def discover(cwd, opts \\ []) when is_binary(cwd) do
    user_dir = Keyword.get(opts, :user_dir, @user_dir)
    project_dir = Keyword.get(opts, :project_dir, Path.join(cwd, @project_subdir))

    %{}
    |> merge_skills(load_dir(user_dir))
    |> merge_skills(load_dir(project_dir))
  end

  @doc """
  Render the catalog section that's appended to the system prompt. Empty
  string when no model-invocable skills exist (so we don't pollute the
  prompt with a bare header).
  """
  @spec catalog_section(map() | [Skill.t()]) :: String.t()
  def catalog_section(skills) when is_map(skills),
    do: skills |> Map.values() |> catalog_section()

  def catalog_section(skills) when is_list(skills) do
    visible =
      Enum.reject(skills, fn %Skill{disable_model_invocation: hidden} -> hidden end)

    case visible do
      [] ->
        ""

      list ->
        lines =
          list
          |> Enum.sort_by(& &1.name)
          |> Enum.map_join("\n", fn %Skill{name: n, description: d} -> "  - `#{n}` — #{d}" end)

        """

        ## Available Skills

        Use `[skill: <name>]` in your response to load a skill's full instructions.

        #{lines}
        """
        |> String.trim_trailing()
    end
  end

  @doc """
  Build a system-role message that activates `skill_name` from `skills`.

  Returns `{:ok, message}` when the skill exists, `{:error, :not_found}`
  otherwise. The message is tagged `name: "skill:<name>"` so we can
  detect already-loaded skills (idempotency) and so the compactor knows
  not to drop it.
  """
  @spec activation_message(map(), String.t()) :: {:ok, Message.t()} | {:error, :not_found}
  def activation_message(skills, skill_name) when is_map(skills) and is_binary(skill_name) do
    case Map.get(skills, skill_name) do
      nil ->
        {:error, :not_found}

      %Skill{} = skill ->
        body =
          "<!-- skill: #{skill.name} (#{skill.path}) -->\n# Skill: #{skill.name}\n\n" <>
            skill.body

        {:ok, %Message{role: :system, content: body, name: "skill:#{skill.name}"}}
    end
  end

  @doc """
  Returns the set of skill names already activated in `messages` (so we
  don't re-attach idempotently).
  """
  @spec loaded_skills([Message.t()]) :: MapSet.t()
  def loaded_skills(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(fn
      %Message{name: "skill:" <> name} -> [name]
      _ -> []
    end)
    |> MapSet.new()
  end

  @doc """
  Extracts skill names referenced via `[skill: <name>]` sentinels in a
  block of model output. De-duplicated; case-sensitive on the name.
  """
  @spec extract_sentinels(String.t() | nil) :: [String.t()]
  def extract_sentinels(nil), do: []
  def extract_sentinels(""), do: []

  def extract_sentinels(text) when is_binary(text) do
    ~r/\[skill:\s*([A-Za-z0-9_\-\.\/]+)\s*\]/
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [name] -> name end)
    |> Enum.uniq()
  end

  @doc """
  Pre-load a list of skill bodies onto a message list. Returns the
  amended message list. Idempotent — already-loaded skills are skipped.

  Useful for hosts that know up-front which skills the agent will need
  (e.g. a `/deploy` slash command pre-attaching the `deploy` skill so
  the agent doesn't have to discover it).
  """
  @spec preload([Message.t()], map(), [String.t()]) :: [Message.t()]
  def preload(messages, skills, names)
      when is_list(messages) and is_map(skills) and is_list(names) do
    already = loaded_skills(messages)

    extra =
      names
      |> Enum.reject(&MapSet.member?(already, &1))
      |> Enum.flat_map(fn name ->
        case activation_message(skills, name) do
          {:ok, msg} -> [msg]
          {:error, _} -> []
        end
      end)

    messages ++ extra
  end

  # ── Internal ──────────────────────────────────────────────────────

  defp merge_skills(acc, []), do: acc

  defp merge_skills(acc, list) when is_list(list) do
    Enum.reduce(list, acc, fn %Skill{name: name} = skill, m -> Map.put(m, name, skill) end)
  end

  defp load_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry -> load_skill(Path.join(dir, entry)) end)

      {:error, _} ->
        []
    end
  end

  defp load_skill(skill_dir) do
    skill_md = Path.join(skill_dir, "SKILL.md")

    with true <- File.regular?(skill_md),
         {:ok, raw} <- File.read(skill_md),
         {:ok, frontmatter, body} <- split_frontmatter(raw),
         {:ok, parsed} <- parse_frontmatter(frontmatter) do
      [build(parsed, body, skill_md)]
    else
      _ -> []
    end
  end

  defp split_frontmatter(raw) do
    case String.split(raw, ~r/^---\s*\n/m, parts: 3) do
      ["", front, body] -> {:ok, front, String.trim_leading(body, "\n")}
      _ -> :no_frontmatter
    end
  end

  # Minimal YAML-ish parser: `key: value` per line, with `[a, b]` lists.
  # Anything richer should live in a real YAML dep; for skills the four
  # documented fields are all we read.
  defp parse_frontmatter(raw) do
    raw
    |> String.split("\n", trim: true)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case String.split(line, ":", parts: 2) do
        [k, v] ->
          key = k |> String.trim() |> String.downcase()
          val = v |> String.trim() |> coerce_value()
          {:cont, {:ok, Map.put(acc, key, val)}}

        _ ->
          {:halt, :bad_frontmatter}
      end
    end)
  end

  defp coerce_value("true"), do: true
  defp coerce_value("false"), do: false

  defp coerce_value("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [items, _] ->
        items
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        rest
    end
  end

  defp coerce_value(<<?", _::binary>> = quoted) do
    quoted
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end

  defp coerce_value(other), do: other

  defp build(parsed, body, path) do
    %Skill{
      name: parsed["name"] || error_no_name(path),
      description: parsed["description"] || "(no description)",
      body: String.trim(body),
      path: path,
      disable_model_invocation: parsed["disable-model-invocation"] == true,
      allowed_tools: parsed["allowed-tools"]
    }
  end

  defp error_no_name(path),
    do: raise(ArgumentError, "skill at #{path} has no `name` in frontmatter")
end
