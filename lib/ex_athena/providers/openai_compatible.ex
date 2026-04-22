defmodule ExAthena.Providers.OpenAICompatible do
  @moduledoc """
  OpenAI-style `/v1/chat/completions` provider.

  Covers OpenAI proper, OpenRouter, LM Studio, vLLM, llama.cpp's server mode,
  Together AI, Groq, DeepInfra, Fireworks, and any other endpoint that speaks
  the OpenAI chat-completions wire format. Uses Server-Sent Events for
  streaming.

  ## Configuration

      config :ex_athena, :openai_compatible,
        base_url: "https://api.openai.com/v1",
        api_key: System.get_env("OPENAI_API_KEY"),
        model: "gpt-4o-mini"

  Or per-provider atoms (they all resolve to this module):

      config :ex_athena, :openai, api_key: "…", base_url: "…"
      config :ex_athena, :llamacpp, base_url: "http://localhost:8080/v1"

  Per-call overrides always win.

  ## Tool calls

  Native OpenAI `tool_calls`. `ExAthena.ToolCalls.Native` handles parsing.
  """

  @behaviour ExAthena.Provider

  alias ExAthena.{Config, Error, Response, Streaming}
  alias ExAthena.Messages.Message

  @default_base_url "https://api.openai.com/v1"

  @impl ExAthena.Provider
  def capabilities do
    %{
      native_tool_calls: true,
      streaming: true,
      json_mode: true,
      max_tokens: 128_000,
      supports_resume: false,
      supports_system_prompt: true,
      supports_temperature: true
    }
  end

  @impl ExAthena.Provider
  def query(request, opts) do
    body = build_body(request, opts, stream: false)
    url = endpoint_url(opts)

    case Req.post(url,
           json: body,
           receive_timeout: request.timeout_ms,
           retry: false,
           headers: auth_headers(opts)
         ) do
      {:ok, %Req.Response{status: 200, body: resp}} ->
        {:ok, to_response(resp, request)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         Error.new(Error.from_status(status), "OpenAI HTTP #{status}: #{inspect(body)}",
           provider: :openai_compatible,
           status: status,
           raw: body
         )}

      {:error, exception} ->
        {:error,
         Error.new(:transport, Exception.message(exception),
           provider: :openai_compatible,
           raw: exception
         )}
    end
  end

  @impl ExAthena.Provider
  def stream(request, callback, opts) do
    body = build_body(request, opts, stream: true)
    url = endpoint_url(opts)

    state_ref = make_ref()
    Process.put({__MODULE__, :text, state_ref}, [])
    Process.put({__MODULE__, :buf, state_ref}, "")

    into_fn = fn {:data, chunk}, {req, resp} ->
      new_buf = Process.get({__MODULE__, :buf, state_ref}, "") <> chunk

      {lines, trailing} = split_sse_events(new_buf)
      Process.put({__MODULE__, :buf, state_ref}, trailing)

      Enum.each(lines, &handle_sse_event(&1, callback, state_ref))

      {:cont, {req, resp}}
    end

    result =
      Req.post(url,
        json: body,
        into: into_fn,
        receive_timeout: request.timeout_ms,
        retry: false,
        headers: auth_headers(opts)
      )

    text = Process.delete({__MODULE__, :text, state_ref}) || []
    _ = Process.delete({__MODULE__, :buf, state_ref})
    Streaming.stop(callback, :stop)

    case result do
      {:ok, %Req.Response{status: 200}} ->
        {:ok,
         %Response{
           text: text |> Enum.reverse() |> IO.iodata_to_binary(),
           tool_calls: [],
           finish_reason: :stop,
           model: request.model || default_model(opts),
           provider: :openai_compatible
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         Error.new(Error.from_status(status), "OpenAI HTTP #{status}",
           provider: :openai_compatible,
           status: status,
           raw: body
         )}

      {:error, exception} ->
        {:error,
         Error.new(:transport, Exception.message(exception),
           provider: :openai_compatible,
           raw: exception
         )}
    end
  end

  # SSE uses `\n\n` to separate events; split on blank lines.
  defp split_sse_events(buf) do
    parts = String.split(buf, "\n\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp handle_sse_event(event, callback, state_ref) do
    event
    |> String.split("\n", trim: true)
    |> Enum.each(fn
      "data: [DONE]" ->
        :ok

      "data: " <> payload ->
        case Jason.decode(payload) do
          {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]}}
          when is_binary(content) and content != "" ->
            Process.put({__MODULE__, :text, state_ref}, [
              content | Process.get({__MODULE__, :text, state_ref}, [])
            ])

            Streaming.text_delta(callback, content)

          _ ->
            :ok
        end

      _ ->
        :ok
    end)
  end

  # ── Request/response mapping ────────────────────────────────────────

  defp build_body(request, opts, stream: stream?) do
    %{
      model: request.model || default_model(opts),
      messages: format_messages(request),
      stream: stream?
    }
    |> maybe_put(:tools, request.tools)
    |> maybe_put(:tool_choice, request.tool_choice)
    |> maybe_put(:temperature, request.temperature)
    |> maybe_put(:top_p, request.top_p)
    |> maybe_put(:max_tokens, request.max_tokens)
    |> maybe_put(:stop, List.wrap(request.stop))
    |> maybe_put(:response_format, response_format(request.response_format))
  end

  defp format_messages(%{messages: messages, system_prompt: sys}) do
    system_messages =
      case sys do
        nil -> []
        "" -> []
        str -> [%{role: "system", content: str}]
      end

    system_messages ++ Enum.map(messages, &format_message/1)
  end

  defp format_message(%Message{role: :system, content: content}),
    do: %{role: "system", content: content}

  defp format_message(%Message{role: :user, content: content}),
    do: %{role: "user", content: content}

  defp format_message(%Message{role: :assistant, content: content, tool_calls: calls}) do
    base = %{role: "assistant", content: content || ""}

    if calls && calls != [] do
      Map.put(base, :tool_calls, Enum.map(calls, &format_tool_call/1))
    else
      base
    end
  end

  defp format_message(%Message{role: :tool, tool_results: [first | _]}) do
    %{role: "tool", tool_call_id: first.tool_call_id, content: first.content}
  end

  defp format_tool_call(%{id: id, name: name, arguments: args}) do
    %{id: id, type: "function", function: %{name: name, arguments: Jason.encode!(args)}}
  end

  defp response_format(:json), do: %{type: "json_object"}
  defp response_format(%{} = map), do: map
  defp response_format(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_response(%{"choices" => [%{"message" => message, "finish_reason" => finish} | _]} = body, request) do
    tool_calls_raw = message["tool_calls"] || []
    {:ok, tool_calls} = ExAthena.ToolCalls.Native.parse(tool_calls_raw)

    %Response{
      text: message["content"] || "",
      tool_calls: tool_calls,
      finish_reason: decode_finish(finish),
      model: body["model"] || request.model,
      provider: :openai_compatible,
      usage: extract_usage(body),
      raw: body
    }
  end

  defp to_response(body, request) do
    %Response{
      text: "",
      tool_calls: [],
      finish_reason: :error,
      model: request.model,
      provider: :openai_compatible,
      raw: body
    }
  end

  defp decode_finish("stop"), do: :stop
  defp decode_finish("length"), do: :length
  defp decode_finish("tool_calls"), do: :tool_calls
  defp decode_finish("content_filter"), do: :content_filter
  defp decode_finish(_), do: nil

  defp extract_usage(%{
         "usage" => %{"prompt_tokens" => prompt, "completion_tokens" => completion} = usage
       }) do
    %{
      input_tokens: prompt,
      output_tokens: completion,
      total_tokens: usage["total_tokens"] || prompt + completion
    }
  end

  defp extract_usage(_), do: nil

  # ── Endpoint + auth ────────────────────────────────────────────────

  defp endpoint_url(opts) do
    base = Config.get(__MODULE__, :base_url, opts, @default_base_url)
    base = String.trim_trailing(base, "/")
    base <> "/chat/completions"
  end

  defp default_model(opts) do
    Config.get(__MODULE__, :model, opts) ||
      raise ArgumentError,
            "No :model configured for OpenAI-compatible provider. Pass `model:` per call " <>
              "or set `config :ex_athena, :openai_compatible, model: \"gpt-4o-mini\"`."
  end

  defp auth_headers(opts) do
    headers =
      case Config.get(__MODULE__, :api_key, opts) do
        nil -> []
        key -> [{"authorization", "Bearer " <> key}]
      end

    case Config.get(__MODULE__, :organization, opts) do
      nil -> headers
      org -> [{"openai-organization", org} | headers]
    end
  end
end
