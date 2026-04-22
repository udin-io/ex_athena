defmodule ExAthena.Tools.BashTest do
  use ExUnit.Case, async: true

  alias ExAthena.ToolContext
  alias ExAthena.Tools.Bash

  setup do
    dir = Path.join(System.tmp_dir!(), "bash_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, ctx: ToolContext.new(cwd: dir)}
  end

  test "runs a command and captures output", %{ctx: ctx} do
    assert {:ok, output} = Bash.execute(%{"command" => "echo hello"}, ctx)
    assert output =~ "exit 0"
    assert output =~ "hello"
  end

  test "captures non-zero exit codes", %{ctx: ctx} do
    assert {:ok, output} = Bash.execute(%{"command" => "exit 7"}, ctx)
    assert output =~ "exit 7"
  end

  test "runs in the context's cwd", %{dir: dir, ctx: ctx} do
    assert {:ok, output} = Bash.execute(%{"command" => "pwd"}, ctx)
    # macOS symlinks /tmp → /private/tmp; compare the resolved path.
    resolved = File.cwd!() |> Path.expand() && dir |> Path.expand() |> Path.relative_to("/")
    assert output =~ resolved
  end

  test "times out", %{ctx: ctx} do
    assert {:error, :timeout} =
             Bash.execute(%{"command" => "sleep 2", "timeout_ms" => 100}, ctx)
  end

  test "missing command rejected", %{ctx: ctx} do
    assert {:error, :missing_command} = Bash.execute(%{}, ctx)
  end
end
