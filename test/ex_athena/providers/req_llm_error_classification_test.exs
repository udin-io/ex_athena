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
