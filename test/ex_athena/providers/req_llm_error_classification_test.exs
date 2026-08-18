defmodule ExAthena.Providers.ReqLLMErrorClassificationTest do
  @moduledoc """
  Coverage for the adapter's error-classification contract (issue #155):

    * `to_error/1` — every failure shape req_llm can hand back (HTTP status
      errors, transport exceptions, stream failures, plain terms) maps to a
      canonical `ExAthena.Error` kind with the original reason preserved in
      `raw:`.
    * `context_overflow?/1` — the string sniff that gates the loop's
      compact-and-retry path, exercised against real provider messages.
    * End-to-end through `Adapter.query/2` + Bypass to prove the wire shapes
      req_llm produces actually match what the classifier expects.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Messages.Message
  alias ExAthena.Providers.ReqLLM, as: Adapter
  alias ExAthena.{Error, Request}

  # ── to_error/1: HTTP status classification ────────────────────────

  describe "to_error/1 with HTTP status errors" do
    test "maps statuses to canonical kinds and preserves the raw reason" do
      for {status, kind} <- [
            {400, :bad_request},
            {401, :unauthorized},
            {403, :unauthorized},
            {404, :not_found},
            {408, :timeout},
            {413, :context_length_exceeded},
            {429, :rate_limited},
            {500, :server_error},
            {502, :server_error},
            {503, :server_error}
          ] do
        raw =
          ReqLLM.Error.API.Request.exception(
            reason: "HTTP Error #{status}",
            status: status,
            response_body: ~s({"error":{"message":"nope"}})
          )

        assert %Error{} = error = Adapter.to_error(raw)

        assert error.kind == kind,
               "expected #{status} -> #{inspect(kind)}, got #{inspect(error.kind)}"

        assert error.status == status
        assert error.provider == :req_llm
        assert error.raw == raw
      end
    end

    test "a 400 whose body sniffs as context overflow wins over the status mapping" do
      raw =
        ReqLLM.Error.API.Request.exception(
          reason:
            "This model's maximum context length is 8192 tokens. " <>
              "However, your messages resulted in 9100 tokens.",
          status: 400,
          response_body:
            ~s({"error":{"message":"This model's maximum context length is 8192 tokens."}})
        )

      assert %Error{kind: :context_length_exceeded, status: 400} = Adapter.to_error(raw)
    end
  end

  # ── to_error/1: transport-level failures ──────────────────────────

  describe "to_error/1 with transport-level failures" do
    test "req_llm-wrapped transport timeouts classify as :timeout" do
      raw =
        ReqLLM.Error.API.Request.exception(
          reason: "timeout",
          status: nil,
          cause: %Req.TransportError{reason: :timeout}
        )

      assert %Error{kind: :timeout, status: nil, raw: ^raw} = Adapter.to_error(raw)
    end

    test "req_llm-wrapped connection failures classify as :transport" do
      for reason <- [:econnrefused, :closed, :nxdomain, {:tls_alert, :handshake_failure}] do
        raw =
          ReqLLM.Error.API.Request.exception(
            reason: "connection failed",
            status: nil,
            cause: %Req.TransportError{reason: reason}
          )

        assert %Error{kind: :transport} = Adapter.to_error(raw),
               "expected :transport for cause #{inspect(reason)}"
      end
    end

    test "bare Req.TransportError classifies by its reason" do
      assert %Error{kind: :timeout} = Adapter.to_error(%Req.TransportError{reason: :timeout})
      assert %Error{kind: :transport} = Adapter.to_error(%Req.TransportError{reason: :closed})
    end

    test "Mint.TransportError (stream rescue path) classifies by its reason" do
      assert %Error{kind: :timeout} = Adapter.to_error(%Mint.TransportError{reason: :timeout})

      assert %Error{kind: :transport} =
               Adapter.to_error(%Mint.TransportError{reason: :econnrefused})
    end

    test "Finch.Error (stream rescue path) classifies as :transport" do
      assert %Error{kind: :transport} = Adapter.to_error(%Finch.Error{reason: :disconnected})
    end

    test "Finch.TransportError (observed wire shape from req_llm) classifies by reason" do
      # This is what req_llm actually wraps as API.Request.cause for a
      # refused connection — verified end-to-end below via Bypass.down/1.
      timeout = %Finch.TransportError{reason: :timeout, source: nil}
      refused = %Finch.TransportError{reason: :econnrefused, source: nil}

      assert %Error{kind: :timeout} = Adapter.to_error(timeout)
      assert %Error{kind: :transport} = Adapter.to_error(refused)

      wrapped =
        ReqLLM.Error.API.Request.exception(
          reason: "connection refused",
          status: nil,
          cause: refused
        )

      assert %Error{kind: :transport} = Adapter.to_error(wrapped)
    end

    test "stream failures classify as :transport, unwrapping a transport cause" do
      stream_err = ReqLLM.Error.API.Stream.exception(reason: "stream interrupted")
      assert %Error{kind: :transport} = Adapter.to_error(stream_err)

      timeout_stream =
        ReqLLM.Error.API.Stream.exception(
          reason: "stream interrupted",
          cause: %Mint.TransportError{reason: :timeout}
        )

      assert %Error{kind: :timeout} = Adapter.to_error(timeout_stream)
    end

    test "unknown exceptions fall back to :server_error with the exception message" do
      error = Adapter.to_error(%RuntimeError{message: "boom"})
      assert %Error{kind: :server_error, message: "boom"} = error
      assert error.raw == %RuntimeError{message: "boom"}
    end

    test "plain terms fall back to :server_error preserving the term in raw:" do
      error = Adapter.to_error({:unexpected, 42})
      assert %Error{kind: :server_error, raw: {:unexpected, 42}} = error
      assert error.message == inspect({:unexpected, 42})
    end

    test "messages come from Exception.message/1, not inspect/1 prose" do
      raw =
        ReqLLM.Error.API.Request.exception(
          reason: "Rate Limited - Too many requests",
          status: 429
        )

      error = Adapter.to_error(raw)
      assert error.message == Exception.message(raw)
      refute error.message =~ "%ReqLLM"
    end
  end

  # ── context_overflow?/1: real provider message corpus ─────────────

  describe "context_overflow?/1 corpus" do
    test "recognizes real overflow messages from supported providers" do
      corpus = [
        # OpenAI / vLLM / most OpenAI-compatible servers
        "This model's maximum context length is 128000 tokens. However, your messages resulted in 131072 tokens. Please reduce the length of the messages.",
        # Anthropic
        "prompt is too long: 210145 tokens > 200000 maximum",
        # OpenRouter passthrough
        "This endpoint's maximum context length is 131072 tokens. However, you requested about 140000 tokens.",
        # Ollama / llama.cpp variants
        "the prompt exceeds the context window size",
        # exo / MLX-style servers
        "Error: too many tokens for model",
        # snake_case API error codes
        ~s({"error":{"code":"context_length_exceeded","message":"Reduce input."}}),
        # generic phrasing several local servers use
        "requested tokens exceeds the context length"
      ]

      for message <- corpus do
        raw = ReqLLM.Error.API.Request.exception(reason: message, status: 400)
        assert Adapter.context_overflow?(raw), "expected overflow for: #{message}"
      end
    end

    test "recognizes llama.cpp's 'exceeds the available context size' phrasing" do
      raw =
        ReqLLM.Error.API.Request.exception(
          reason:
            "the request exceeds the available context size. try increasing the context size or enable context shift",
          status: 500
        )

      assert Adapter.context_overflow?(raw)
    end

    test "finds the phrase even when buried past inspect's default truncation" do
      # Regression: the sniff used inspect(raw, limit: 2_000), whose
      # printable_limit truncated large payloads before the matching phrase.
      filler = String.duplicate("irrelevant filler text ", 2_000)

      raw =
        ReqLLM.Error.API.Request.exception(
          reason: "Bad Request",
          status: 400,
          response_body: filler <> "This model's maximum context length is 8192 tokens."
        )

      assert Adapter.context_overflow?(raw)
    end

    test "does not sniff the request body — prompts legitimately mention context windows" do
      # A prompt discussing "context window" must not turn an unrelated
      # server error into :context_length_exceeded.
      raw =
        ReqLLM.Error.API.Request.exception(
          reason: "Internal server error",
          status: 500,
          response_body: ~s({"error":{"message":"Internal server error"}}),
          request_body: ~s({"messages":[{"role":"user","content":"explain the context window"}]})
        )

      refute Adapter.context_overflow?(raw)
      assert %Error{kind: :server_error} = Adapter.to_error(raw)
    end

    test "does not classify unrelated provider errors as overflow" do
      for message <- [
            "Rate limit exceeded. Please retry shortly.",
            "Invalid API key provided.",
            "The model `gpt-nope` does not exist",
            "Internal server error",
            "insufficient quota for this request"
          ] do
        raw = ReqLLM.Error.API.Request.exception(reason: message, status: 400)
        refute Adapter.context_overflow?(raw), "false positive for: #{message}"
      end
    end
  end

  # ── End-to-end via Bypass: what req_llm actually hands the adapter ──

  describe "query/2 error classification end-to-end" do
    setup do
      bypass = Bypass.open()

      request = %Request{
        messages: [%Message{role: :user, content: "hi"}],
        model: "test-model",
        timeout_ms: 5_000
      }

      opts = [
        req_llm_provider_tag: "openai",
        base_url: "http://localhost:#{bypass.port}",
        api_key: "test-key"
      ]

      {:ok, bypass: bypass, request: request, opts: opts}
    end

    test "HTTP error statuses map to canonical kinds", %{
      bypass: bypass,
      request: request,
      opts: opts
    } do
      # 429 excluded here: req_llm retries it internally (covered separately).
      for {status, kind} <- [
            {400, :bad_request},
            {401, :unauthorized},
            {403, :unauthorized},
            {404, :not_found},
            {408, :timeout},
            {413, :context_length_exceeded},
            {500, :server_error},
            {503, :server_error}
          ] do
        Bypass.expect(bypass, "POST", "/chat/completions", fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(status, ~s({"error":{"message":"boom"}}))
        end)

        assert {:error, %Error{} = error} = Adapter.query(request, opts)

        assert error.kind == kind,
               "expected #{status} -> #{inspect(kind)}, got #{inspect(error.kind)}"

        assert error.status == status
        assert error.provider == :req_llm
        refute is_nil(error.raw)
      end
    end

    test "a refused connection classifies as :transport", %{
      bypass: bypass,
      request: request,
      opts: opts
    } do
      Bypass.down(bypass)

      assert {:error, %Error{kind: :transport, status: nil} = error} =
               Adapter.query(request, opts)

      refute is_nil(error.raw)
    end

    test "a 400 with an overflow body classifies as :context_length_exceeded", %{
      bypass: bypass,
      request: request,
      opts: opts
    } do
      Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
        body =
          ~s({"error":{"message":"This model's maximum context length is 8192 tokens. However, your messages resulted in 9100 tokens."}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, body)
      end)

      assert {:error, %Error{kind: :context_length_exceeded, status: 400}} =
               Adapter.query(request, opts)
    end
  end
end
