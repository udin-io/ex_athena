defmodule ExAthena.Tools.GlobGrepTest do
  use ExUnit.Case, async: true

  alias ExAthena.ToolContext
  alias ExAthena.Tools.{Glob, Grep}

  setup do
    dir = Path.join(System.tmp_dir!(), "gg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "sub"))
    File.write!(Path.join(dir, "a.ex"), "defmodule A do\n  def foo, do: :bar\nend\n")
    File.write!(Path.join(dir, "b.ex"), "defmodule B do\n  def baz, do: :qux\nend\n")
    File.write!(Path.join(dir, "sub/c.ex"), "defmodule C do\n  def foo, do: :bar\nend\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, ctx: ToolContext.new(cwd: dir)}
  end

  test "Glob lists files under a pattern", %{ctx: ctx} do
    assert {:ok, output, ui} = Glob.execute(%{"pattern" => "**/*.ex"}, ctx)
    assert output =~ "a.ex"
    assert output =~ "b.ex"
    assert output =~ "sub/c.ex"

    assert ui.kind == :matches
    assert ui.payload.count >= 3
  end

  test "Glob returns '(no matches)' on empty", %{ctx: ctx} do
    assert {:ok, "(no matches)", %{kind: :matches, payload: %{count: 0}}} =
             Glob.execute(%{"pattern" => "*.nope"}, ctx)
  end

  test "Glob requires pattern", %{ctx: ctx} do
    assert {:error, :missing_pattern} = Glob.execute(%{}, ctx)
  end

  test "Glob respects max_results cap", %{ctx: ctx} do
    assert {:ok, output, _ui} =
             Glob.execute(%{"pattern" => "**/*.ex", "max_results" => 1}, ctx)

    # Only one line with a filename
    assert length(String.split(output, "\n", trim: true)) == 1
  end

  test "Grep finds matching lines", %{ctx: ctx} do
    assert {:ok, output, ui} = Grep.execute(%{"pattern" => "def foo"}, ctx)
    assert output =~ "a.ex"
    assert output =~ "sub/c.ex"

    assert ui.kind == :matches
    assert ui.payload.pattern == "def foo"
    assert ui.payload.count >= 2
  end

  test "Grep returns '(no matches)' when empty", %{ctx: ctx} do
    assert {:ok, output, %{kind: :matches, payload: %{count: 0}}} =
             Grep.execute(%{"pattern" => "zzzzzzzz"}, ctx)

    assert output =~ "(no matches)"
  end

  test "Grep requires pattern", %{ctx: ctx} do
    assert {:error, :missing_pattern} = Grep.execute(%{}, ctx)
  end
end
