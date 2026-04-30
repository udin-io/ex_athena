defmodule ExAthena.Providers.ReqLLMTest do
  use ExUnit.Case, async: true

  alias ExAthena.Config
  alias ExAthena.Providers.ReqLLM, as: Adapter

  describe "capabilities/0" do
    test "declares streaming + native tool-calls + json mode" do
      caps = Adapter.capabilities()
      assert caps.streaming
      assert caps.native_tool_calls
      assert caps.json_mode
    end
  end

  describe "Config resolves builtin provider atoms to the ReqLLM adapter" do
    test ":ollama, :openai*, :llamacpp, :claude, :anthropic all route here" do
      for atom <- [:ollama, :openai, :openai_compatible, :llamacpp, :claude, :anthropic, :req_llm] do
        assert Config.provider_module(atom) == Adapter,
               "expected provider atom #{inspect(atom)} to resolve to ReqLLM adapter"
      end
    end

    test ":mock stays on the Mock provider" do
      assert Config.provider_module(:mock) == ExAthena.Providers.Mock
    end
  end

  describe "Config threads the req_llm provider tag into opts" do
    test ":ollama uses the openai tag (Ollama is OpenAI-compatible)" do
      {_mod, opts} = Config.pop_provider!(provider: :ollama)
      assert Keyword.get(opts, :req_llm_provider_tag) == "openai"
    end

    test ":ollama threads openai_compatible_backend so missing API keys are tolerated" do
      {_mod, opts} = Config.pop_provider!(provider: :ollama)
      assert Keyword.get(opts, :openai_compatible_backend) == :ollama
    end

    test ":llamacpp uses the openai tag (llama.cpp is OpenAI-compatible)" do
      {_mod, opts} = Config.pop_provider!(provider: :llamacpp)
      assert Keyword.get(opts, :req_llm_provider_tag) == "openai"
    end

    test ":claude translates to anthropic tag" do
      {_mod, opts} = Config.pop_provider!(provider: :claude)
      assert Keyword.get(opts, :req_llm_provider_tag) == "anthropic"
    end

    test ":openai_compatible uses openai tag" do
      {_mod, opts} = Config.pop_provider!(provider: :openai_compatible)
      assert Keyword.get(opts, :req_llm_provider_tag) == "openai"
    end

    test ":openai_compatible does NOT inject the ollama backend marker" do
      {_mod, opts} = Config.pop_provider!(provider: :openai_compatible)
      refute Keyword.has_key?(opts, :openai_compatible_backend)
    end

    test ":mock has no tag" do
      {_mod, opts} = Config.pop_provider!(provider: :mock)
      refute Keyword.has_key?(opts, :req_llm_provider_tag)
    end
  end

  describe "resolve_model/2 prefixes the provider tag correctly" do
    alias ExAthena.Request

    test "prepends tag to bare model id" do
      assert Adapter.resolve_model(%Request{messages: [], model: "gpt-4"}, req_llm_provider_tag: "openai") ==
               {:ok, "openai:gpt-4"}
    end

    test "prepends tag even when model id contains a colon (Ollama version separator)" do
      # Regression: Ollama model ids use `:` as the version separator
      # (`qwen2.5-coder:14b`). The previous heuristic treated the colon as
      # "already tagged" and shipped the bare name to req_llm, which then
      # parsed `qwen2.5-coder` as a provider name and failed validation
      # with `{:error, :bad_provider}` because of the `.`.
      assert Adapter.resolve_model(
               %Request{messages: [], model: "qwen2.5-coder:14b"},
               req_llm_provider_tag: "openai"
             ) == {:ok, "openai:qwen2.5-coder:14b"}

      assert Adapter.resolve_model(
               %Request{messages: [], model: "qwen3-coder:30b"},
               req_llm_provider_tag: "openai"
             ) == {:ok, "openai:qwen3-coder:30b"}
    end

    test "does not double-prefix when model already starts with the tag" do
      assert Adapter.resolve_model(
               %Request{messages: [], model: "openai:gpt-4"},
               req_llm_provider_tag: "openai"
             ) == {:ok, "openai:gpt-4"}

      assert Adapter.resolve_model(
               %Request{messages: [], model: "openai:qwen2.5-coder:14b"},
               req_llm_provider_tag: "openai"
             ) == {:ok, "openai:qwen2.5-coder:14b"}
    end

    test "passes the model through unchanged when no tag is set" do
      assert Adapter.resolve_model(%Request{messages: [], model: "qwen2.5-coder:14b"}, []) ==
               {:ok, "qwen2.5-coder:14b"}
    end

    test "falls back to opts[:model] when the request has no model and prefixes the tag" do
      assert Adapter.resolve_model(
               %Request{messages: [], model: nil},
               model: "qwen2.5-coder:14b",
               req_llm_provider_tag: "openai"
             ) == {:ok, "openai:qwen2.5-coder:14b"}
    end

    test "errors when no model is supplied anywhere" do
      assert {:error, %ExAthena.Error{kind: :bad_request, message: "no model configured"}} =
               Adapter.resolve_model(%Request{messages: [], model: nil}, [])
    end
  end
end
