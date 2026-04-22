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
    test ":ollama + bare model gets prefixed to ollama:model" do
      {_mod, opts} = Config.pop_provider!(provider: :ollama)
      assert Keyword.get(opts, :req_llm_provider_tag) == "ollama"
    end

    test ":claude translates to anthropic tag" do
      {_mod, opts} = Config.pop_provider!(provider: :claude)
      assert Keyword.get(opts, :req_llm_provider_tag) == "anthropic"
    end

    test ":openai_compatible uses openai tag" do
      {_mod, opts} = Config.pop_provider!(provider: :openai_compatible)
      assert Keyword.get(opts, :req_llm_provider_tag) == "openai"
    end

    test ":mock has no tag" do
      {_mod, opts} = Config.pop_provider!(provider: :mock)
      refute Keyword.has_key?(opts, :req_llm_provider_tag)
    end
  end
end
