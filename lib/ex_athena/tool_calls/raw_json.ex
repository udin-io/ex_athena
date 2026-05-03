defmodule ExAthena.ToolCalls.RawJson do
  @moduledoc """
  Best-effort parser for bare JSON tool calls embedded in assistant text.

  Handles weak open-weight models (e.g. `qwen2.5-coder:14b` via Ollama) that
  emit tool calls as raw JSON objects in the text rather than structured
  `tool_calls` arrays or `~~~tool_call` fences.

  A valid payload looks like:

      {"name": "read_file", "arguments": {"path": "/tmp/foo"}}

  or wrapped in a markdown code fence:

      ```json
      {"name": "read_file", "arguments": {"path": "/tmp/foo"}}
      ```

  The parser walks the text scanning for `{` characters, then uses a
  balanced-brace scanner that respects JSON string boundaries (backslash
  escapes, in-string state). Never raises — malformed input returns `{:ok, []}`.
  """

  alias ExAthena.Messages.ToolCall

  @fence_regex ~r/\A\s*```(?:json)?\s*\n(.*?)\n\s*```\s*\z/s

  @doc "Extract tool calls from assistant text. Always returns `{:ok, list}`."
  @spec parse(String.t()) :: {:ok, [ToolCall.t()]}
  def parse(text) when is_binary(text) do
    text = strip_markdown_fence(text)
    {:ok, scan_all(text, 0, [])}
  end

  defp strip_markdown_fence(text) do
    case Regex.run(@fence_regex, text, capture: :all_but_first) do
      [inner] -> String.trim(inner)
      nil -> text
    end
  end

  defp scan_all(text, offset, acc) do
    case find_open_brace(text, offset) do
      nil ->
        Enum.reverse(acc)

      brace_pos ->
        # Slice to the char after `{`; scan_balanced tracks depth from 1.
        after_brace = binary_part(text, brace_pos + 1, byte_size(text) - brace_pos - 1)

        case scan_balanced(after_brace, 1, false, false, 1) do
          {:ok, length} ->
            # length includes the leading `{` (consumed starts at 1).
            candidate = binary_part(text, brace_pos, length)

            case decode_tool_call(candidate) do
              {:ok, tc} -> scan_all(text, brace_pos + length, [tc | acc])
              :skip -> scan_all(text, brace_pos + 1, acc)
            end

          :error ->
            scan_all(text, brace_pos + 1, acc)
        end
    end
  end

  defp find_open_brace(text, offset) when offset < byte_size(text) do
    case :binary.match(text, "{", scope: {offset, byte_size(text) - offset}) do
      {pos, 1} -> pos
      :nomatch -> nil
    end
  end

  defp find_open_brace(_text, _offset), do: nil

  # Slice-and-pass balanced-brace scanner. `rest` is the binary starting at the
  # character after the opening `{` (depth starts at 1, consumed starts at 1).
  # Returns {:ok, total_bytes} where total_bytes includes the leading `{`.
  # Tracks in-string state and backslash escapes to skip braces inside strings.
  defp scan_balanced(<<>>, _depth, _in_string, _escaped, _consumed), do: :error

  defp scan_balanced(<<_ch, rest::binary>>, depth, true, true, consumed) do
    # Previous char was a backslash inside a string: skip this char, clear escape.
    scan_balanced(rest, depth, true, false, consumed + 1)
  end

  defp scan_balanced(<<?\\, rest::binary>>, depth, true, false, consumed) do
    scan_balanced(rest, depth, true, true, consumed + 1)
  end

  defp scan_balanced(<<?", rest::binary>>, depth, true, false, consumed) do
    scan_balanced(rest, depth, false, false, consumed + 1)
  end

  defp scan_balanced(<<_ch, rest::binary>>, depth, true, false, consumed) do
    scan_balanced(rest, depth, true, false, consumed + 1)
  end

  defp scan_balanced(<<?", rest::binary>>, depth, false, false, consumed) do
    scan_balanced(rest, depth, true, false, consumed + 1)
  end

  defp scan_balanced(<<?{, rest::binary>>, depth, false, false, consumed) do
    scan_balanced(rest, depth + 1, false, false, consumed + 1)
  end

  defp scan_balanced(<<?}, _rest::binary>>, 1, false, false, consumed) do
    {:ok, consumed + 1}
  end

  defp scan_balanced(<<?}, rest::binary>>, depth, false, false, consumed) do
    scan_balanced(rest, depth - 1, false, false, consumed + 1)
  end

  defp scan_balanced(<<_ch, rest::binary>>, depth, false, false, consumed) do
    scan_balanced(rest, depth, false, false, consumed + 1)
  end

  defp decode_tool_call(json) do
    with {:ok, map} when is_map(map) <- Jason.decode(json),
         name when is_binary(name) and name != "" <- Map.get(map, "name"),
         {:ok, args} <- extract_arguments(map) do
      {:ok,
       %ToolCall{
         id: Map.get(map, "id") || generate_id(),
         name: name,
         arguments: args
       }}
    else
      _ -> :skip
    end
  end

  defp extract_arguments(%{"arguments" => args}) when is_map(args), do: {:ok, args}
  defp extract_arguments(%{"arguments" => nil}), do: {:ok, %{}}

  defp extract_arguments(%{"arguments" => args}) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp extract_arguments(_map), do: :error

  defp generate_id do
    "call_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  end
end
