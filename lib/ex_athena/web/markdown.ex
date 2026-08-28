defmodule ExAthena.Web.Markdown do
  @moduledoc """
  Renders the small Markdown subset used by the web chat.

  The renderer is safe by construction: it emits only the tags defined in this
  module and escapes every value that came from the model. Raw HTML is
  intentionally displayed as text. Links are limited to HTTP(S), `mailto:`,
  and same-origin relative destinations.
  """

  alias Phoenix.HTML.Safe

  # Link captures stop at any new link delimiter. Allowing either capture to
  # scan across another opener makes repeated malformed input such as `[x](`
  # quadratic in the LiveView process.
  @inline_pattern ~r/`([^`]+)`|\[([^\[\]]+)\]\(([^()\[\]]+)\)|\*\*\*([^*]+)\*\*\*|\*\*([^*]+)\*\*|\*([^*]+)\*/
  @fence_pattern ~r/^```(\w*)\s*$/
  @control_characters ~r/[\x00-\x1F\x7F]/
  @attribute_breakers ~r/["']/
  @character_reference ~r/&(?:#\d+|#x[0-9a-f]+|[a-z][a-z0-9]+);/i
  @web_schemes ~w(http https)

  @type render_state :: %{
          parts: [iodata()],
          list_kind: nil | :ul | :ol,
          fence: nil | %{language: String.t(), lines: [String.t()]}
        }

  @doc """
  Converts Markdown text to HTML-safe iodata.

  Supported syntax matches the chat's previous lightweight renderer: headings
  through level three, ordered and unordered lists, horizontal rules, fenced
  and inline code, emphasis, and links.
  """
  @spec render(String.t() | nil) :: Phoenix.HTML.safe()
  def render(nil), do: {:safe, []}

  def render(markdown) when is_binary(markdown) do
    state =
      markdown
      |> String.split("\n")
      |> Enum.reduce(initial_state(), &render_line/2)
      |> finish()

    {:safe, Enum.reverse(state.parts)}
  end

  defp initial_state, do: %{parts: [], list_kind: nil, fence: nil}

  defp render_line(line, %{fence: nil} = state) do
    case Regex.run(@fence_pattern, line, capture: :all_but_first) do
      [language] ->
        state
        |> close_list()
        |> Map.put(:fence, %{language: language, lines: []})

      nil ->
        render_regular_line(line, state)
    end
  end

  defp render_line(line, %{fence: fence} = state) do
    if String.trim(line) == "```" do
      state
      |> Map.put(:fence, nil)
      |> emit(render_fence(fence))
    else
      put_in(state, [:fence, :lines], [line | fence.lines])
    end
  end

  defp render_regular_line(line, state) do
    cond do
      heading = Regex.run(~r/^(\#{1,3}) (.+)$/, line, capture: :all_but_first) ->
        [marker, text] = heading
        level = String.length(marker)

        state
        |> close_list()
        |> emit([
          "<h",
          Integer.to_string(level),
          " class=\"md-h",
          Integer.to_string(level),
          "\">",
          render_inline(text),
          "</h",
          Integer.to_string(level),
          ">"
        ])

      item = Regex.run(~r/^[-*] (.+)$/, line, capture: :all_but_first) ->
        [text] = item

        state
        |> open_list(:ul)
        |> emit(["<li>", render_inline(text), "</li>"])

      item = Regex.run(~r/^\d+\. (.+)$/, line, capture: :all_but_first) ->
        [text] = item

        state
        |> open_list(:ol)
        |> emit(["<li>", render_inline(text), "</li>"])

      Regex.match?(~r/^---+$/, String.trim(line)) ->
        state
        |> close_list()
        |> emit("<hr class=\"md-hr\">")

      String.trim(line) == "" ->
        state
        |> close_list()
        |> emit("<br>")

      state.list_kind != nil ->
        emit(state, ["<li>", render_inline(line), "</li>"])

      true ->
        emit(state, ["<span>", render_inline(line), "</span><br>"])
    end
  end

  defp render_inline(text, allow_links \\ true) do
    case Regex.run(@inline_pattern, text, return: :index) do
      nil ->
        escape(text)

      captures ->
        [
          {start, length},
          code_index,
          label_index,
          href_index,
          bold_italic_index,
          bold_index,
          italic_index
        ] = pad_inline_captures(captures)

        prefix = binary_part(text, 0, start)
        suffix_start = start + length
        suffix = binary_part(text, suffix_start, byte_size(text) - suffix_start)

        [
          escape(prefix),
          render_inline_match(
            text,
            code_index,
            label_index,
            href_index,
            bold_italic_index,
            bold_index,
            italic_index,
            allow_links
          ),
          render_inline(suffix, allow_links)
        ]
    end
  end

  defp render_inline_match(
         text,
         code_index,
         label_index,
         href_index,
         bold_italic_index,
         bold_index,
         italic_index,
         allow_links
       ) do
    cond do
      present?(code_index) ->
        ["<code class=\"md-code\">", escape(slice(text, code_index)), "</code>"]

      present?(label_index) and allow_links ->
        render_link(slice(text, label_index), slice(text, href_index))

      present?(label_index) ->
        render_inline(slice(text, label_index), false)

      present?(bold_italic_index) ->
        ["<strong><em>", escape(slice(text, bold_italic_index)), "</em></strong>"]

      present?(bold_index) ->
        ["<strong>", escape(slice(text, bold_index)), "</strong>"]

      present?(italic_index) ->
        ["<em>", escape(slice(text, italic_index)), "</em>"]
    end
  end

  defp render_link(label, href) do
    case safe_href(href) do
      {:ok, safe_href} ->
        [
          "<a class=\"md-link\" href=\"",
          escape(safe_href),
          "\" target=\"_blank\" rel=\"noopener noreferrer\">",
          render_inline(label, false),
          "</a>"
        ]

      :error ->
        render_inline(label, false)
    end
  end

  defp safe_href(href) do
    href = String.trim(href)

    with false <- href == "",
         false <- Regex.match?(@control_characters, href),
         false <- Regex.match?(@attribute_breakers, href),
         false <- Regex.match?(@character_reference, href),
         {:ok, uri} <- URI.new(href),
         true <- valid_destination?(uri, href) do
      {:ok, URI.to_string(uri)}
    else
      _ -> :error
    end
  end

  defp valid_destination?(%URI{scheme: scheme, host: host}, _href)
       when is_binary(scheme) and is_binary(host) do
    String.downcase(scheme) in @web_schemes and host != ""
  end

  defp valid_destination?(%URI{scheme: scheme, path: path, host: nil}, _href)
       when is_binary(scheme) and is_binary(path) do
    String.downcase(scheme) == "mailto" and path != ""
  end

  defp valid_destination?(%URI{scheme: nil, host: nil}, href) do
    not String.starts_with?(href, ["//", "\\"]) and not String.contains?(href, "\\")
  end

  defp valid_destination?(_uri, _href), do: false

  defp render_fence(%{language: language, lines: lines}) do
    label =
      if language == "" do
        []
      else
        ["<span class=\"md-fence-lang\">", escape(language), "</span>"]
      end

    code =
      lines
      |> Enum.reverse()
      |> Enum.join("\n")
      |> String.trim()

    [
      "<div class=\"md-fence\">",
      label,
      "<pre><code>",
      escape(code),
      "</code></pre></div>"
    ]
  end

  defp open_list(%{list_kind: kind} = state, kind), do: state

  defp open_list(state, kind) do
    state
    |> close_list()
    |> emit(["<", Atom.to_string(kind), " class=\"md-", Atom.to_string(kind), "\">"])
    |> Map.put(:list_kind, kind)
  end

  defp close_list(%{list_kind: nil} = state), do: state

  defp close_list(%{list_kind: kind} = state) do
    state
    |> emit(["</", Atom.to_string(kind), ">"])
    |> Map.put(:list_kind, nil)
  end

  defp finish(%{fence: nil} = state), do: close_list(state)

  defp finish(%{fence: fence} = state) do
    state
    |> Map.put(:fence, nil)
    |> emit(render_fence(fence))
    |> close_list()
  end

  defp emit(state, iodata), do: %{state | parts: [iodata | state.parts]}

  defp escape(value), do: Safe.to_iodata(value)

  defp present?({index, _length}), do: index >= 0

  defp slice(text, {start, length}), do: binary_part(text, start, length)

  defp pad_inline_captures(captures) do
    captures ++ List.duplicate({-1, 0}, 7 - length(captures))
  end
end
