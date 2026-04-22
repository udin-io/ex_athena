defmodule ExAthena.Providers.ReqLLM do
  @moduledoc """
  Delegating provider that runs requests through the `req_llm` library.

  `req_llm` ships 18+ providers (OpenAI, Anthropic, Ollama, LM Studio,
  OpenRouter, Groq, Together, DeepInfra, Vercel, Mistral, Gemini, Cohere,
  Bedrock, llama.cpp, vLLM, …) with a canonical data model and `models.dev`
  cost/context metadata. ExAthena delegates to it instead of maintaining
  per-provider modules.

  ## Usage

  Callers identify a model via the `req_llm` two-part spec
  (`"provider:model-id"` or a `{provider, model_id}` tuple):

      ExAthena.query("hi",
        provider: :req_llm,
        model: "ollama:llama3.1",
        base_url: "http://localhost:11434"
      )

      ExAthena.query("hi",
        provider: :req_llm,
        model: "anthropic:claude-opus-4-5",
        api_key: System.get_env("ANTHROPIC_API_KEY")
      )

  The provider atoms `:ollama`, `:openai`, `:openai_compatible`, `:llamacpp`,
  `:claude`, `:mock` continue to route here via `ExAthena.Config` and are
  translated to the appropriate `req_llm` model spec.

  ## Capabilities

  Reported statically at `:native_tool_calls / :streaming / :json_mode`
  = true, reflecting req_llm's superset. The loop's auto-fallback handles
  individual-model quirks (e.g. Ollama models without native tool-calls).
  """

  @behaviour ExAthena.Provider

  alias ExAthena.{Error, Request, Response}
  alias ExAthena.Messages.{Message, ToolResult}

  @impl ExAthena.Provider
  def capabilities do
    %{
      native_tool_calls: true,
      streaming: true,
      json_mode: true,
      max_tokens: 200_000,
      supports_resume: false,
      supports_system_prompt: true,
      supports_temperature: true
    }
  end

  @impl ExAthena.Provider
  def query(%Request{} = request, opts) do
    with {:ok, model_spec} <- resolve_model(request, opts),
         {:ok, messages} <- build_messages(request),
         {:ok, req_opts} <- build_opts(request, opts) do
      case ReqLLM.generate_text(model_spec, messages, req_opts) do
        {:ok, %ReqLLM.Response{} = resp} ->
          {:ok, to_response(resp, request)}

        {:error, reason} ->
          {:error, to_error(reason)}
      end
    end
  end

  @impl ExAthena.Provider
  def stream(%Request{} = request, callback, opts) when is_function(callback, 1) do
    with {:ok, model_spec} <- resolve_model(request, opts),
         {:ok, messages} <- build_messages(request),
         {:ok, req_opts} <- build_opts(request, opts) do
      case ReqLLM.stream_text(model_spec, messages, req_opts) do
        {:ok, %ReqLLM.StreamResponse{} = sr} ->
          {:ok, consume_stream(sr, callback, request)}

        {:error, reason} ->
          {:error, to_error(reason)}
      end
    end
  end

  # ── Model resolution ──────────────────────────────────────────────

  # Translate ExAthena-side provider atoms into req_llm model specs.
  # Callers may pass a two-part string (`"ollama:llama3.1"`) OR a bare model
  # id (`"llama3.1"`); when bare, Config threads the provider's `req_llm`
  # tag through opts so we can build the full spec here.
  defp resolve_model(%Request{model: model_str}, opts) when is_binary(model_str) and model_str != "" do
    if String.contains?(model_str, ":") do
      {:ok, model_str}
    else
      case Keyword.get(opts, :req_llm_provider_tag) do
        tag when is_binary(tag) and tag != "" -> {:ok, tag <> ":" <> model_str}
        _ -> {:ok, model_str}
      end
    end
  end

  defp resolve_model(_request, opts) do
    case Keyword.get(opts, :model) do
      m when is_binary(m) and m != "" ->
        case Keyword.get(opts, :req_llm_provider_tag) do
          tag when is_binary(tag) and tag != "" -> {:ok, tag <> ":" <> m}
          _ -> {:ok, m}
        end

      _ ->
        {:error, Error.new(:bad_request, "no model configured", provider: :req_llm)}
    end
  end

  # ── Messages ──────────────────────────────────────────────────────

  defp build_messages(%Request{messages: [], system_prompt: sp}) when is_binary(sp) and sp != "" do
    # System-prompt-only request — req_llm requires at least one user msg.
    {:error, Error.new(:bad_request, "no messages supplied", provider: :req_llm)}
  end

  defp build_messages(%Request{messages: messages, system_prompt: sp}) do
    base =
      case sp do
        nil -> []
        "" -> []
        str -> [%ReqLLM.Message{role: :system, content: [ReqLLM.Message.ContentPart.text(str)]}]
      end

    converted = Enum.map(messages, &to_req_llm_message/1)
    {:ok, base ++ converted}
  end

  defp to_req_llm_message(%Message{role: :system, content: content}) do
    %ReqLLM.Message{role: :system, content: text_parts(content)}
  end

  defp to_req_llm_message(%Message{role: :user, content: content}) do
    %ReqLLM.Message{role: :user, content: text_parts(content)}
  end

  defp to_req_llm_message(%Message{role: :assistant, content: content, tool_calls: calls}) do
    %ReqLLM.Message{
      role: :assistant,
      content: text_parts(content),
      tool_calls: if(is_list(calls) and calls != [], do: format_tool_calls(calls), else: nil)
    }
  end

  defp to_req_llm_message(%Message{role: :tool, tool_results: [%ToolResult{} = first | _]}) do
    %ReqLLM.Message{
      role: :tool,
      content: text_parts(first.content),
      tool_call_id: first.tool_call_id,
      metadata: if(first.is_error, do: %{is_error: true}, else: %{})
    }
  end

  defp to_req_llm_message(%Message{role: :tool, content: content}) when is_binary(content) do
    # Older shape — no tool_call_id available; forward as user-visible text.
    %ReqLLM.Message{role: :user, content: text_parts(content)}
  end

  defp text_parts(nil), do: []
  defp text_parts(""), do: []
  defp text_parts(content) when is_binary(content),
    do: [ReqLLM.Message.ContentPart.text(content)]

  defp format_tool_calls(calls) do
    Enum.map(calls, fn tc ->
      %{
        id: tc.id,
        name: tc.name,
        arguments: tc.arguments || %{}
      }
    end)
  end

  # ── Options ────────────────────────────────────────────────────────

  defp build_opts(%Request{} = request, opts) do
    base_opts =
      [
        api_key: Keyword.get(opts, :api_key),
        base_url: Keyword.get(opts, :base_url),
        max_tokens: request.max_tokens,
        temperature: request.temperature,
        top_p: request.top_p,
        stop: request.stop,
        tools: request.tools,
        tool_choice: request.tool_choice,
        receive_timeout: request.timeout_ms
      ]
      |> Keyword.reject(fn {_k, v} -> is_nil(v) or v == [] end)

    provider_opts = Keyword.get(opts, :provider_opts, [])
    {:ok, Keyword.merge(base_opts, provider_opts)}
  end

  # ── Response mapping ──────────────────────────────────────────────

  defp to_response(%ReqLLM.Response{} = resp, %Request{} = request) do
    %Response{
      text: extract_text(resp),
      tool_calls: extract_tool_calls(resp),
      finish_reason: resp.finish_reason,
      model: resp.model || request.model,
      provider: :req_llm,
      usage: resp.usage,
      raw: resp
    }
  end

  defp extract_text(%ReqLLM.Response{message: nil}), do: ""

  defp extract_text(%ReqLLM.Response{message: %{content: content}}) when is_binary(content),
    do: content

  defp extract_text(%ReqLLM.Response{message: %{content: parts}}) when is_list(parts) do
    parts
    |> Enum.filter(fn part -> part_type(part) == :text end)
    |> Enum.map_join("", &part_text/1)
  end

  defp extract_text(_), do: ""

  defp extract_tool_calls(%ReqLLM.Response{message: nil}), do: []

  defp extract_tool_calls(%ReqLLM.Response{message: %{tool_calls: calls}}) when is_list(calls) do
    case ExAthena.ToolCalls.Native.parse(calls) do
      {:ok, parsed} -> parsed
      _ -> []
    end
  end

  defp extract_tool_calls(%ReqLLM.Response{message: %{content: parts}}) when is_list(parts) do
    parts
    |> Enum.filter(fn part -> part_type(part) == :tool_use end)
    |> Enum.map(&part_to_tool_call/1)
  end

  defp extract_tool_calls(_), do: []

  defp part_type(%{type: type}), do: type
  defp part_type(%{"type" => type}) when is_binary(type), do: String.to_atom(type)
  defp part_type(_), do: :unknown

  defp part_text(%{text: text}) when is_binary(text), do: text
  defp part_text(%{"text" => text}) when is_binary(text), do: text
  defp part_text(_), do: ""

  defp part_to_tool_call(part) do
    %ExAthena.Messages.ToolCall{
      id: Map.get(part, :id) || Map.get(part, "id"),
      name: Map.get(part, :name) || Map.get(part, "name"),
      arguments:
        Map.get(part, :input) || Map.get(part, "input") ||
          Map.get(part, :arguments) || Map.get(part, "arguments") || %{}
    }
  end

  # ── Streaming ─────────────────────────────────────────────────────

  defp consume_stream(%ReqLLM.StreamResponse{stream: stream}, callback, request) do
    state = %{text: [], tool_calls: [], model: request.model, finish_reason: nil, usage: nil}

    final =
      Enum.reduce(stream, state, fn chunk, acc ->
        handle_chunk(chunk, callback, acc)
      end)

    ExAthena.Streaming.stop(callback, final.finish_reason || :stop)

    %Response{
      text: final.text |> Enum.reverse() |> IO.iodata_to_binary(),
      tool_calls: final.tool_calls,
      finish_reason: final.finish_reason || :stop,
      model: final.model,
      provider: :req_llm,
      usage: final.usage
    }
  end

  defp handle_chunk(%{type: :content, text: text}, callback, acc) when is_binary(text) do
    ExAthena.Streaming.text_delta(callback, text)
    %{acc | text: [text | acc.text]}
  end

  defp handle_chunk(%{type: :tool_call} = tc, _callback, acc) do
    %{acc | tool_calls: acc.tool_calls ++ [tc]}
  end

  defp handle_chunk(%{type: :usage, usage: usage}, _callback, acc), do: %{acc | usage: usage}

  defp handle_chunk(%{type: :meta, finish_reason: reason}, _callback, acc) when not is_nil(reason),
    do: %{acc | finish_reason: reason}

  defp handle_chunk(_chunk, _callback, acc), do: acc

  # ── Error mapping ─────────────────────────────────────────────────

  defp to_error(%{status: status} = raw) when is_integer(status) do
    Error.new(Error.from_status(status), "req_llm error",
      provider: :req_llm,
      status: status,
      raw: raw
    )
  end

  defp to_error(reason) do
    Error.new(:server_error, inspect(reason), provider: :req_llm, raw: reason)
  end
end
