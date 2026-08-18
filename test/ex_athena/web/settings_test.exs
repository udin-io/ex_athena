defmodule ExAthena.Web.SettingsTest do
  @moduledoc """
  The tuning rails are config keys, but config lives in source — changing one
  meant editing `config.exs` and restarting. Settings puts the same keys behind
  the web UI: edit, save, applied immediately and reloaded on next boot.
  """
  use ExUnit.Case, async: false

  alias ExAthena.{Tuning, Web.Settings}

  setup do
    dir = Path.join(System.tmp_dir!(), "settings_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "settings.json")
    Application.put_env(:ex_athena, :settings_path, path)

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.delete_env(:ex_athena, :settings_path)

      for ns <- Settings.namespaces(), do: Application.delete_env(:ex_athena, ns)
    end)

    {:ok, path: path}
  end

  describe "values/0" do
    test "reports the built-in default for every field when nothing is saved" do
      values = Settings.values()

      assert values[{:orchestrate, :max_planning_turns}] == 8
      assert values[{:agents, :result_chars}] == 64_000
      assert values[{:web, :max_retained_events}] == 2_000
    end

    test "covers every field the schema declares" do
      values = Settings.values()

      for group <- Settings.schema(), field <- group.fields do
        assert Map.has_key?(values, {group.ns, field.key}),
               "#{group.ns}.#{field.key} missing from values/0"
      end
    end
  end

  describe "save/1" do
    test "applies immediately — Tuning sees the new value without a restart" do
      assert {:ok, _} = Settings.save(%{"orchestrate.max_planning_turns" => "20"})
      assert Tuning.get(:orchestrate, :max_planning_turns, 8) == 20
    end

    test "persists so the value survives a restart", %{path: path} do
      assert {:ok, _} = Settings.save(%{"agents.result_chars" => "32000"})
      Application.delete_env(:ex_athena, :agents)
      assert Tuning.get(:agents, :result_chars, 64_000) == 64_000

      assert File.exists?(path)
      Settings.load()
      assert Tuning.get(:agents, :result_chars, 64_000) == 32_000
    end

    test "rejects a non-numeric value for a numeric field and names the field" do
      assert {:error, errors} = Settings.save(%{"orchestrate.max_planning_turns" => "twelve"})
      assert errors[{:orchestrate, :max_planning_turns}] =~ "number"
      assert Tuning.get(:orchestrate, :max_planning_turns, 8) == 8
    end

    test "rejects a value below the field's minimum" do
      assert {:error, errors} = Settings.save(%{"agents.result_chars" => "0"})
      assert errors[{:agents, :result_chars}] =~ "at least"
    end

    test "a rejected field does not stop the valid ones from being written" do
      assert {:error, _} =
               Settings.save(%{
                 "orchestrate.max_planning_turns" => "20",
                 "agents.result_chars" => "nope"
               })

      assert Tuning.get(:orchestrate, :max_planning_turns, 8) == 20
      assert Tuning.get(:agents, :result_chars, 64_000) == 64_000
    end

    # A form posts whatever the page contained; app env is global process
    # state, so anything not in the schema must never reach it.
    test "ignores keys the schema does not declare" do
      assert {:ok, _} = Settings.save(%{"orchestrate.evil_key" => "1", "nope.other" => "2"})

      refute Keyword.has_key?(Application.get_env(:ex_athena, :orchestrate, []), :evil_key)
      assert Application.get_env(:ex_athena, :nope) == nil
    end

    test "accepts a select field's allowed value and refuses anything else" do
      assert {:ok, _} = Settings.save(%{"model.reasoning_effort" => "high"})
      assert Tuning.get(:model, :reasoning_effort, :default) == :high

      assert {:error, errors} = Settings.save(%{"model.reasoning_effort" => "banana"})
      assert errors[{:model, :reasoning_effort}] =~ "one of"
    end
  end

  describe "reset/0" do
    test "clears saved overrides and returns every field to its default", %{path: path} do
      {:ok, _} = Settings.save(%{"orchestrate.max_planning_turns" => "20"})
      assert :ok = Settings.reset()

      assert Tuning.get(:orchestrate, :max_planning_turns, 8) == 8
      refute File.exists?(path)
    end
  end

  describe "load/0" do
    test "is a no-op when no settings file exists" do
      assert :ok = Settings.load()
      assert Tuning.get(:orchestrate, :max_planning_turns, 8) == 8
    end

    test "survives a corrupt settings file rather than crashing boot", %{path: path} do
      File.write!(path, "{not json")
      assert :ok = Settings.load()
      assert Tuning.get(:orchestrate, :max_planning_turns, 8) == 8
    end
  end

  describe "provider_opts/0" do
    test "sends nothing while reasoning effort is left at default" do
      assert Settings.provider_opts() == []
    end

    test "forwards a chosen effort" do
      {:ok, _} = Settings.save(%{"model.reasoning_effort" => "none"})
      assert Settings.provider_opts() == [reasoning_effort: :none]
    end
  end
end
