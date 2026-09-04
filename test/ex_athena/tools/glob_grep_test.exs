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

  test "Glob confined to roots drops matches a `..` pattern reaches outside", %{ctx: ctx} do
    dir = ctx.cwd
    outside = dir <> "_outside"
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.ex"), "x")
    on_exit(fn -> File.rm_rf!(outside) end)

    pattern = "../#{Path.basename(outside)}/*.ex"

    # `include_artifacts` is on for both calls so that this test measures
    # confinement and nothing else. A match that escapes the cwd stays absolute
    # after `Path.relative_to/2`, so the artifact filter sees the whole
    # `System.tmp_dir!()` prefix — and on Linux that prefix is literally `/tmp`,
    # which is one of the artifact dirs. Without this the unconfined control
    # assertion below fails on every Linux box (including CI) for a reason that
    # has nothing to do with allowed_roots.
    args = %{"pattern" => pattern, "include_artifacts" => true}

    # Unconfined: the `..` escapes and finds the sibling file.
    assert {:ok, unconfined, _} = Glob.execute(args, ctx)
    assert unconfined =~ "secret.ex"

    # Confined to [dir]: the out-of-root match is filtered away.
    confined = ToolContext.new(cwd: dir, allowed_roots: [dir])

    assert {:ok, "(no matches)", %{payload: %{count: 0}}} =
             Glob.execute(args, confined)
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

  # ripgrep exits 2 when it hit an error ANYWHERE in the walk — including a
  # directory it could not read — even though it searched everything else and
  # found matches. The tool treated any exit but 0/1 as a hard failure, so a
  # completed search was thrown away: live, a worker grepping a project holding
  # a root-owned `data_psql/` got `{:rg_failed, 2, "./data_psql: Permission
  # denied (os error 13)"}` back three times, and had to reason its way past
  # its own tool ("the grep actually succeeded").
  #
  # Driven through ripgrep's actual output rather than by chmodding a
  # directory: only an unprivileged process can be stopped from reading one, so
  # a chmod-based test asserts nothing wherever the suite runs as root.
  describe "partial_payload/3 — ripgrep exited 2 mid-walk" do
    @unreadable "./data_psql: Permission denied (os error 13)"
    @match "./mix.lock:67:  \"ortex\": {:hex, :ortex, \"0.1.10\"},"

    test "returns the matches the search did find" do
      output = Enum.join([@unreadable, @match], "\n") <> "\n"

      assert {:ok, llm, ui} = Grep.partial_payload("ortex", output, 200)
      assert llm =~ "mix.lock:67"
      assert ui.payload.count == 1
      assert ui.payload.items == [@match]
    end

    test "does not count the diagnostic as a match" do
      output = Enum.join([@unreadable, @match], "\n") <> "\n"

      assert {:ok, _llm, ui} = Grep.partial_payload("ortex", output, 200)
      refute Enum.any?(ui.payload.items, &(&1 =~ "Permission denied"))
    end

    test "names what could not be read, so 'no match' is never mistaken for absent" do
      output = Enum.join([@unreadable, @match], "\n") <> "\n"

      assert {:ok, llm, _ui} = Grep.partial_payload("ortex", output, 200)
      assert llm =~ "incomplete search"
      assert llm =~ "does not prove absence"
      assert llm =~ "data_psql"
    end

    test "a search that matched nothing readable still reports the gap" do
      assert {:ok, llm, ui} = Grep.partial_payload("nope", @unreadable <> "\n", 200)
      assert ui.payload.count == 0
      assert llm =~ "no matches"
      assert llm =~ "incomplete search"
      assert llm =~ "data_psql"
    end

    test "honours the result cap" do
      output = Enum.map_join(1..10, "\n", &"./f#{&1}.ex:1:hit") <> "\n" <> @unreadable

      assert {:ok, _llm, ui} = Grep.partial_payload("hit", output, 3)
      assert ui.payload.count == 3
    end

    test "reads ripgrep output with no ./ prefix (version differences)" do
      output = "mix.lock:67:  ortex\n" <> "data_psql: Permission denied (os error 13)\n"

      assert {:ok, llm, ui} = Grep.partial_payload("ortex", output, 200)
      assert ui.payload.items == ["mix.lock:67:  ortex"]
      assert llm =~ "data_psql"
    end

    # A bad regex or an unknown flag also exits 2, with no matches and nothing
    # that looks like a path diagnostic. That must stay an error — reporting it
    # as an empty search would read as "definitely not there".
    test "output with neither matches nor diagnostics stays an error" do
      assert {:error, {:rg_failed, 2, _}} = Grep.partial_payload("(", "", 200)
    end
  end

  # A worker globbed `deps/ortex/**`, got a bare "(no matches)" because `deps/`
  # is filtered by default, and concluded "the glob tool is misbehaving with
  # `**` patterns" — then worked around a tool that was fine. Same shape as the
  # ripgrep case: a path that was SKIPPED must not be indistinguishable from
  # one that is not there, because the worker contract tells workers to treat a
  # repeated "no matches" as settled absence.
  describe "paths excluded as build artifacts" do
    setup %{ctx: ctx} do
      File.mkdir_p!(Path.join(ctx.cwd, "deps/ortex/lib"))
      File.write!(Path.join(ctx.cwd, "deps/ortex/mix.exs"), "x")
      File.write!(Path.join(ctx.cwd, "deps/ortex/lib/backend.ex"), "x")
      :ok
    end

    test "says they were excluded rather than reporting no matches", %{ctx: ctx} do
      assert {:ok, output, ui} = Glob.execute(%{"pattern" => "deps/ortex/**"}, ctx)

      assert ui.payload.count == 0
      assert output =~ "excluded"
      assert output =~ "include_artifacts"
      refute output == "(no matches)"
    end

    test "a pattern matching nothing at all still reads as absent", %{ctx: ctx} do
      assert {:ok, output, _ui} = Glob.execute(%{"pattern" => "no/such/thing/**"}, ctx)

      assert output == "(no matches)"
    end

    test "results found outside artifact dirs are unaffected", %{ctx: ctx} do
      assert {:ok, output, ui} = Glob.execute(%{"pattern" => "**/*.ex"}, ctx)

      assert ui.payload.count >= 3
      refute output =~ "excluded"
      refute output =~ "deps/ortex"
    end

    test "include_artifacts returns them with no notice", %{ctx: ctx} do
      assert {:ok, output, ui} =
               Glob.execute(%{"pattern" => "deps/ortex/**", "include_artifacts" => true}, ctx)

      assert ui.payload.count > 0
      refute output =~ "excluded"
    end
  end

  # `**` can expand to the same file by more than one route, and the duplicate
  # reached both the model and the count.
  describe "overlapping ** patterns" do
    # `**/ortex/**/*.ex` reaches deps/ortex/lib/ortex/backend.ex by two routes
    # when the segment repeats at two depths, and both reached the model.
    test "each path is listed once", %{ctx: ctx} do
      File.mkdir_p!(Path.join(ctx.cwd, "deps/ortex/lib/ortex"))
      File.write!(Path.join(ctx.cwd, "deps/ortex/lib/ortex/backend.ex"), "x")

      assert {:ok, output, ui} =
               Glob.execute(
                 %{"pattern" => "**/ortex/**/*.ex", "include_artifacts" => true},
                 ctx
               )

      assert ui.payload.items == Enum.uniq(ui.payload.items)
      assert ui.payload.count == length(ui.payload.items)
      assert length(String.split(output, "\n")) == ui.payload.count
    end
  end

  describe "build-artifact filtering" do
    setup do
      dir = Path.join(System.tmp_dir!(), "gg_filter_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dir, "lib"))
      File.mkdir_p!(Path.join(dir, "_build/dev/lib/phoenix/priv/templates/phx.gen.auth"))
      File.mkdir_p!(Path.join(dir, "deps/phoenix/lib"))
      File.mkdir_p!(Path.join(dir, "node_modules/foo"))
      File.mkdir_p!(Path.join(dir, ".git"))
      File.mkdir_p!(Path.join(dir, "priv/static/assets"))
      File.mkdir_p!(Path.join(dir, "tmp"))

      File.write!(Path.join(dir, "lib/app.ex"), "defmodule App do\n  def needle, do: :ok\nend\n")

      File.write!(
        Path.join(dir, "_build/dev/lib/phoenix/priv/templates/phx.gen.auth/auth.ex"),
        "defmodule Phx.Auth do\n  def needle, do: :ok\nend\n"
      )

      File.write!(
        Path.join(dir, "deps/phoenix/lib/phoenix.ex"),
        "defmodule Phoenix do\n  def needle, do: :ok\nend\n"
      )

      File.write!(Path.join(dir, "node_modules/foo/bar.js"), "// needle\n")
      File.write!(Path.join(dir, ".git/HEAD"), "ref: needle\n")
      File.write!(Path.join(dir, "priv/static/assets/app.css"), "/* needle */\n")

      File.write!(
        Path.join(dir, "tmp/scratch.ex"),
        "defmodule Scratch do\n  def needle, do: :ok\nend\n"
      )

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, ctx: ToolContext.new(cwd: dir)}
    end

    test "Glob excludes _build, deps, node_modules, .git, priv/static, tmp by default",
         %{ctx: ctx} do
      {:ok, output, ui} = Glob.execute(%{"pattern" => "**/*.ex"}, ctx)

      assert output =~ "lib/app.ex"
      refute output =~ "_build/"
      refute output =~ "deps/"
      refute output =~ "tmp/"
      assert ui.payload.count == 1
    end

    test "Glob honors include_artifacts: true and returns build/dep paths too",
         %{ctx: ctx} do
      {:ok, output, _ui} =
        Glob.execute(%{"pattern" => "**/*.ex", "include_artifacts" => true}, ctx)

      assert output =~ "lib/app.ex"
      assert output =~ "_build/"
      assert output =~ "deps/"
      assert output =~ "tmp/"
    end

    test "Grep excludes the same artifact directories by default", %{ctx: ctx} do
      {:ok, output, ui} = Grep.execute(%{"pattern" => "needle"}, ctx)

      assert output =~ "lib/app.ex"
      refute output =~ "_build/"
      refute output =~ "deps/"
      refute output =~ "node_modules/"
      refute output =~ ".git/"
      refute output =~ "priv/static/"
      refute output =~ "tmp/"
      assert ui.payload.count >= 1
    end

    test "Grep honors include_artifacts: true", %{ctx: ctx} do
      {:ok, output, _ui} =
        Grep.execute(%{"pattern" => "needle", "include_artifacts" => true}, ctx)

      assert output =~ "lib/app.ex"
      assert output =~ "_build/"
      assert output =~ "deps/"
    end

    test "Glob excludes nested artifact dirs (e.g. web/_build, web/deps)", %{ctx: ctx} do
      # Phoenix-in-subdir layout: build/dep dirs are under `web/`, not at the root.
      File.mkdir_p!(Path.join(ctx.cwd, "web/_build/dev/lib"))
      File.mkdir_p!(Path.join(ctx.cwd, "web/deps/phoenix/lib"))
      File.mkdir_p!(Path.join(ctx.cwd, "web/lib"))
      File.mkdir_p!(Path.join(ctx.cwd, "web/priv/static/assets"))
      File.write!(Path.join(ctx.cwd, "web/lib/app.ex"), "real\n")
      File.write!(Path.join(ctx.cwd, "web/_build/dev/lib/template.ex"), "noise\n")
      File.write!(Path.join(ctx.cwd, "web/deps/phoenix/lib/phoenix.ex"), "noise\n")
      File.write!(Path.join(ctx.cwd, "web/priv/static/assets/app.css"), "noise\n")

      {:ok, output, _ui} = Glob.execute(%{"pattern" => "web/**/*.ex"}, ctx)

      assert output =~ "web/lib/app.ex"
      refute output =~ "web/_build/"
      refute output =~ "web/deps/"
    end

    test "Grep excludes nested artifact dirs (e.g. web/_build, web/deps)", %{ctx: ctx} do
      File.mkdir_p!(Path.join(ctx.cwd, "web/_build/dev/lib"))
      File.mkdir_p!(Path.join(ctx.cwd, "web/deps/phoenix/lib"))
      File.mkdir_p!(Path.join(ctx.cwd, "web/lib"))

      File.write!(
        Path.join(ctx.cwd, "web/lib/app.ex"),
        "defmodule WebApp do\n  def needle, do: :ok\nend\n"
      )

      File.write!(
        Path.join(ctx.cwd, "web/_build/dev/lib/template.ex"),
        "defmodule Tmpl do\n  def needle, do: :noise\nend\n"
      )

      File.write!(
        Path.join(ctx.cwd, "web/deps/phoenix/lib/phoenix.ex"),
        "defmodule Phx do\n  def needle, do: :noise\nend\n"
      )

      {:ok, output, _ui} = Grep.execute(%{"pattern" => "needle"}, ctx)

      assert output =~ "web/lib/app.ex"
      refute output =~ "web/_build/"
      refute output =~ "web/deps/"
    end
  end
end
