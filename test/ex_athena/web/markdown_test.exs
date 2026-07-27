defmodule ExAthena.Web.MarkdownTest do
  use ExUnit.Case, async: true

  alias ExAthena.Web.Markdown

  defp render(markdown) do
    markdown
    |> Markdown.render()
    |> Phoenix.HTML.safe_to_string()
  end

  describe "safe rendering" do
    test "displays raw HTML as text instead of creating executable elements" do
      payloads = [
        ~s|<img src=x onerror="alert(1)">|,
        ~s|<svg onload="alert(1)"><script>alert(2)</script></svg>|,
        ~s|<iframe srcdoc="<script>alert(1)</script>"></iframe>|,
        ~s|</span><details open ontoggle="alert(1)">x</details>|
      ]

      for payload <- payloads do
        html = render(payload)

        refute html =~ ~r/<(?:img|svg|script|iframe|details)\b/i
        assert html =~ "&lt;"
      end
    end

    test "escapes raw HTML in every supported Markdown context" do
      payload = ~s|<img src=x onerror="alert(1)">|

      for markdown <- [
            "# #{payload}",
            "- #{payload}",
            "1. #{payload}",
            "**#{payload}**",
            "*#{payload}*",
            "[#{payload}](https://example.com)"
          ] do
        html = render(markdown)

        refute html =~ "<img"
        assert html =~ "&lt;img"
      end
    end

    test "escapes HTML inside inline and fenced code" do
      inline = render("`<img src=x onerror=alert(1)>`")

      fenced =
        render("""
        ```html
        <script>alert("xss")</script>
        ```
        """)

      assert inline =~ "<code class=\"md-code\">&lt;img"
      refute inline =~ "<img"
      assert fenced =~ "<div class=\"md-fence\">"
      assert fenced =~ "&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;"
      refute fenced =~ "<script"
    end

    test "rejects executable and non-web link schemes" do
      dangerous_urls = [
        "javascript:alert%281%29",
        "JAVASCRIPT:alert%281%29",
        "data:text/html;base64,PHNjcmlwdD4=",
        "vbscript:msgbox%281%29",
        "file:///etc/passwd",
        "blob:https://example.com/id",
        "//example.com/path",
        "\\\\example.com/path",
        "javascript&#58;alert%281%29",
        "java&#x73;cript&#58;alert",
        "javascript&colon;alert",
        "java&Tab;script&colon;alert",
        "&#106;&#97;&#118;&#97;&#115;&#99;&#114;&#105;&#112;&#116;&#58;alert"
      ]

      for url <- dangerous_urls do
        html = render("[open](#{url})")

        refute html =~ "<a", "expected #{inspect(url)} to render without a link"
        assert html =~ "open"
      end
    end

    test "rejects control characters that can obscure a URL scheme" do
      for url <- [
            "java\tscript:alert",
            "java\rscript:alert",
            "java\nscript:alert",
            "java\0script:alert",
            "java\x7Fscript:alert"
          ] do
        html = render("[open](#{url})")

        refute html =~ "<a"
        assert html =~ "open"
      end
    end

    test "rejects entity-looking destinations before HTML parsing" do
      html = render("[open](https://example.com/&quot;onmouseover=&quot;alert)")

      refute html =~ "<a"
      assert html =~ "open"
    end

    test "allows web, mail, and same-origin relative links with fixed security attributes" do
      html =
        render(
          "[HTTPS](https://example.com/docs?q=one&lang=en) " <>
            "[HTTP](http://example.com) [mail](mailto:security@example.com) " <>
            "[root](/guides/start) [file](../README.md) [fragment](#security) [query](?page=2)"
        )

      assert html =~
               ~s|<a class="md-link" href="https://example.com/docs?q=one&amp;lang=en" target="_blank" rel="noopener noreferrer">HTTPS</a>|

      assert html =~
               ~s|<a class="md-link" href="http://example.com" target="_blank" rel="noopener noreferrer">HTTP</a>|

      assert html =~
               ~s|<a class="md-link" href="mailto:security@example.com" target="_blank" rel="noopener noreferrer">mail</a>|

      for {label, href} <- [
            {"root", "/guides/start"},
            {"file", "../README.md"},
            {"fragment", "#security"},
            {"query", "?page=2"}
          ] do
        assert html =~
                 ~s|<a class="md-link" href="#{href}" target="_blank" rel="noopener noreferrer">#{label}</a>|
      end

      {:ok, document} = Floki.parse_fragment(html)

      refute Enum.any?(Floki.find(document, "a"), fn {"a", attributes, _children} ->
               Enum.any?(attributes, fn {name, _value} -> String.starts_with?(name, "on") end)
             end)
    end

    test "rejects quote-breaking destinations and escapes malicious labels" do
      for quote <- [?", ?'] do
        html =
          render(
            "[<img src=x onerror=alert(1)>](https://example.com/#{<<quote>>}onmouseover=alert)"
          )

        refute html =~ "<a"
        refute html =~ "<img"
        assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
      end
    end

    test "does not decode HTML entities into active markup" do
      html = render("&lt;img src=x onerror=alert(1)&gt;")

      assert html =~ "&amp;lt;img"
      refute html =~ "<img"
    end
  end

  describe "supported Markdown" do
    test "renders headings, emphasis, lists, rules, and code" do
      html =
        render("""
        # Heading
        Text with **bold**, *italic*, ***both***, and `code`.
        - first
        - second
        ---
        """)

      assert html =~ ~s|<h1 class="md-h1">Heading</h1>|
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<em>italic</em>"
      assert html =~ "<strong><em>both</em></strong>"
      assert html =~ ~s|<code class="md-code">code</code>|
      assert html =~ ~s|<ul class="md-ul"><li>first</li><li>second</li></ul>|
      assert html =~ ~s|<hr class="md-hr">|
    end

    test "renders nil and malformed Markdown without raising" do
      assert Phoenix.HTML.safe_to_string(Markdown.render(nil)) == ""
      assert render("**unclosed <tag>") =~ "**unclosed &lt;tag&gt;"
      assert render("```html\n<em>unfinished") =~ "&lt;em&gt;unfinished"

      mixed_fence = render("```html\nsafe\n```<img src=x onerror=alert(1)>")
      refute mixed_fence =~ "<img"
      assert mixed_fence =~ "&lt;img"
    end

    test "handles long malformed link streams without quadratic slowdown" do
      malformed = String.duplicate("[x](", 50_000)

      {elapsed_microseconds, html} = :timer.tc(fn -> render(malformed) end)

      assert byte_size(html) > byte_size(malformed)

      assert elapsed_microseconds < 3_000_000,
             "malformed links took #{elapsed_microseconds / 1_000_000}s to render"
    end
  end
end
