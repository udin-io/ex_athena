defmodule ExAthena.Tools.SkillTest do
  use ExUnit.Case, async: true

  alias ExAthena.Skills.Skill, as: SkillDef
  alias ExAthena.ToolContext
  alias ExAthena.Tools.Skill

  defp skill(name, opts \\ []) do
    %SkillDef{
      name: name,
      description: Keyword.get(opts, :description, "does #{name}"),
      body: Keyword.get(opts, :body, "# #{name}\ndo the thing"),
      path: "/skills/#{name}/SKILL.md",
      disable_model_invocation: Keyword.get(opts, :hidden, false)
    }
  end

  defp ctx(skills) do
    ToolContext.new(cwd: "/tmp", assigns: %{skills: Map.new(skills, &{&1.name, &1})})
  end

  test "is registered as a builtin under the name models reach for" do
    assert Skill in ExAthena.Tools.builtins()
    assert ExAthena.Tools.find(ExAthena.Tools.builtins(), "skill") == Skill
  end

  test "is read-only and parallel-safe" do
    assert Skill.read_only?()
    assert Skill.parallel_safe?()
  end

  test "a known skill name succeeds and says the instructions are in context" do
    assert {:ok, text} = Skill.execute(%{"name" => "deploy"}, ctx([skill("deploy")]))
    assert text =~ "deploy"
    assert text =~ "instructions"
  end

  test "surrounding whitespace in the name is tolerated" do
    assert {:ok, _} = Skill.execute(%{"name" => "  deploy "}, ctx([skill("deploy")]))
  end

  test "an unknown name is a recoverable error that names the available skills" do
    ctx = ctx([skill("deploy"), skill("audit")])

    assert {:error, reason} = Skill.execute(%{"name" => "deploi"}, ctx)
    assert reason =~ "deploi"
    assert reason =~ "audit"
    assert reason =~ "deploy"
  end

  test "an unknown name with no skills at all says so" do
    assert {:error, reason} = Skill.execute(%{"name" => "deploy"}, ctx([]))
    assert reason =~ "No skills"
  end

  test "a skill with disable-model-invocation is not loadable by the model" do
    ctx = ctx([skill("internal", hidden: true), skill("deploy")])

    assert {:error, reason} = Skill.execute(%{"name" => "internal"}, ctx)
    refute reason =~ "internal,"
    assert reason =~ "deploy"
  end

  test "a missing name argument is an error, not a crash" do
    assert {:error, reason} = Skill.execute(%{}, ctx([skill("deploy")]))
    assert reason =~ "name"
  end

  test "the schema requires a single name argument" do
    schema = Skill.schema()
    assert schema.required == ["name"]
    assert Map.has_key?(schema.properties, :name)
  end
end
