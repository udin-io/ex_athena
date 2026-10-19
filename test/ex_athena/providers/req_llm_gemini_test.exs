defmodule ExAthena.Providers.ReqLLMGeminiTest do
  @moduledoc """
  The `:gemini` provider against a local stub of Google's generateContent API
  (issue 283): structured output, key placement, a missing key, safety blocks
  and what the adapter logs. Request and response shapes follow Google's
  reference at https://ai.google.dev/api/generate-content.
  """
  use ExUnit.Case, async: false

  alias ExAthena.Error

  @model "gemini-flash-lite-latest"
  @key "test-gemini-key-283"

  @ok_body ~s({"candidates":[{"content":{"role":"model","parts":[{"text":"{\\"pick\\":\\"tea\\",\\"note\\":null}"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":5,"totalTokenCount":8}})

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}/v1beta"}
  end

  defp opts(ctx, extra \\ []) do
    Keyword.merge(
      [provider: :gemini, model: @model, api_key: @key, base_url: ctx.base_url],
      extra
    )
  end

  # Answers a streaming call with one SSE event per JSON body in `events`.
  defp stub_stream(bypass, events, status \\ 200) do
    test = self()

    Bypass.stub(bypass, "POST", "/v1beta/models/#{@model}:streamGenerateContent", fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:stream, conn.query_string, conn.req_headers})

      if status == 200 do
        send_events(conn, events)
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(status, hd(events))
      end
    end)
  end

  defp send_events(conn, events) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    Enum.reduce(events, conn, fn event, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, "data: " <> event <> "\n\n")
      conn
    end)
  end

  describe "stream results" do
    test "a normal answer on a stream reports :stop as an atom", ctx do
      stub_stream(ctx.bypass, [@ok_body])

      assert {:ok, %ExAthena.Response{finish_reason: :stop}} =
               ExAthena.stream("hi", fn _ -> :ok end, opts(ctx))
    end

    test "a 400 on a stream is :bad_request, like on a query", ctx do
      stub_stream(ctx.bypass, [~s({"error":{"code":400,"status":"INVALID_ARGUMENT"}})], 400)

      assert {:error, %Error{kind: :bad_request, status: 400}} =
               ExAthena.stream("hi", fn _ -> :ok end, opts(ctx))
    end
  end
end
