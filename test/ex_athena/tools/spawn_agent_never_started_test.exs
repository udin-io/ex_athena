defmodule ExAthena.Tools.SpawnAgentNeverStartedTest do
  @moduledoc """
  The fourth result branch: `{:ok, {:error, reason}}`, which `SpawnAgent` tags
  `:sub_agent_crashed`'s sibling `:sub_agent_failed`.

  It is a different animal from the other three, and issue 221 grouped them.
  `ExAthena.Loop.run/2` returns `{:error, reason}` from exactly one place — the
  `with` over `build_initial_state/2` and `mode.init/1`, before the first
  iteration. So this branch means the worker never ran a turn: bad tool spec,
  unusable mode, unknown provider. Nothing was written, nothing was journalled,
  and there is no digest to hand back.

  That makes it the one worker failure that IS the parent's to own: the
  configuration is deterministic, so re-delegating the same brief reproduces it
  exactly. It stays COUNTED. What it owes the parent is a sentence it can act
  on rather than an inspected tuple.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Response, ToolContext}
  alias ExAthena.Tools.SpawnAgent

  defmodule RefusingMode do
    @moduledoc false
    @behaviour ExAthena.Loop.Mode

    @impl true
    def init(_state), do: {:error, :mode_refused}

    @impl true
    def iterate(state), do: {:halt, state}
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "spawn_never_started_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp ctx(dir, opts) do
    ToolContext.new(
      cwd: dir,
      session_id: "sess_#{System.unique_integer([:positive])}",
      assigns: %{
        spawn_agent_opts:
          Keyword.merge(
            [
              provider: :mock,
              mock: [
                responder: fn _req ->
                  %Response{text: "hi", finish_reason: :stop, provider: :mock}
                end
              ],
              memory: false
            ],
            opts
          )
      }
    )
  end

  test "a worker that never started says so, and names the reason", %{dir: dir} do
    assert {:error, message} =
             SpawnAgent.execute(%{"prompt" => "do the thing"}, ctx(dir, mode: RefusingMode))

    assert is_binary(message)
    assert message =~ "never started"
    assert message =~ ":mode_refused"
  end

  test "a worker that never started is still the parent's mistake", %{dir: dir} do
    # Two elements, not three: `{:error, text}` is scored by `Modes.ReAct`,
    # `{:error, :uncounted, text}` is not. A setup failure repeats on every
    # retry of the same brief, which is what the counter exists to stop.
    assert {:error, _message} =
             SpawnAgent.execute(%{"prompt" => "do the thing"}, ctx(dir, mode: RefusingMode))
  end
end
