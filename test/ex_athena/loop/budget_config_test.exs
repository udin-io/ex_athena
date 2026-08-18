defmodule ExAthena.Loop.BudgetConfigTest do
  @moduledoc """
  The top-level run budgets lived only as `Keyword.get(opts, …, @attr)`, with
  no application-env layer — so the web UI, which never passes them, could
  never change them. `max_iterations` was the one most often retuned per
  model (it is what trips `:error_max_turns`), and it was the setting a user
  went looking for in the gear modal and could not find.
  """
  use ExUnit.Case, async: false

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "budget_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.txt"), "hello")

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.delete_env(:ex_athena, :loop)
    end)

    {:ok, dir: dir}
  end

  # Always calls a tool and never stops, so the run can only end by hitting
  # an iteration cap.
  defp endless do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      %Response{
        text: "reading",
        tool_calls: [%ToolCall{id: "c#{n}", name: "read", arguments: %{"path" => "a.txt"}}],
        finish_reason: :tool_calls,
        provider: :mock
      }
    end
  end

  defp run(dir, opts) do
    Loop.run(
      "go",
      [
        provider: :mock,
        mock: [responder: endless()],
        tools: [ExAthena.Tools.Read],
        cwd: dir,
        memory: false,
        skills: false,
        # Re-reading one file is "unproductive"; that guard would trip at 4
        # and mask the cap actually under test.
        max_unproductive_iterations: 10_000,
        max_consecutive_mistakes: 10_000
      ] ++ opts
    )
  end

  test "config caps the run when the caller passes no max_iterations", ctx do
    Application.put_env(:ex_athena, :loop, max_iterations: 2)

    assert {:ok, result} = run(ctx.dir, [])
    assert result.iterations == 2
  end

  # Resolution order must stay per-call > config > default, matching
  # ExAthena.Config. A host that asks for 7 gets 7 whatever is configured.
  test "an explicit max_iterations still beats the configured value", ctx do
    Application.put_env(:ex_athena, :loop, max_iterations: 2)

    assert {:ok, result} = run(ctx.dir, max_iterations: 7)
    assert result.iterations == 7
  end

  test "with nothing configured the built-in default still applies", ctx do
    Application.delete_env(:ex_athena, :loop)

    assert {:ok, result} = run(ctx.dir, max_iterations: 3)
    assert result.iterations == 3
  end
end
