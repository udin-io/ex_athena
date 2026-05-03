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

    test "declares structured_output: true" do
      assert Adapter.capabilities().structured_output == true
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

    test ":llamacpp threads openai_compatible_backend so missing API keys are tolerated" do
      {_mod, opts} = Config.pop_provider!(provider: :llamacpp)
      assert Keyword.get(opts, :openai_compatible_backend) == :llamacpp
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
      assert Adapter.resolve_model(%Request{messages: [], model: "gpt-4"},
               req_llm_provider_tag: "openai"
             ) ==
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

  describe "to_req_llm_tools/1" do
    test "returns nil and [] unchanged" do
      assert Adapter.to_req_llm_tools(nil) == nil
      assert Adapter.to_req_llm_tools([]) == []
    end

    test "passes through %ReqLLM.Tool{} structs unchanged (forward compat)" do
      tool = %ReqLLM.Tool{
        name: "passthrough",
        description: "already a struct",
        parameter_schema: %{},
        callback: fn _ -> {:ok, ""} end
      }

      assert [^tool] = Adapter.to_req_llm_tools([tool])
    end

    test "converts atom-keyed OpenAI-format maps (the modes/react.ex shape) to ReqLLM.Tool" do
      # Regression: req_llm 1.10's openai adapter calls
      # ReqLLM.Tool.to_schema(tool, :openai) on each entry, which only
      # matches %ReqLLM.Tool{}. Previously these maps reached req_llm raw
      # and crashed with "no function clause matching".
      tool_map = %{
        type: "function",
        function: %{
          name: "read",
          description: "Read a file",
          parameters: %{
            type: "object",
            properties: %{path: %{type: "string"}},
            required: ["path"]
          }
        }
      }

      assert [%ReqLLM.Tool{} = tool] = Adapter.to_req_llm_tools([tool_map])
      assert tool.name == "read"
      assert tool.description == "Read a file"
      assert tool.parameter_schema == tool_map.function.parameters
      assert is_function(tool.callback, 1)
    end

    test "also accepts string-keyed OpenAI-format maps" do
      tool_map = %{
        "type" => "function",
        "function" => %{
          "name" => "grep",
          "description" => "Search files",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      }

      assert [%ReqLLM.Tool{} = tool] = Adapter.to_req_llm_tools([tool_map])
      assert tool.name == "grep"
      assert tool.description == "Search files"
    end

    test "the stub callback returns a tagged error so accidental use is loud" do
      tool_map = %{
        type: "function",
        function: %{name: "x", description: "y", parameters: %{}}
      }

      [%ReqLLM.Tool{callback: cb}] = Adapter.to_req_llm_tools([tool_map])
      assert cb.(%{}) == {:error, :tool_execution_handled_by_ex_athena}
    end
  end

  describe "build_opts/2 substitutes a placeholder api_key for backends that ignore auth" do
    alias ExAthena.Request

    test ":ollama backend with no api_key gets the \"ollama\" placeholder" do
      request = %Request{messages: []}
      {:ok, opts} = Adapter.build_opts(request, openai_compatible_backend: :ollama)
      assert Keyword.get(opts, :api_key) == "ollama"
    end

    test ":llamacpp backend with no api_key gets the \"llamacpp\" placeholder" do
      request = %Request{messages: []}
      {:ok, opts} = Adapter.build_opts(request, openai_compatible_backend: :llamacpp)
      assert Keyword.get(opts, :api_key) == "llamacpp"
    end

    test "explicit api_key wins over the placeholder for :llamacpp" do
      request = %Request{messages: []}

      {:ok, opts} =
        Adapter.build_opts(request, openai_compatible_backend: :llamacpp, api_key: "real-key")

      assert Keyword.get(opts, :api_key) == "real-key"
    end

    test "no backend marker means no placeholder substitution" do
      request = %Request{messages: []}
      {:ok, opts} = Adapter.build_opts(request, [])
      refute Keyword.has_key?(opts, :api_key)
    end
  end

  describe "build_opts/2 forwards response_format" do
    alias ExAthena.Request

    test "passes :json atom from request.response_format" do
      request = %Request{messages: [], response_format: :json}
      {:ok, opts} = Adapter.build_opts(request, [])
      assert Keyword.get(opts, :response_format) == :json
    end

    test "passes a schema map from request.response_format" do
      schema = %{type: "json_schema", json_schema: %{name: "r", schema: %{}, strict: true}}
      request = %Request{messages: [], response_format: schema}
      {:ok, opts} = Adapter.build_opts(request, [])
      assert Keyword.get(opts, :response_format) == schema
    end

    test "opts[:response_format] overrides request.response_format" do
      request = %Request{messages: [], response_format: :json}
      schema = %{type: "json_schema", json_schema: %{name: "r", schema: %{}, strict: true}}
      {:ok, opts} = Adapter.build_opts(request, response_format: schema)
      assert Keyword.get(opts, :response_format) == schema
    end

    test "omits response_format key when neither opts nor request sets it" do
      request = %Request{messages: []}
      {:ok, opts} = Adapter.build_opts(request, [])
      refute Keyword.has_key?(opts, :response_format)
    end
  end
end
