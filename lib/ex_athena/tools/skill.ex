defmodule ExAthena.Tools.Skill do
  @moduledoc """
  Load a skill's full instructions by calling for it by name.

  Skills were loadable one way: the model wrote `[skill: <name>]` in its
  reply text and `ExAthena.Modes.ReAct` picked the sentinel up. Models do
  not do that. In web session `66f4204cd532` the orchestrator called
  `skill: architecture-brief-and-mocks` as a TOOL, twice, collected two
  unknown-tool errors against a cap of three, and concluded "the skill tool
  is not available in this environment" — then did the work from the
  one-line catalog descriptions alone, which is the exact failure the
  feature exists to prevent. The bodies were on disk, discovered,
  catalogued and never read.

  Every model worth running is trained on tool calls, and a skill looks like
  a tool. So it is one.

  ## One loader, two entry points

  This tool does not return the body. It validates the name and the loop
  attaches the body through `ExAthena.Skills.activation_message/2` — the
  same call the sentinel path makes, producing the same system message
  tagged `skill:<name>`. Three things follow for free: the body arrives
  byte-identical whichever entry point asked for it, `Skills.loaded_skills/1`
  sees one load and not two when both entry points name the same skill, and
  the compactor already knows not to drop that message.

  `ExAthena.Tools.PlanMode` has the same shape: the tool states the
  intent, the loop applies it.

  Calling for a skill already in context is not an error and not a second
  copy — the result says the instructions are in context, which is true
  either way, and the loader skips the attach.
  """

  @behaviour ExAthena.Tool

  alias ExAthena.Skills
  alias ExAthena.ToolContext

  @impl true
  def name, do: "skill"

  @impl true
  def description do
    "Load one skill's full instructions into your context. `name` is a skill " <>
      "from the Available Skills list in your system prompt. The instructions " <>
      "arrive as a system message on your next turn — call this BEFORE starting " <>
      "the work the skill covers, then follow what it says."
  end

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        name: %{
          type: "string",
          description: "The skill's name, exactly as the Available Skills list spells it."
        }
      },
      required: ["name"]
    }
  end

  @impl true
  def parallel_safe?, do: true

  @impl true
  def read_only?, do: true

  @impl true
  def execute(%{"name" => name}, %ToolContext{} = ctx) when is_binary(name) do
    skills = invocable(ctx)
    wanted = String.trim(name)

    case Map.get(skills, wanted) do
      nil -> {:error, unknown(wanted, skills)}
      _skill -> {:ok, loaded(wanted)}
    end
  end

  def execute(_args, _ctx),
    do: {:error, "skill takes a `name`: the name of one skill from the Available Skills list."}

  defp invocable(%ToolContext{assigns: assigns}) do
    assigns
    |> Kernel.||(%{})
    |> Map.get(:skills, %{})
    |> Skills.model_invocable()
  end

  defp loaded(name) do
    "Skill `#{name}` is loaded — its full instructions are in your context as a " <>
      "system message headed \"# Skill: #{name}\". Follow them."
  end

  defp unknown(name, skills) when map_size(skills) == 0 do
    "There is no skill named `#{name}`. No skills are available in this run — " <>
      "carry on without one."
  end

  defp unknown(name, skills) do
    available = skills |> Map.keys() |> Enum.sort() |> Enum.join(", ")

    "There is no skill named `#{name}`. Available skills: #{available}. " <>
      "Call skill again with one of those names, or carry on without one."
  end
end
