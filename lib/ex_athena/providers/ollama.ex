defmodule ExAthena.Providers.Ollama do
  @moduledoc """
  Local Ollama provider via `/api/chat`.

  Ollama's HTTP API mirrors OpenAI's `tool_calls` shape as of v0.3. This
  provider talks to it directly via `Req`.

  ## Configuration

      config :ex_athena, :ollama,
        base_url: "http://localhost:11434",
        model: "llama3.1"

  ## Per-call overrides

      ExAthena.query("hi", provider: :ollama, model: "qwen2.5-coder")

  ## Capabilities

  Tool-call fidelity depends on the model — `llama3.1`, `qwen2.5-coder`, and
  `mistral-nemo` all handle the native schema reliably; smaller models often
  need TextTagged fallback. The agent loop handles fallback automatically when
  it sees a capability mismatch.
  """

  @behaviour ExAthena.Provider

  alias ExAthena.{Config, Error, Response, Streaming}
  alias ExAthena.Messages.Message

  @default_base_url "http://localhost:11434"
  @default_model "llama3.1"

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
           decode_body: true,
           headers: auth_headers(opts)
         ) do
      {:ok, %Req.Response{status: 200, body: response}} ->
        {:ok, to_response(decode(response), request)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, Error.new(Error.from_status(status), "Ollama HTTP #{status}: #{inspect(body)}", provider: :ollama, status: status, raw: body)}

      {:error, exception} ->
        {:error, Error.new(:transport, Exception.message(exception), provider: :ollama, raw: exception)}
    end
  end

  @impl ExAthena.Provider
  def stream(request, callback, opts) do
    body = build_body(request, opts, stream: true)
    url = endpoint_url(opts)

    state_ref = make_ref()
    state_pid = self()
    Process.put({__MODULE__, :stream_text, state_ref}, [])

    into_fn = fn {:data, chunk}, {req, resp} ->
      chunk
      |> String.split("\n", trim: true)
      |> Enum.each(&handle_stream_chunk(&1, callback, state_ref, state_pid))

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

    collected = Process.delete({__MODULE__, :stream_text, state_ref}) || []
    Streaming.stop(callback, :stop)

    case result do
      {:ok, %Req.Response{status: 200}} ->
        {:ok,
         %Response{
           text: collected |> Enum.reverse() |> IO.iodata_to_binary(),
           tool_calls: [],
           finish_reason: :stop,
           model: request.model || default_model(opts),
           provider: :ollama
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         Error.new(Error.from_status(status), "Ollama HTTP #{status}", provider: :ollama, status: status, raw: body)}

      {:error, exception} ->
        {:error, Error.new(:transport, Exception.message(exception), provider: :ollama, raw: exception)}
    end
  end

  defp handle_stream_chunk(line, callback, state_ref, _state_pid) do
    case Jason.decode(line) do
      {:ok, %{"message" => %{"content" => content}}} when is_binary(content) and content != "" ->
        Process.put({__MODULE__, :stream_text, state_ref},
          [content | Process.get({__MODULE__, :stream_text, state_ref}, [])])

        Streaming.text_delta(callback, content)

      {:ok, %{"done" => true}} ->
        :ok

      _ ->
        :ok
    end
  end

  # ── Request/response mapping ────────────────────────────────────────

  defp build_body(request, opts, stream: stream?) do
    %{
      model: request.model || default_model(opts),
      messages: format_messages(request),
      stream: stream?
    }
    |> maybe_put(:tools, request.tools)
    |> maybe_put(:options, sampling_opts(request))
    |> maybe_put(:format, format_for(request.response_format))
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

  defp format_message(%Message{role: :tool, tool_results: results}) do
    # Ollama accepts a single tool-role message per result.
    [first | _] = results || [%{tool_call_id: "", content: ""}]
    %{role: "tool", tool_call_id: first.tool_call_id, content: first.content}
  end

  defp format_tool_call(%{id: id, name: name, arguments: args}) do
    %{id: id, type: "function", function: %{name: name, arguments: Jason.encode!(args)}}
  end

  defp sampling_opts(%{temperature: nil, top_p: nil, stop: nil}), do: nil

  defp sampling_opts(request) do
    %{}
    |> maybe_put(:temperature, request.temperature)
    |> maybe_put(:top_p, request.top_p)
    |> maybe_put(:stop, List.wrap(request.stop))
    |> maybe_put(:num_predict, request.max_tokens)
  end

  defp format_for(:json), do: "json"
  defp format_for(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_response(%{"message" => message} = body, request) do
    text = message["content"] || ""
    tool_calls_raw = message["tool_calls"] || []

    {:ok, tool_calls} = ExAthena.ToolCalls.Native.parse(tool_calls_raw)

    %Response{
      text: text,
      tool_calls: tool_calls,
      finish_reason: if(body["done"], do: :stop, else: nil),
      model: body["model"] || request.model,
      provider: :ollama,
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
      provider: :ollama,
      raw: body
    }
  end

  defp extract_usage(%{"prompt_eval_count" => prompt, "eval_count" => completion}) do
    %{input_tokens: prompt, output_tokens: completion, total_tokens: prompt + completion}
  end

  defp extract_usage(_), do: nil

  defp decode(body) when is_map(body), do: body

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode(_), do: %{}

  # ── Endpoint + auth ────────────────────────────────────────────────

  defp endpoint_url(opts) do
    base = Config.get(__MODULE__, :base_url, opts, @default_base_url)
    base = String.trim_trailing(base, "/")
    base <> "/api/chat"
  end

  defp default_model(opts) do
    Config.get(__MODULE__, :model, opts, @default_model)
  end

  defp auth_headers(opts) do
    case Config.get(__MODULE__, :api_key, opts) do
      nil -> []
      key -> [{"authorization", "Bearer " <> key}]
    end
  end
end
