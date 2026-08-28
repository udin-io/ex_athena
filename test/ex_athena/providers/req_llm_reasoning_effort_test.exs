defmodule ExAthena.Providers.ReqLLMReasoningEffortTest do
  @moduledoc """
  Qwen3.8 and its peers ship with reasoning turned all the way up (`xhigh`),
  which burns a whole completion budget on circular thinking (#198). The knob
  that turns it down is the `reasoning_effort` field of the chat-completions
  body, so the assertion that matters is what reaches the wire — a value that
  survives into `build_opts/2` but is dropped by the encoder looks configured
  and does nothing.

  `async: false` because the configured-default cases write the `:model` rail
  into application env, which is process-global.
  """
  use ExUnit.Case, async: false

  alias ExAthena.Messages.Message
  alias ExAthena.Providers.ReqLLM, as: Adapter
  alias ExAthena.Request

  setup do
    on_exit(fn -> Application.delete_env(:ex_athena, :model) end)
    :ok
  end

  defp request(fields) do
    struct!(
      %Request{
        messages: [%Message{role: :user, content: "hi"}],
        model: "qwen3.8-27b",
        timeout_ms: 5_000
      },
      fields
    )
  end

  describe "build_opts/2 resolves the effort" do
    test "sends nothing when neither the request nor the rail names one" do
      {:ok, opts} = Adapter.build_opts(request([]), [])
      refute Keyword.has_key?(opts, :reasoning_effort)
    end

    test "forwards the effort the caller set on the request" do
      {:ok, opts} = Adapter.build_opts(request(reasoning_effort: :low), [])
      assert Keyword.get(opts, :reasoning_effort) == :low
    end

    test "falls back to the configured rail so every entry point sends it" do
      Application.put_env(:ex_athena, :model, reasoning_effort: :medium)

      {:ok, opts} = Adapter.build_opts(request([]), [])
      assert Keyword.get(opts, :reasoning_effort) == :medium
    end

    test "the request wins over the configured rail" do
      Application.put_env(:ex_athena, :model, reasoning_effort: :xhigh)

      {:ok, opts} = Adapter.build_opts(request(reasoning_effort: :none), [])
      assert Keyword.get(opts, :reasoning_effort) == :none
    end

    test "accepts a rail written as a string, as a hand-edited config file would" do
      Application.put_env(:ex_athena, :model, reasoning_effort: "high")

      {:ok, opts} = Adapter.build_opts(request([]), [])
      assert Keyword.get(opts, :reasoning_effort) == :high
    end

    # A typo in config, or a level a future model invents, must not take the
    # run down with it — the same degrade-don't-crash contract `ExAthena.Tuning`
    # keeps for every other rail.
    test "drops an unrecognised level instead of failing the run" do
      Application.put_env(:ex_athena, :model, reasoning_effort: :ludicrous)

      {:ok, opts} = Adapter.build_opts(request([]), [])
      refute Keyword.has_key?(opts, :reasoning_effort)
    end

    # `:default` is what the settings modal offers for "leave the model alone".
    # It is not a level, so it must not be sent as one.
    test "sends nothing for the :default sentinel" do
      Application.put_env(:ex_athena, :model, reasoning_effort: :default)

      {:ok, opts} = Adapter.build_opts(request([]), [])
      refute Keyword.has_key?(opts, :reasoning_effort)
    end
  end

  describe "the chosen effort on the wire" do
    setup do
      bypass = Bypass.open()

      opts = [
        openai_compatible_backend: :llamacpp,
        req_llm_provider_tag: "openai",
        base_url: "http://localhost:#{bypass.port}"
      ]

      {:ok, bypass: bypass, opts: opts}
    end

    # Captures the JSON the adapter actually posts and answers with a minimal
    # well-formed completion so response decoding stays out of the way.
    defp capture_body(bypass) do
      test = self()

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:wire_body, Jason.decode!(raw)})

        body =
          Jason.encode!(%{
            "id" => "chatcmpl-1",
            "object" => "chat.completion",
            "created" => 1_700_000_000,
            "model" => "qwen3.8-27b",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{"role" => "assistant", "content" => "ok"},
                "finish_reason" => "stop"
              }
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      fn ->
        assert_receive {:wire_body, wire}, 5_000
        wire
      end
    end

    test "a chosen effort is sent on the chat-completions body",
         %{bypass: bypass, opts: opts} do
      wire = capture_body(bypass)

      assert {:ok, _response} = Adapter.query(request(reasoning_effort: :low), opts)
      assert wire.()["reasoning_effort"] == "low"
    end

    test "nothing is sent when the caller names no effort",
         %{bypass: bypass, opts: opts} do
      wire = capture_body(bypass)

      assert {:ok, _response} = Adapter.query(request([]), opts)
      refute Map.has_key?(wire.(), "reasoning_effort")
    end
  end
end
