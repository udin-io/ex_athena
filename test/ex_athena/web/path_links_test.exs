defmodule ExAthena.Web.PathLinksTest do
  @moduledoc """
  Turning the paths a report names into links (issue #269).

  Driven through `ExAthena.Web.Markdown.render/2`, which is what the chat
  actually calls — the linker only matters in the markup it ends up producing.

  The bar is deliberately lopsided. A missed link costs a click; a false one
  is worse, because every report is full of dotted identifiers
  (`Fudu.Accounts.TenantClaim`, `ExAthena.Loop.Terminations`) that look
  path-like. So each case below that asserts **plain text** is the load-bearing
  one.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Web.Markdown

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(Path.join(root, "docs/design"))
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(outside)

    File.write!(Path.join(root, "docs/design/brief.html"), "<h1>brief</h1>")
    File.write!(Path.join(root, "lib/re_act.ex"), "defmodule ReAct do end")
    File.write!(Path.join(root, "mix.exs"), "defmodule MixProject do end")
    File.write!(Path.join(outside, "secret.txt"), "not yours")

    %{root: root, outside: outside}
  end

  # The root token is opaque to the linker — it only carries it into the
  # download URL — so this stays a pure, async unit. `FileControllerTest`
  # covers what a real `Phoenix.Token` root means on the wire.
  @root_token "signed-root-token"

  defp render(text, root) do
    text
    |> Markdown.render(links: %{root: root, token: @root_token})
    |> Phoenix.HTML.safe_to_string()
  end

  describe "a path that resolves inside the root" do
    test "becomes a viewer link and a download link", %{root: root} do
      html = render("The brief is at docs/design/brief.html now.", root)

      assert html =~ ~s(phx-click="files_open")
      assert html =~ ~s(phx-value-path="#{Path.join(root, "docs/design/brief.html")}")
      assert html =~ ~s(>docs/design/brief.html</a>)
      assert html =~ ~s(class="path-dl" href="/files/download?)
      assert html =~ "root=#{@root_token}"
    end

    test "works when the report writes it as an absolute path", %{root: root} do
      abs = Path.join(root, "lib/re_act.ex")

      html = render("See #{abs} for the counter.", root)

      assert html =~ ~s(phx-value-path="#{abs}")
      assert html =~ ~s(>#{abs}</a>)
    end

    test "works inside backticks, where reports usually put it", %{root: root} do
      html = render("Check `docs/design/brief.html` before approving.", root)

      assert html =~ ~s(<code class="md-code">)
      assert html =~ ~s(phx-click="files_open")
      assert html =~ ~s(>docs/design/brief.html</a>)
    end

    test "links a dotted filename with no slash, like mix.exs", %{root: root} do
      html = render("Nothing in mix.exs changed.", root)

      assert html =~ ~s(phx-value-path="#{Path.join(root, "mix.exs")}")
    end

    test "leaves trailing punctuation outside the link", %{root: root} do
      html = render("Wrote docs/design/brief.html, then stopped.", root)

      assert html =~ ~s(>docs/design/brief.html</a>)
      refute html =~ ~s(brief.html,</a>)
      assert html =~ ", then stopped."
    end
  end

  describe "a path that does not resolve stays plain text" do
    test "a file that does not exist", %{root: root} do
      html = render("I also wrote tmp/summary-269.html for you.", root)

      refute html =~ "files_open"
      refute html =~ "path-dl"
      assert html =~ "tmp/summary-269.html"
    end

    test "an absolute path outside the root", %{root: root, outside: outside} do
      secret = Path.join(outside, "secret.txt")

      html = render("Compare against #{secret} on disk.", root)

      refute html =~ "files_open"
      assert html =~ secret
    end

    test "a `..` traversal that would land on a real file", %{root: root, outside: outside} do
      escape = "../" <> Path.basename(outside) <> "/secret.txt"
      assert File.regular?(Path.expand(escape, root)), "fixture must really exist"

      html = render("Look at #{escape} instead.", root)

      refute html =~ "files_open"
    end

    test "a symlink inside the root that points out of it", %{root: root, outside: outside} do
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "escape.txt"))

      html = render("Read escape.txt for the details.", root)

      refute html =~ "files_open"
    end

    test "a module name that looks path-like", %{root: root} do
      html = render("Nothing changed in Fudu.Accounts.TenantClaim or ExAthena.Loop.", root)

      refute html =~ "files_open"
      assert html =~ "Fudu.Accounts.TenantClaim"
    end

    test "a directory, which has no bytes to serve", %{root: root} do
      html = render("Everything lives under docs/design now.", root)

      refute html =~ "files_open"
    end
  end

  describe "the rest of the renderer is unchanged" do
    test "render/1 still produces no links at all" do
      html = "Wrote mix.exs." |> Markdown.render() |> Phoenix.HTML.safe_to_string()

      refute html =~ "files_open"
      assert html =~ "Wrote mix.exs."
    end

    test "a fenced code block is left alone", %{root: root} do
      html = render("```\nmix.exs\n```", root)

      refute html =~ "files_open"
      assert html =~ "md-fence"
    end

    test "surrounding text is still escaped", %{root: root} do
      html = render("Before <script>alert(1)</script> and mix.exs after.", root)

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
      assert html =~ "files_open"
    end

    test "markdown links still work beside path links", %{root: root} do
      html = render("[docs](https://example.com) and mix.exs.", root)

      assert html =~ ~s(class="md-link" href="https://example.com")
      assert html =~ "files_open"
    end
  end
end
