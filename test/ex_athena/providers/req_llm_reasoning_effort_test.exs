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
end
