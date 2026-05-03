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
        case scan_balanced(text, brace_pos) do
          {:ok, end_pos} ->
            candidate = binary_part(text, brace_pos, end_pos - brace_pos)

            case decode_tool_call(candidate) do
              {:ok, tc} -> scan_all(text, end_pos, [tc | acc])
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

  # Scan from the `{` at `brace_pos`; return {:ok, end_pos} (exclusive) or :error.
  # Tracks in-string state and backslash escapes to avoid counting braces inside strings.
  defp scan_balanced(text, brace_pos) do
    scan_loop(text, brace_pos + 1, 1, false, false)
  end

  defp scan_loop(text, pos, depth, in_string, escaped) when pos < byte_size(text) do
    <<_::binary-size(pos), ch, _::binary>> = text

    cond do
      escaped ->
        scan_loop(text, pos + 1, depth, in_string, false)

      in_string and ch == ?\\ ->
        scan_loop(text, pos + 1, depth, true, true)

      in_string and ch == ?" ->
        scan_loop(text, pos + 1, depth, false, false)

      in_string ->
        scan_loop(text, pos + 1, depth, true, false)

      ch == ?" ->
        scan_loop(text, pos + 1, depth, true, false)

      ch == ?{ ->
        scan_loop(text, pos + 1, depth + 1, false, false)

      ch == ?} and depth == 1 ->
        {:ok, pos + 1}

      ch == ?} ->
        scan_loop(text, pos + 1, depth - 1, false, false)

      true ->
        scan_loop(text, pos + 1, depth, false, false)
    end
  end

  defp scan_loop(_text, _pos, _depth, _in_string, _escaped), do: :error

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
