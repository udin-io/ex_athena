defmodule ExAthena.Lsp.Framing do
  @moduledoc """
  Pure decoder for LSP's `Content-Length`-prefixed JSON-RPC framing.

  The wire format is:

      Content-Length: <N>\\r\\n
      [Content-Type: ...]\\r\\n
      \\r\\n
      <N bytes of JSON>

  `parse/1` returns all complete frame bodies found in the buffer (as raw
  binaries — callers are responsible for `Jason.decode!/1`) and the
  unconsumed tail. Garbage bytes before the first `Content-Length:` token
  are dropped with a warning; this keeps the stream live if the server
  emits a startup banner before its first LSP frame.
  """

  require Logger

  @doc """
  Parse one or more LSP frames from `buffer`.

  Returns `{bodies, remainder}` where `bodies` is a list of raw JSON
  binaries (in order) and `remainder` is whatever bytes follow the last
  complete frame.
  """
  @spec parse(binary()) :: {[binary()], binary()}
  def parse(buffer) when is_binary(buffer) do
    parse_frames(buffer, [])
  end

  # --- private ---

  defp parse_frames(buf, acc) do
    case find_content_length(buf) do
      :not_found ->
        {Enum.reverse(acc), buf}

      {:ok, length, rest_after_headers} ->
        case rest_after_headers do
          <<body::binary-size(length), remainder::binary>> ->
            parse_frames(remainder, [body | acc])

          _incomplete ->
            {Enum.reverse(acc), buf}
        end

      {:garbage, stripped} ->
        parse_frames(stripped, acc)
    end
  end

  # Scan `buf` for "Content-Length: <n>\r\n" (or LF-only).
  # Returns:
  #   {:ok, length, rest_after_blank_line}
  #   :not_found
  #   {:garbage, buf_starting_at_content_length}
  defp find_content_length(buf) do
    case :binary.match(buf, "Content-Length:") do
      :nomatch ->
        :not_found

      {0, _} ->
        extract_length_and_body(buf)

      {offset, _} ->
        # Bytes before Content-Length are garbage — drop them and warn.
        garbage = binary_part(buf, 0, offset)

        Logger.warning(
          "[ExAthena.Lsp] dropped #{offset} garbage bytes before LSP frame: #{inspect(garbage)}"
        )

        {:garbage, binary_part(buf, offset, byte_size(buf) - offset)}
    end
  end

  defp extract_length_and_body(buf) do
    # Find end of headers — blank line separates headers from body.
    # Support both \r\n\r\n and \n\n separators.
    with {:ok, length, after_first_header} <- parse_content_length_line(buf),
         {:ok, body_start} <- find_header_end(after_first_header) do
      rest =
        binary_part(after_first_header, body_start, byte_size(after_first_header) - body_start)

      {:ok, length, rest}
    else
      _ -> :not_found
    end
  end

  defp parse_content_length_line(buf) do
    # Match "Content-Length: <digits>\r\n" or "Content-Length: <digits>\n"
    case Regex.run(~r/\AContent-Length:\s*(\d+)\r?\n/, buf, return: :index) do
      nil ->
        :error

      [{_start, match_len}, {digits_start, digits_len}] ->
        length = buf |> binary_part(digits_start, digits_len) |> String.to_integer()
        rest = binary_part(buf, match_len, byte_size(buf) - match_len)
        {:ok, length, rest}
    end
  end

  # After the Content-Length header, there may be more headers before the
  # blank line. Skip them and return the offset where the body begins.
  defp find_header_end(buf) do
    cond do
      # Already at blank line
      String.starts_with?(buf, "\r\n") -> {:ok, 2}
      String.starts_with?(buf, "\n") -> {:ok, 1}
      true -> skip_extra_headers(buf)
    end
  end

  defp skip_extra_headers(buf) do
    case Regex.run(~r/\r?\n\r?\n/, buf, return: :index) do
      nil ->
        :error

      [{start, len}] ->
        {:ok, start + len}
    end
  end
end
