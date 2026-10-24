defmodule ExAthena.Providers.ReqLLMGeminiTest do
  @moduledoc """
  The `:gemini` provider against a local stub of Google's generateContent API
  (issue 283): structured output, key placement, a missing key, safety blocks
  and what the adapter logs. Request and response shapes follow Google's
  reference at https://ai.google.dev/api/generate-content.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias ExAthena.{Error, StructuredOutput}

  @model "gemini-flash-lite-latest"
  @key "test-gemini-key-283"

  @ok_body ~s({"candidates":[{"content":{"role":"model","parts":[{"text":"{\\"pick\\":\\"tea\\",\\"note\\":null}"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":5,"totalTokenCount":8}})

  @schema %{
    "type" => "object",
    "properties" => %{
      "pick" => %{"type" => "string", "enum" => ["tea", "coffee"]},
      "note" => %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}
    },
    "required" => ["pick", "note"]
  }

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

  # Records each request the stub receives (query string, headers, decoded
  # body) and answers with `body` at `status`.
  defp stub_generate(bypass, model \\ @model, body \\ @ok_body, status \\ 200) do
    test = self()

    Bypass.stub(bypass, "POST", "/v1beta/models/#{model}:generateContent", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:generate, conn.query_string, conn.req_headers, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, body)
    end)
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

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  defp query_params(query_string), do: URI.decode_query(query_string)

  describe "structured output" do
    for model <- ["gemini-flash-lite-latest", "gemini-2.5-flash"] do
      test "sends the schema as responseJsonSchema and returns the decoded map on #{model}",
           ctx do
        stub_generate(ctx.bypass, unquote(model))

        assert {:ok, %{"pick" => "tea", "note" => nil}} =
                 StructuredOutput.request("tea or coffee?", @schema,
                   provider: :gemini,
                   model: unquote(model),
                   api_key: @key,
                   base_url: ctx.base_url
                 )

        assert_received {:generate, _query, _headers, body}
        config = body["generationConfig"]
        assert config["responseMimeType"] == "application/json"
        assert config["responseJsonSchema"] == @schema
        refute Map.has_key?(config, "responseSchema")
      end
    end

    test "plain JSON mode sends the MIME type and no schema", ctx do
      stub_generate(ctx.bypass)

      assert {:ok, %{"pick" => "tea"}} = StructuredOutput.request("pick", "json", opts(ctx))

      assert_received {:generate, _query, _headers, body}
      assert body["generationConfig"]["responseMimeType"] == "application/json"
      refute Map.has_key?(body["generationConfig"], "responseJsonSchema")
    end

    test "a blocked structured request returns :content_filter, not :invalid_json", ctx do
      stub_generate(ctx.bypass, @model, ~s({"promptFeedback":{"blockReason":"SAFETY"}}))

      assert {:error, :content_filter} = StructuredOutput.request("pick", @schema, opts(ctx))
    end

    test "an unknown response_format is refused before any request", ctx do
      stub_generate(ctx.bypass)

      assert {:error, %Error{kind: :bad_request}} =
               ExAthena.query("pick", opts(ctx, response_format: %{type: "xml"}))

      refute_received {:generate, _, _, _}
    end

    test "a stream asking for a JSON shape is refused before any request", ctx do
      stub_stream(ctx.bypass, [@ok_body])

      assert {:error, %Error{kind: :bad_request, message: message}} =
               ExAthena.stream(
                 "pick",
                 fn _ -> :ok end,
                 opts(ctx, response_format: %{type: "json_object"})
               )

      assert message =~ "query"
      refute_received {:stream, _, _}
    end
  end

  describe "API key" do
    test "a query sends the key in the x-goog-api-key header and never in the URL", ctx do
      stub_generate(ctx.bypass)

      assert {:ok, %ExAthena.Response{text: text}} = ExAthena.query("hi", opts(ctx))
      assert text =~ "tea"

      assert_received {:generate, query, headers, _body}
      assert header(headers, "x-goog-api-key") == @key
      refute Map.has_key?(query_params(query), "key")
      refute query =~ @key
    end

    test "a stream sends the key in the x-goog-api-key header and never in the URL", ctx do
      stub_stream(ctx.bypass, [@ok_body])

      assert {:ok, %ExAthena.Response{text: text}} =
               ExAthena.stream("hi", fn _ -> :ok end, opts(ctx))

      assert text =~ "tea"
      assert_received {:stream, query, headers}
      assert header(headers, "x-goog-api-key") == @key
      refute Map.has_key?(query_params(query), "key")
      refute query =~ @key
    end

    test "an embedding sends the key in the x-goog-api-key header and never in the URL", ctx do
      test = self()

      Bypass.stub(
        ctx.bypass,
        "POST",
        "/v1beta/models/gemini-embedding-001:embedContent",
        fn conn ->
          send(test, {:embed, conn.query_string, conn.req_headers})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, ~s({"embedding":{"values":[0.5,0.25]}}))
        end
      )

      assert {:ok, %ExAthena.Embedding{embeddings: [[0.5, 0.25]]}} =
               ExAthena.embed("hi", opts(ctx, model: "gemini-embedding-001"))

      assert_received {:embed, query, headers}
      assert header(headers, "x-goog-api-key") == @key
      refute query =~ @key
    end

    test "a batch embedding keeps the input order and sends the key in the header", ctx do
      test = self()

      Bypass.stub(
        ctx.bypass,
        "POST",
        "/v1beta/models/gemini-embedding-001:batchEmbedContents",
        fn conn ->
          send(test, {:embed, conn.query_string, conn.req_headers})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, ~s({"embeddings":[{"values":[1.0]},{"values":[2.0]}]}))
        end
      )

      assert {:ok, %ExAthena.Embedding{embeddings: [[1.0], [2.0]]}} =
               ExAthena.embed(["a", "b"], opts(ctx, model: "gemini-embedding-001"))

      assert_received {:embed, query, headers}
      assert header(headers, "x-goog-api-key") == @key
      refute query =~ @key
    end

    test "a model written as id@google takes the same header path", ctx do
      stub_generate(ctx.bypass, "gemini-2.5-flash")

      assert {:ok, _} =
               ExAthena.query("hi",
                 provider: :req_llm,
                 model: "gemini-2.5-flash@google",
                 api_key: @key,
                 base_url: ctx.base_url
               )

      assert_received {:generate, query, headers, _body}
      assert header(headers, "x-goog-api-key") == @key
      refute query =~ @key
    end

    test "a redirect is not followed, so the key never reaches another host", ctx do
      other = Bypass.open()
      test = self()

      Bypass.stub(other, "POST", "/steal", fn conn ->
        send(test, {:stolen, header(conn.req_headers, "x-goog-api-key")})
        Plug.Conn.resp(conn, 200, @ok_body)
      end)

      Bypass.stub(ctx.bypass, "POST", "/v1beta/models/#{@model}:generateContent", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://localhost:#{other.port}/steal")
        |> Plug.Conn.resp(307, "")
      end)

      Bypass.stub(
        ctx.bypass,
        "POST",
        "/v1beta/models/gemini-embedding-001:embedContent",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "http://localhost:#{other.port}/steal")
          |> Plug.Conn.resp(308, "")
        end
      )

      assert {:error, %Error{}} = ExAthena.query("hi", opts(ctx))

      assert {:error, %Error{}} =
               ExAthena.embed("hi", opts(ctx, model: "gemini-embedding-001"))

      refute_received {:stolen, _}
    end

    test "provider_options that are neither a list nor a map are refused", ctx do
      stub_generate(ctx.bypass)

      assert {:error, %Error{kind: :bad_request}} =
               ExAthena.query("hi", opts(ctx, provider_opts: [provider_options: "nope"]))

      refute_received {:generate, _, _, _}
    end

    test "provider_options given as a map still get the header", ctx do
      stub_generate(ctx.bypass)

      assert {:ok, _} =
               ExAthena.query(
                 "hi",
                 opts(ctx, provider_opts: [provider_options: %{google_auth_header: false}])
               )

      assert_received {:generate, query, headers, _body}
      assert header(headers, "x-goog-api-key") == @key
      refute query =~ @key
    end

    test "a caller's google_auth_header: false does not put the key back in the URL", ctx do
      stub_generate(ctx.bypass)

      assert {:ok, _} =
               ExAthena.query(
                 "hi",
                 opts(ctx, provider_opts: [provider_options: [google_auth_header: false]])
               )

      assert_received {:generate, query, headers, _body}
      assert header(headers, "x-goog-api-key") == @key
      refute query =~ @key
    end
  end

  describe "missing API key" do
    setup do
      previous = System.get_env("GOOGLE_API_KEY")
      System.put_env("GOOGLE_API_KEY", "key-from-the-environment")

      on_exit(fn ->
        if previous,
          do: System.put_env("GOOGLE_API_KEY", previous),
          else: System.delete_env("GOOGLE_API_KEY")
      end)
    end

    for {label, key} <- [{"nil", nil}, {"empty", ""}] do
      test "a query with a #{label} key returns :unauthorized and sends nothing", ctx do
        stub_generate(ctx.bypass)

        assert {:error, %Error{kind: :unauthorized, message: message}} =
                 ExAthena.query("hi", opts(ctx, api_key: unquote(key)))

        assert message =~ "api_key"
        refute_received {:generate, _, _, _}
      end

      test "an embedding with a #{label} key returns :unauthorized and sends nothing", ctx do
        test = self()

        Bypass.stub(
          ctx.bypass,
          "POST",
          "/v1beta/models/gemini-embedding-001:embedContent",
          fn conn ->
            send(test, :embed_sent)
            Plug.Conn.resp(conn, 200, ~s({"embedding":{"values":[1.0]}}))
          end
        )

        assert {:error, %Error{kind: :unauthorized}} =
                 ExAthena.embed(
                   "hi",
                   opts(ctx, model: "gemini-embedding-001", api_key: unquote(key))
                 )

        refute_received :embed_sent
      end

      test "an id@google model with a #{label} key returns :unauthorized and sends nothing",
           ctx do
        stub_generate(ctx.bypass, "gemini-2.5-flash")

        assert {:error, %Error{kind: :unauthorized}} =
                 ExAthena.query("hi",
                   provider: :req_llm,
                   model: "gemini-2.5-flash@google",
                   api_key: unquote(key),
                   base_url: ctx.base_url
                 )

        refute_received {:generate, _, _, _}
      end

      test "a stream with a #{label} key returns :unauthorized and sends nothing", ctx do
        stub_stream(ctx.bypass, [@ok_body])

        assert {:error, %Error{kind: :unauthorized}} =
                 ExAthena.stream("hi", fn _ -> :ok end, opts(ctx, api_key: unquote(key)))

        refute_received {:stream, _, _}
      end
    end
  end

  describe "safety blocks" do
    for {label, body} <- [
          {"a blocked prompt", ~s({"promptFeedback":{"blockReason":"SAFETY"}})},
          {"a prohibited prompt", ~s({"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"}})},
          {"an empty SAFETY candidate", ~s({"candidates":[{"finishReason":"SAFETY"}]})},
          {"a SAFETY candidate with text",
           ~s({"candidates":[{"content":{"parts":[{"text":"par"}]},"finishReason":"SAFETY"}]})},
          {"a BLOCKLIST candidate",
           ~s({"candidates":[{"content":{"parts":[{"text":"x"}]},"finishReason":"BLOCKLIST"}]})}
        ] do
      test "#{label} on a query reports :content_filter", ctx do
        stub_generate(ctx.bypass, @model, unquote(body))

        assert {:ok, %ExAthena.Response{finish_reason: :content_filter}} =
                 ExAthena.query("hi", opts(ctx))
      end
    end

    test "a normal answer on a query still reports :stop", ctx do
      stub_generate(ctx.bypass)
      assert {:ok, %ExAthena.Response{finish_reason: :stop}} = ExAthena.query("hi", opts(ctx))
    end

    test "an empty SAFETY candidate on a stream reports :content_filter", ctx do
      stub_stream(ctx.bypass, [~s({"candidates":[{"finishReason":"SAFETY"}]})])

      assert {:ok, %ExAthena.Response{finish_reason: :content_filter, text: ""}} =
               ExAthena.stream("hi", fn _ -> :ok end, opts(ctx))
    end

    test "a blocked prompt on a stream reports :content_filter", ctx do
      stub_stream(ctx.bypass, [
        ~s({"promptFeedback":{"blockReason":"SAFETY"},"usageMetadata":{"promptTokenCount":3,"totalTokenCount":3}})
      ])

      assert {:ok, %ExAthena.Response{finish_reason: :content_filter, text: ""}} =
               ExAthena.stream("hi", fn _ -> :ok end, opts(ctx))
    end
  end

  describe "body logging" do
    @user_sentinel "USER-TEXT-SENTINEL-283"
    @body_sentinel "GOOGLE-BODY-SENTINEL-283"

    defp error_body,
      do: ~s({"error":{"code":400,"message":"#{@body_sentinel}","status":"INVALID_ARGUMENT"}})

    test "with log_bodies: false a failed query logs no body and no user text", ctx do
      stub_generate(ctx.bypass, @model, error_body(), 400)

      log =
        capture_log([level: :debug], fn ->
          assert {:error, %Error{kind: :bad_request}} =
                   ExAthena.query(@user_sentinel, opts(ctx, log_bodies: false))
        end)

      assert log =~ "←error"
      refute log =~ @body_sentinel
      refute log =~ @user_sentinel
    end

    # req_llm's stream module logs the failed body itself, outside ex_athena;
    # guides/gemini.md tells hosts to raise that module's level, as here.
    test "with log_bodies: false and req_llm's stream log raised, a failed stream logs no body",
         ctx do
      stub_stream(ctx.bypass, [error_body()], 400)
      Logger.put_module_level(ReqLLM.Streaming.Failure, :error)
      on_exit(fn -> Logger.delete_module_level(ReqLLM.Streaming.Failure) end)

      log =
        capture_log([level: :debug], fn ->
          assert {:error, %Error{kind: :bad_request}} =
                   ExAthena.stream(@user_sentinel, fn _ -> :ok end, opts(ctx, log_bodies: false))
        end)

      refute log =~ @body_sentinel
      refute log =~ @user_sentinel
    end

    test "with log_bodies: false a successful query logs no message or reply text", ctx do
      stub_generate(ctx.bypass)

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, _} =
                   ExAthena.query(@user_sentinel,
                     provider: :gemini,
                     model: @model,
                     api_key: @key,
                     base_url: ctx.base_url,
                     system_prompt: "SYSTEM-SENTINEL-283",
                     log_bodies: false
                   )
        end)

      assert log =~ "←done"
      refute log =~ @user_sentinel
      refute log =~ "SYSTEM-SENTINEL-283"
      refute log =~ "tea"
    end

    test "with log_bodies: false a successful stream logs no text, thought or tool arguments",
         ctx do
      stub_stream(ctx.bypass, [
        ~s({"candidates":[{"content":{"role":"model","parts":[{"text":"THOUGHT-SENTINEL-283","thought":true}]}}]}),
        ~s({"candidates":[{"content":{"role":"model","parts":[{"text":"REPLY-SENTINEL-283"}]}}]}),
        ~s({"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"lookup","args":{"q":"ARGS-SENTINEL-283"}}}]},"finishReason":"STOP"}]})
      ])

      stream_opts = [
        provider: :gemini,
        model: @model,
        api_key: @key,
        base_url: ctx.base_url
      ]

      quiet =
        capture_log([level: :debug], fn ->
          assert {:ok, %ExAthena.Response{text: "REPLY-SENTINEL-283", tool_calls: [_]}} =
                   ExAthena.stream(
                     @user_sentinel,
                     fn _ -> :ok end,
                     [log_bodies: false] ++ stream_opts
                   )
        end)

      loud =
        capture_log([level: :debug], fn ->
          ExAthena.stream(@user_sentinel, fn _ -> :ok end, stream_opts)
        end)

      for sentinel <- [
            @user_sentinel,
            "THOUGHT-SENTINEL-283",
            "REPLY-SENTINEL-283",
            "ARGS-SENTINEL-283"
          ] do
        refute quiet =~ sentinel
        assert loud =~ sentinel
      end
    end

    test "with log_bodies: false a failed embedding logs no body", ctx do
      Bypass.stub(
        ctx.bypass,
        "POST",
        "/v1beta/models/gemini-embedding-001:embedContent",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(400, error_body())
        end
      )

      log =
        capture_log([level: :debug], fn ->
          assert {:error, %Error{kind: :bad_request}} =
                   ExAthena.embed(
                     "hi",
                     opts(ctx, model: "gemini-embedding-001", log_bodies: false)
                   )
        end)

      assert log =~ "←error"
      refute log =~ @body_sentinel
    end

    test "by default the debug log still carries the text, so the refutes above can fail",
         ctx do
      stub_generate(ctx.bypass, @model, error_body(), 400)

      log =
        capture_log([level: :debug], fn -> ExAthena.query(@user_sentinel, opts(ctx)) end)

      assert log =~ @user_sentinel
      assert log =~ @body_sentinel
    end
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

  describe "replies outside Google's documented shapes" do
    for body <- [
          ~s({"candidates":"x"}),
          ~s([1,2]),
          ~s({"candidates":[{"content":{"parts":"x"}}]})
        ] do
      test "a query answered with #{body} returns an error instead of raising", ctx do
        stub_generate(ctx.bypass, @model, unquote(body))
        assert {:error, %Error{kind: :server_error}} = ExAthena.query("hi", opts(ctx))
      end
    end

    for {label, body} <- [
          {"fewer vectors than inputs", ~s({"embeddings":[{"values":[1.0]}]})},
          {"an empty vector", ~s({"embeddings":[{"values":[1.0]},{"values":[]}]})}
        ] do
      test "a batch embedding answered with #{label} is an error", ctx do
        Bypass.stub(
          ctx.bypass,
          "POST",
          "/v1beta/models/gemini-embedding-001:batchEmbedContents",
          fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(200, unquote(body))
          end
        )

        assert {:error, %Error{kind: :server_error}} =
                 ExAthena.embed(["a", "b"], opts(ctx, model: "gemini-embedding-001"))
      end
    end
  end

  describe "failures that already hold" do
    test "a 503 is one request, with no retry", ctx do
      counter = :counters.new(1, [])

      Bypass.stub(ctx.bypass, "POST", "/v1beta/models/#{@model}:generateContent", fn conn ->
        :counters.add(counter, 1, 1)
        Plug.Conn.resp(conn, 503, ~s({"error":{"code":503,"status":"UNAVAILABLE"}}))
      end)

      assert {:error, %Error{kind: :server_error, status: 503}} =
               ExAthena.query("hi", opts(ctx))

      assert :counters.get(counter, 1) == 1
    end

    test "a server that never answers in time is :timeout" do
      # A socket that accepts the connection (via the backlog) and never
      # replies, so the call waits out its receive timeout.
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listen)
      on_exit(fn -> :gen_tcp.close(listen) end)

      assert {:error, %Error{kind: :timeout}} =
               ExAthena.query("hi",
                 provider: :gemini,
                 model: @model,
                 api_key: @key,
                 base_url: "http://localhost:#{port}/v1beta",
                 timeout_ms: 100
               )
    end

    test "a refused connection is :transport", ctx do
      Bypass.down(ctx.bypass)
      assert {:error, %Error{kind: :transport}} = ExAthena.query("hi", opts(ctx))
    end
  end
end
