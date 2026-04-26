defmodule ExAthena.SkillsTest do
  use ExUnit.Case, async: true

  alias ExAthena.Messages.Message
  alias ExAthena.Skills
  alias ExAthena.Skills.Skill

  setup do
    cwd = Path.join(System.tmp_dir!(), "skills_proj_#{System.unique_integer([:positive])}")
    user_dir = Path.join(System.tmp_dir!(), "skills_user_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    File.mkdir_p!(user_dir)

    on_exit(fn ->
      File.rm_rf!(cwd)
      File.rm_rf!(user_dir)
    end)

    {:ok, cwd: cwd, user_dir: user_dir}
  end

  defp write_skill(root, name, frontmatter, body) do
    skill_dir = Path.join(root, name)
    File.mkdir_p!(skill_dir)

    contents = "---\n" <> frontmatter <> "\n---\n" <> body
    File.write!(Path.join(skill_dir, "SKILL.md"), contents)
    skill_dir
  end

  describe "discover/2" do
    test "returns empty when no skill dirs exist", %{cwd: cwd, user_dir: ud} do
      assert Skills.discover(cwd, user_dir: ud, project_dir: Path.join(cwd, ".exathena/skills")) ==
               %{}
    end

    test "loads a project skill with full frontmatter", %{cwd: cwd, user_dir: ud} do
      project_dir = Path.join(cwd, ".exathena/skills")

      write_skill(
        project_dir,
        "deploy",
        "name: deploy\ndescription: Ship it.\nallowed-tools: [bash, read]",
        "# Body\nRun `bin/deploy`."
      )

      skills = Skills.discover(cwd, user_dir: ud, project_dir: project_dir)

      assert %{"deploy" => %Skill{} = s} = skills
      assert s.name == "deploy"
      assert s.description == "Ship it."
      assert s.body =~ "Run `bin/deploy`."
      assert s.allowed_tools == ["bash", "read"]
      refute s.disable_model_invocation
    end

    test "project skills override user skills with the same name", %{cwd: cwd, user_dir: ud} do
      project_dir = Path.join(cwd, ".exathena/skills")
      write_skill(ud, "deploy", "name: deploy\ndescription: user version", "user body")

      write_skill(
        project_dir,
        "deploy",
        "name: deploy\ndescription: project version",
        "project body"
      )

      skills = Skills.discover(cwd, user_dir: ud, project_dir: project_dir)
      assert skills["deploy"].description == "project version"
      assert skills["deploy"].body == "project body"
    end

    test "respects disable-model-invocation", %{cwd: cwd, user_dir: ud} do
      project_dir = Path.join(cwd, ".exathena/skills")

      write_skill(
        project_dir,
        "internal",
        "name: internal\ndescription: hidden\ndisable-model-invocation: true",
        "body"
      )

      skills = Skills.discover(cwd, user_dir: ud, project_dir: project_dir)
      assert skills["internal"].disable_model_invocation
    end
  end

  describe "catalog_section/1" do
    test "returns empty string when there are no model-invocable skills" do
      assert Skills.catalog_section(%{}) == ""

      hidden = %Skill{
        name: "x",
        description: "d",
        body: "b",
        path: "/p",
        disable_model_invocation: true
      }

      assert Skills.catalog_section(%{"x" => hidden}) == ""
    end

    test "renders each skill on its own line, alphabetised" do
      skills = %{
        "deploy" => %Skill{name: "deploy", description: "Ship it.", body: "", path: "/d"},
        "audit" => %Skill{name: "audit", description: "Audit perms.", body: "", path: "/a"}
      }

      section = Skills.catalog_section(skills)
      assert section =~ "## Available Skills"
      assert section =~ "Use `[skill: <name>]`"

      # Skill bullets are alphabetised; the audit line appears before the
      # deploy line in the rendered section.
      audit_idx = :binary.match(section, "audit") |> elem(0)
      deploy_idx = :binary.match(section, "deploy") |> elem(0)
      assert audit_idx < deploy_idx
    end
  end

  describe "extract_sentinels/1" do
    test "extracts skill names from `[skill: name]` references" do
      assert Skills.extract_sentinels("Let me [skill: deploy] this.") == ["deploy"]
      assert Skills.extract_sentinels("First [skill: a] then [skill: b].") == ["a", "b"]
      assert Skills.extract_sentinels("Repeat [skill: a] [skill: a].") == ["a"]
      assert Skills.extract_sentinels("no sentinel here") == []
      assert Skills.extract_sentinels(nil) == []
      assert Skills.extract_sentinels("") == []
    end
  end

  describe "activation_message/2 + loaded_skills/1" do
    test "produces a system message tagged for the skill" do
      skills = %{
        "deploy" => %Skill{
          name: "deploy",
          description: "d",
          body: "## Steps\n1. Build",
          path: "/x"
        }
      }

      assert {:ok, %Message{role: :system, name: "skill:deploy", content: c}} =
               Skills.activation_message(skills, "deploy")

      assert c =~ "skill: deploy"
      assert c =~ "1. Build"
    end

    test "returns :not_found for unknown skills" do
      assert {:error, :not_found} = Skills.activation_message(%{}, "missing")
    end

    test "loaded_skills returns the names already activated" do
      messages = [
        %Message{role: :user, content: "hi"},
        %Message{role: :system, content: "x", name: "skill:deploy"},
        %Message{role: :system, content: "x", name: "skill:audit"}
      ]

      loaded = Skills.loaded_skills(messages)
      assert MapSet.equal?(loaded, MapSet.new(["deploy", "audit"]))
    end
  end

  describe "preload/3" do
    test "appends activation messages, skipping already-loaded skills" do
      skills = %{
        "deploy" => %Skill{name: "deploy", description: "d", body: "DEPLOY", path: "/d"},
        "audit" => %Skill{name: "audit", description: "a", body: "AUDIT", path: "/a"}
      }

      msgs = [%Message{role: :user, content: "hi"}]
      msgs2 = Skills.preload(msgs, skills, ["deploy"])
      assert length(msgs2) == 2
      assert Enum.any?(msgs2, &match?(%Message{name: "skill:deploy"}, &1))

      # Idempotent on a second preload.
      msgs3 = Skills.preload(msgs2, skills, ["deploy", "audit"])
      assert length(msgs3) == 3
      assert Enum.count(msgs3, &match?(%Message{name: "skill:deploy"}, &1)) == 1
      assert Enum.count(msgs3, &match?(%Message{name: "skill:audit"}, &1)) == 1
    end

    test "skips unknown skill names silently" do
      msgs = [%Message{role: :user, content: "hi"}]
      assert Skills.preload(msgs, %{}, ["unknown"]) == msgs
    end
  end
end
