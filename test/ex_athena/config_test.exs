defmodule ExAthena.ConfigTest do
  use ExUnit.Case, async: false

  alias ExAthena.Config

  setup do
    on_exit(fn ->
      Application.delete_env(:ex_athena, :default_provider)
      Application.delete_env(:ex_athena, :ollama)
      Application.delete_env(:ex_athena, :openai)
      Application.delete_env(:ex_athena, :openai_compatible)
    end)

    :ok
  end

  describe "pop_provider!/1" do
    test "uses :provider from opts when given" do
      assert {ExAthena.Providers.Mock, []} = Config.pop_provider!(provider: :mock)
    end

    test "falls back to :default_provider from env" do
      Application.put_env(:ex_athena, :default_provider, :mock)
      assert {ExAthena.Providers.Mock, []} = Config.pop_provider!([])
    end

    test "raises when no provider anywhere" do
      Application.put_env(:ex_athena, :default_provider, nil)

      assert_raise ArgumentError, ~r/no :provider passed/, fn ->
        Config.pop_provider!([])
      end
    end

    test "resolves module references directly" do
      assert {ExAthena.Providers.Mock, []} =
               Config.pop_provider!(provider: ExAthena.Providers.Mock)
    end

    test "rejects unknown provider atoms" do
      assert_raise ArgumentError, ~r/unknown provider/, fn ->
        Config.pop_provider!(provider: :nonexistent)
      end
    end
  end

  describe "get/4 tiered resolution" do
    test "per-call wins over provider env wins over top-level wins over default" do
      Application.put_env(:ex_athena, :ollama, model: "env-model")
      Application.put_env(:ex_athena, :model, "top-model")

      # per-call wins
      assert "call-model" =
               Config.get(ExAthena.Providers.ReqLLM, :model,
                 [model: "call-model"],
                 "default"
               )

      # provider env wins over top-level
      assert "env-model" = Config.get(ExAthena.Providers.ReqLLM, :model, [], "default")

      # top-level wins over default when provider env doesn't set it
      Application.delete_env(:ex_athena, :ollama)

      assert "top-model" = Config.get(ExAthena.Providers.ReqLLM, :model, [], "default")

      # default when nothing is set
      Application.delete_env(:ex_athena, :model)

      assert "default" = Config.get(ExAthena.Providers.ReqLLM, :model, [], "default")
    end
  end

  describe "provider_module/1" do
    test "resolves built-in atoms" do
      assert ExAthena.Providers.ReqLLM = Config.provider_module(:ollama)
      assert ExAthena.Providers.ReqLLM = Config.provider_module(:openai)
      assert ExAthena.Providers.ReqLLM = Config.provider_module(:openai_compatible)
      assert ExAthena.Providers.ReqLLM = Config.provider_module(:llamacpp)
      assert ExAthena.Providers.ReqLLM = Config.provider_module(:claude)
      assert ExAthena.Providers.Mock = Config.provider_module(:mock)
    end

    test "accepts modules that implement the behaviour" do
      assert ExAthena.Providers.Mock = Config.provider_module(ExAthena.Providers.Mock)
    end
  end
end
