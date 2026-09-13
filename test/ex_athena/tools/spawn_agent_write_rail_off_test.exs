defmodule ExAthena.Tools.SpawnAgentWriteRailOffTest do
  @moduledoc """
  The write rail's off switch.

  Every other rail in `SpawnAgent` reads a number. This one reads English
  written by a model and can be wrong, and a wrong refusal blocks a spawn
  that would have succeeded. A host that finds the detector firing on its
  own briefs needs a way to stand it down without waiting for a release, so
  `config :ex_athena, :agents, write_brief_rail: 0` turns it off.
  """
  # Mutates :ex_athena application config.
  use ExUnit.Case, async: false

  alias ExAthena.Agents.Quota
  alias ExAthena.{Response, ToolContext}
  alias ExAthena.Tools.SpawnAgent

  @write_brief "WRITE THE RESULT TO A FILE: `plan/guides.md`"

  setup do
    original = Application.get_env(:ex_athena, :agents)
    on_exit(fn -> Application.put_env(:ex_athena, :agents, original) end)

    dir = Path.join(System.tmp_dir!(), "write_rail_off_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    ctx =
      ToolContext.new(
        cwd: dir,
        session_id: "sess_#{System.unique_integer([:positive])}",
        assigns:
          Map.merge(Quota.install(%{}), %{
            spawn_agent_opts: [
              provider: :mock,
              mock: [
                responder: fn _req ->
                  %Response{text: "worker report", finish_reason: :stop, provider: :mock}
                end
              ],
              memory: false
            ]
          })
      )

    {:ok, ctx: ctx}
  end

  # The namespace is a keyword list from config.exs and a map once the web
  # settings file has been loaded; Tuning reads both, so this must write both.
  defp set_rail(value) do
    agents =
      case Application.get_env(:ex_athena, :agents) do
        m when is_map(m) -> Map.put(m, :write_brief_rail, value)
        kw when is_list(kw) -> Keyword.put(kw, :write_brief_rail, value)
        _ -> [write_brief_rail: value]
      end

    Application.put_env(:ex_athena, :agents, agents)
  end

  test "the rail is on by default", %{ctx: ctx} do
    assert {:error, _message} =
             SpawnAgent.execute(%{"prompt" => @write_brief, "agent" => "explore"}, ctx)
  end

  test "write_brief_rail: 0 lets the spawn through", %{ctx: ctx} do
    set_rail(0)

    assert {:ok, _text, _ui} =
             SpawnAgent.execute(%{"prompt" => @write_brief, "agent" => "explore"}, ctx)
  end

  test "any other value keeps it on", %{ctx: ctx} do
    set_rail(1)

    assert {:error, _message} =
             SpawnAgent.execute(%{"prompt" => @write_brief, "agent" => "explore"}, ctx)
  end
end
