defmodule ExAthena.Lsp.FramingTest do
  use ExUnit.Case, async: true

  alias ExAthena.Lsp.Framing

  defp frame(body) when is_binary(body) do
    "Content-Length: #{byte_size(body)}\r\n\r\n#{body}"
  end

  test "decodes a single complete frame" do
    body = ~s({"jsonrpc":"2.0","id":1,"result":null})
    buf = frame(body)
    assert {[^body], ""} = Framing.parse(buf)
  end

  test "decodes two frames in one buffer" do
    b1 = ~s({"jsonrpc":"2.0","id":1,"result":null})
    b2 = ~s({"jsonrpc":"2.0","method":"initialized","params":{}})
    buf = frame(b1) <> frame(b2)
    assert {[^b1, ^b2], ""} = Framing.parse(buf)
  end

  test "returns leftover bytes when frame body is truncated" do
    body = ~s({"jsonrpc":"2.0","id":1,"result":null})
    truncated = frame(body) |> binary_part(0, byte_size(frame(body)) - 3)
    assert {[], leftover} = Framing.parse(truncated)
    assert leftover == truncated
  end

  test "handles extra Content-Type header line" do
    body = ~s({"jsonrpc":"2.0","id":1,"result":"ok"})

    buf =
      "Content-Length: #{byte_size(body)}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n#{body}"

    assert {[^body], ""} = Framing.parse(buf)
  end

  test "handles LF-only line endings" do
    body = ~s({"jsonrpc":"2.0","id":1,"result":"ok"})
    buf = "Content-Length: #{byte_size(body)}\n\n#{body}"
    assert {[^body], ""} = Framing.parse(buf)
  end

  test "returns leftover unchanged when Content-Length header is missing" do
    garbage = "this is not an LSP frame at all"
    assert {[], ^garbage} = Framing.parse(garbage)
  end

  test "drops garbage bytes before a valid frame" do
    body = ~s({"jsonrpc":"2.0","id":1,"result":null})
    garbage_prefix = "some garbage bytes\r\n"
    buf = garbage_prefix <> frame(body)
    {frames, leftover} = Framing.parse(buf)
    assert leftover == ""
    assert frames == [body]
  end

  test "handles empty buffer" do
    assert {[], ""} = Framing.parse("")
  end
end
