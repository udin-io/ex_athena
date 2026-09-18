defmodule ExAthena.Tools.SpawnAgentTimeoutConfigTest do
  @moduledoc """
  A worker's wall-clock budget was a module attribute with a host override and
  nothing in between, so the one number that decides when the handback stage
  fires — and, before it, when a worker is killed — could not be changed
  without editing source. It now resolves through `ExAthena.Tuning`, which is
  what puts it in the gear modal beside the stage that divides it.

  Two things it must NOT become. The host's `spawn_agent_opts[:timeout_ms]`
  still wins, because a host that sets it per run means it. And it stays out of
  the model's reach: small models supplied self-sabotaging 30-60s budgets that
  killed the worker after a single turn, the same lesson `cwd` records.
  """
  use ExUnit.Case, async: false

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "spawn_timeout_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.delete_env(:ex_athena, :agents)
    end)

    {:ok, dir: dir}
  end

  # Spawns one worker with `args`, then stops.
  defp parent_responder(args) do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1 do
        %Response{
          text: "delegating",
          tool_calls: [%ToolCall{id: "c1", name: "spawn_agent", arguments: args}],
          finish_reason: :tool_calls,
          provider: :mock
        }
      else
        %Response{text: "done", finish_reason: :stop, provider: :mock}
      end
    end
  end

  defp run(dir, args, spawn_opts) do
    Loop.run("coordinate the work",
      provider: :mock,
      mock: [responder: parent_responder(args)],
      tools: [ExAthena.Tools.SpawnAgent],
      cwd: dir,
      memory: false,
      max_iterations: 10,
      assigns: %{
        spawn_agent_opts:
          Keyword.merge(
            [
              provider: :mock,
              mock: [responder: fn _ -> %Response{text: "all done", finish_reason: :stop} end],
              tools: [],
              memory: false,
              max_iterations: 3
            ],
            spawn_opts
          )
      }
    )
  end

  defp spawn_content(result) do
    result.messages
    |> Enum.filter(&match?(%{role: :tool}, &1))
    |> Enum.flat_map(& &1.tool_results)
    |> List.first()
    |> Map.get(:content)
  end

  test "config sets the worker's budget", %{dir: dir} do
    Application.put_env(:ex_athena, :agents, timeout_ms: 1)

    blocked = fn _req -> receive do: (:never -> :never) end

    assert {:ok, result} = run(dir, %{"prompt" => "work"}, mock: [responder: blocked])
    assert spawn_content(result) =~ ~r/timed out/i
  end

  test "the host's spawn_agent_opts still beat the configured value", %{dir: dir} do
    Application.put_env(:ex_athena, :agents, timeout_ms: 1)

    assert {:ok, result} = run(dir, %{"prompt" => "work"}, timeout_ms: 30_000)
    assert spawn_content(result) =~ "all done"
  end

  test "with nothing configured the built-in default still applies", %{dir: dir} do
    Application.delete_env(:ex_athena, :agents)

    assert {:ok, result} = run(dir, %{"prompt" => "work"}, [])
    assert spawn_content(result) =~ "all done"
  end

  test "a timeout the MODEL asked for is ignored", %{dir: dir} do
    assert {:ok, result} = run(dir, %{"prompt" => "work", "timeout_ms" => 1}, [])
    assert spawn_content(result) =~ "all done"
  end
end
