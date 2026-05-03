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

  require Logger

  alias ExAthena.{Error, Request, Response}
  alias ExAthena.Messages.{Message, ToolResult}

  # Claude Code-style log prefix so callers can filter/tail the adapter
  # boundary independently of other ex_athena components.
  @log_prefix "[ExAthena.ReqLLM]"

  @impl ExAthena.Provider
  def capabilities do
    %{
      native_tool_calls: true,
      streaming: true,
      json_mode: true,
      structured_output: true,
      max_tokens: 200_000,
      supports_resume: false,
      supports_system_prompt: true,
      supports_temperature: true,
      compact_tool_schemas: true
    }
  end

  @impl ExAthena.Provider
  def query(%Request{} = request, opts) do
    with {:ok, model_spec} <- resolve_model(request, opts),
         {:ok, messages} <- build_messages(request),
         {:ok, req_opts} <- build_opts(request, opts) do
      log_request(:query, model_spec, request, messages, req_opts)

      case ReqLLM.generate_text(model_spec, messages, req_opts) do
        {:ok, %ReqLLM.Response{} = resp} ->
          response = to_response(resp, request)
          log_response(response)
          {:ok, response}

        {:error, reason} ->
          log_error(reason)
          {:error, to_error(reason)}
      end
    end
  end

  @impl ExAthena.Provider
  def stream(%Request{} = request, callback, opts) when is_function(callback, 1) do
    with {:ok, model_spec} <- resolve_model(request, opts),
         {:ok, messages} <- build_messages(request),
         {:ok, req_opts} <- build_opts(request, opts) do
      log_request(:stream, model_spec, request, messages, req_opts)

      case ReqLLM.stream_text(model_spec, messages, req_opts) do
        {:ok, %ReqLLM.StreamResponse{} = sr} ->
          response = consume_stream(sr, callback, request)
          log_response(response)
          {:ok, response}

        {:error, reason} ->
          log_error(reason)
          {:error, to_error(reason)}
      end
    end
  end

  # ── Model resolution ──────────────────────────────────────────────

  # Translate ExAthena-side provider atoms into req_llm model specs.
  # Callers may pass a two-part string (`"openai:gpt-4"`) OR a bare model
  # id (`"qwen2.5-coder:14b"`). When bare, Config threads the provider's
  # `req_llm` tag through opts so we can build the full spec here.
  #
  # Note: bare Ollama model ids legitimately contain `:` (the version
  # separator, e.g. `"qwen2.5-coder:14b"`) so we cannot use the presence
  # of a colon as a "spec already tagged" signal — the tag is the source
  # of truth. We only skip prefixing when the model string already begins
  # with the same tag (caller passed a fully-formed spec).
  @doc false
  def resolve_model(%Request{model: model_str}, opts)
      when is_binary(model_str) and model_str != "" do
    {:ok, prepend_tag(model_str, opts)}
  end

  def resolve_model(_request, opts) do
    case Keyword.get(opts, :model) do
      m when is_binary(m) and m != "" ->
        {:ok, prepend_tag(m, opts)}

      _ ->
        {:error, Error.new(:bad_request, "no model configured", provider: :req_llm)}
    end
  end

  defp prepend_tag(model, opts) do
    case Keyword.get(opts, :req_llm_provider_tag) do
      tag when is_binary(tag) and tag != "" ->
        prefix = tag <> ":"
        if String.starts_with?(model, prefix), do: model, else: prefix <> model

      _ ->
        model
    end
  end

  # ── Messages ──────────────────────────────────────────────────────

  defp build_messages(%Request{messages: [], system_prompt: sp})
       when is_binary(sp) and sp != "" do
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

  @doc false
  def to_req_llm_message(%Message{role: :system, content: content}) do
    %ReqLLM.Message{role: :system, content: text_parts(content)}
  end

  def to_req_llm_message(%Message{role: :user, content: content}) do
    %ReqLLM.Message{role: :user, content: text_parts(content)}
  end

  def to_req_llm_message(%Message{role: :assistant, content: content, tool_calls: calls}) do
    %ReqLLM.Message{
      role: :assistant,
      content: text_parts(content),
      tool_calls: if(is_list(calls) and calls != [], do: format_tool_calls(calls), else: nil)
    }
  end

  def to_req_llm_message(%Message{role: :tool, tool_results: [%ToolResult{} = first | _]}) do
    %ReqLLM.Message{
      role: :tool,
      content: text_parts(first.content),
      tool_call_id: first.tool_call_id,
      metadata: if(first.is_error, do: %{is_error: true}, else: %{})
    }
  end

  def to_req_llm_message(%Message{role: :tool, content: content}) when is_binary(content) do
    # Older shape — no tool_call_id available; forward as user-visible text.
    %ReqLLM.Message{role: :user, content: text_parts(content)}
  end

  defp text_parts(nil), do: []
  defp text_parts(""), do: []

  defp text_parts(content) when is_binary(content),
    do: [ReqLLM.Message.ContentPart.text(content)]

  defp format_tool_calls(calls) do
    Enum.map(calls, fn tc ->
      ReqLLM.ToolCall.new(tc.id, tc.name, encode_arguments(tc.arguments))
    end)
  end

  defp encode_arguments(nil), do: "{}"
  defp encode_arguments(args) when is_binary(args), do: args
  defp encode_arguments(args) when is_map(args), do: Jason.encode!(args)

  # ── Options ────────────────────────────────────────────────────────

  @doc false
  def build_opts(%Request{} = request, opts) do
    backend = Keyword.get(opts, :openai_compatible_backend)
    base_url = normalize_base_url(Keyword.get(opts, :base_url), backend)
    api_key = resolve_api_key(Keyword.get(opts, :api_key), backend)

    base_opts =
      [
        api_key: api_key,
        base_url: base_url,
        openai_compatible_backend: backend,
        max_tokens: request.max_tokens,
        temperature: request.temperature,
        top_p: request.top_p,
        stop: request.stop,
        tools: to_req_llm_tools(request.tools),
        tool_choice: request.tool_choice,
        response_format: Keyword.get(opts, :response_format, request.response_format),
        receive_timeout: request.timeout_ms
      ]
      |> Keyword.reject(fn {_k, v} -> is_nil(v) or v == [] end)

    provider_opts = Keyword.get(opts, :provider_opts, [])
    {:ok, Keyword.merge(base_opts, provider_opts)}
  end

  # ex_athena's modes (see `Tools.describe_for_provider/1`) build OpenAI-format
  # tool maps (`%{type: "function", function: %{name, description, parameters}}`)
  # directly. req_llm 1.10 expects each entry in `:tools` to be a `%ReqLLM.Tool{}`
  # struct so it can call `ReqLLM.Tool.to_schema/2` per provider — passing maps
  # raises `no function clause matching in ReqLLM.Tool.to_schema/2`. Convert
  # here. The callback is a stub: req_llm uses it only for client-side execution
  # and ex_athena executes tools server-side via `ExAthena.Tool.execute/2`.
  @doc false
  def to_req_llm_tools(nil), do: nil
  def to_req_llm_tools([]), do: []
  def to_req_llm_tools(tools) when is_list(tools), do: Enum.map(tools, &to_req_llm_tool/1)

  defp to_req_llm_tool(%ReqLLM.Tool{} = tool), do: tool

  defp to_req_llm_tool(%{function: %{name: name, description: desc, parameters: params}}) do
    build_req_llm_tool(name, desc, params)
  end

  defp to_req_llm_tool(%{
         "function" => %{"name" => name, "description" => desc, "parameters" => params}
       }) do
    build_req_llm_tool(name, desc, params)
  end

  defp build_req_llm_tool(name, desc, params) do
    %ReqLLM.Tool{
      name: name,
      description: desc,
      parameter_schema: params || %{},
      callback: &noop_callback/1,
      strict: false,
      compiled: nil,
      provider_options: %{}
    }
  end

  defp noop_callback(_args),
    do: {:error, :tool_execution_handled_by_ex_athena}

  # Local OpenAI-compatible servers (Ollama, llama.cpp) commonly accept either
  # the bare host (`http://localhost:11434`) or the OpenAI prefix
  # (`http://localhost:11434/v1`). req_llm's openai adapter expects the prefix
  # to already include `/v1`. Append it when the caller passed the bare host.
  defp normalize_base_url(nil, _backend), do: nil
  defp normalize_base_url(url, nil), do: url

  defp normalize_base_url(url, _backend) when is_binary(url) do
    trimmed = String.trim_trailing(url, "/")

    cond do
      String.ends_with?(trimmed, "/v1") -> trimmed
      true -> trimmed <> "/v1"
    end
  end

  # req_llm's openai adapter requires *some* api_key value even when
  # `openai_compatible_backend: :ollama | :llamacpp` allows missing auth — the
  # underlying HTTP request still sets an Authorization header. Local servers
  # ignore it, so substitute a placeholder when the caller didn't supply one.
  defp resolve_api_key(nil, :ollama), do: "ollama"
  defp resolve_api_key(nil, :llamacpp), do: "llamacpp"
  defp resolve_api_key(key, _backend), do: key

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
    state = %{
      text: [],
      tool_calls: [],
      model: request.model,
      finish_reason: nil,
      usage: nil,
      first_chunk_logged: false,
      stream_started_ms: System.monotonic_time(:millisecond)
    }

    heartbeat_pid = start_heartbeat(state.stream_started_ms)

    final =
      try do
        Enum.reduce(stream, state, fn chunk, acc ->
          acc = maybe_log_first_chunk(chunk, acc)
          handle_chunk(chunk, callback, acc)
        end)
      after
        stop_heartbeat(heartbeat_pid)
      end

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

  # ── Heartbeat / TTFT (visibility while Ollama is processing) ──────────
  #
  # Local Ollama on a 14B+ model can spend 30–120s processing the prompt
  # before emitting the first chunk. Without any signal on the wire,
  # callers can't tell a slow-but-alive request from a stalled one. Emit a
  # `⋯ waiting on stream (Ns elapsed)` heartbeat every 10s until the first
  # content/tool_call chunk arrives, then log the TTFT exactly once.

  @heartbeat_interval_ms 10_000

  defp start_heartbeat(start_ms) do
    parent = self()

    spawn(fn ->
      heartbeat_loop(parent, start_ms)
    end)
  end

  defp heartbeat_loop(parent, start_ms) do
    receive do
      :stop -> :ok
    after
      @heartbeat_interval_ms ->
        if Process.alive?(parent) do
          elapsed_s = div(System.monotonic_time(:millisecond) - start_ms, 1000)
          Logger.info("#{@log_prefix} ⋯ waiting on stream (#{elapsed_s}s elapsed)")
          heartbeat_loop(parent, start_ms)
        else
          :ok
        end
    end
  end

  defp stop_heartbeat(pid) when is_pid(pid) do
    send(pid, :stop)
    :ok
  end

  defp maybe_log_first_chunk(%{type: type}, %{first_chunk_logged: false} = acc)
       when type in [:content, :tool_call] do
    elapsed_ms = System.monotonic_time(:millisecond) - acc.stream_started_ms
    Logger.info("#{@log_prefix} ←first_chunk after #{elapsed_ms}ms (TTFT)")
    %{acc | first_chunk_logged: true}
  end

  defp maybe_log_first_chunk(_chunk, acc), do: acc

  defp handle_chunk(%{type: :content, text: text}, callback, acc) when is_binary(text) do
    Logger.debug(fn ->
      "#{@log_prefix} ←text_delta #{byte_size(text)}B: #{preview(text, 80)}"
    end)

    ExAthena.Streaming.text_delta(callback, text)
    %{acc | text: [text | acc.text]}
  end

  defp handle_chunk(%{type: :tool_call} = tc, _callback, acc) do
    Logger.debug(fn ->
      name = Map.get(tc, :name) || Map.get(tc, "name") || "<unknown>"
      args = Map.get(tc, :arguments) || Map.get(tc, "arguments") || %{}

      "#{@log_prefix} ←tool_call name=#{inspect(name)} args=#{inspect(args, limit: 3, printable_limit: 200)}"
    end)

    %{acc | tool_calls: acc.tool_calls ++ [tc]}
  end

  defp handle_chunk(%{type: :usage, usage: usage}, _callback, acc) do
    Logger.debug(fn -> "#{@log_prefix} ←usage #{inspect(usage)}" end)
    %{acc | usage: usage}
  end

  defp handle_chunk(%{type: :meta, finish_reason: reason}, _callback, acc)
       when not is_nil(reason) do
    Logger.debug(fn -> "#{@log_prefix} ←meta finish_reason=#{inspect(reason)}" end)
    %{acc | finish_reason: reason}
  end

  defp handle_chunk(_chunk, _callback, acc), do: acc

  # ── Logging helpers (Claude Code-style adapter-boundary breadcrumbs) ──

  defp log_request(kind, model_spec, %Request{} = request, messages, req_opts) do
    base_url = Keyword.get(req_opts, :base_url) || "<provider default>"
    backend = Keyword.get(req_opts, :openai_compatible_backend)
    n_msgs = length(messages)
    n_tools = length(Keyword.get(req_opts, :tools, []) || [])

    Logger.info(
      "#{@log_prefix} →#{kind} model=#{inspect(model_spec)} msgs=#{n_msgs} tools=#{n_tools} " <>
        "base_url=#{base_url}#{if backend, do: " backend=#{inspect(backend)}", else: ""}"
    )

    Logger.debug(fn ->
      sp_preview =
        case request.system_prompt do
          nil -> "nil"
          "" -> "\"\""
          str when is_binary(str) -> "#{byte_size(str)}B: #{preview(str, 200)}"
        end

      msg_lines =
        messages
        |> Enum.with_index()
        |> Enum.map(fn {%ReqLLM.Message{role: role, content: parts}, i} ->
          text = parts |> Enum.map(&content_part_text/1) |> Enum.join(" ")
          "  msg[#{i}] #{role}: #{preview(text, 200)}"
        end)
        |> Enum.join("\n")

      "#{@log_prefix} →#{kind} system_prompt=#{sp_preview}\n#{msg_lines}"
    end)
  end

  defp log_response(%Response{} = resp) do
    text_chars = byte_size(resp.text || "")
    n_tool_calls = length(resp.tool_calls || [])

    Logger.info(
      "#{@log_prefix} ←done finish_reason=#{inspect(resp.finish_reason)} " <>
        "text_chars=#{text_chars} tool_calls=#{n_tool_calls} " <>
        "usage=#{inspect(resp.usage, limit: 5)}"
    )

    Logger.debug(fn ->
      "#{@log_prefix} ←done text_preview=#{preview(resp.text || "", 300)}"
    end)
  end

  defp log_error(reason) do
    Logger.warning("#{@log_prefix} ←error #{inspect(reason, limit: 5, printable_limit: 500)}")
  end

  defp content_part_text(%ReqLLM.Message.ContentPart{text: text}) when is_binary(text), do: text
  defp content_part_text(_), do: ""

  defp preview(str, max) when is_binary(str) do
    cleaned = String.replace(str, ~r/\s+/, " ")

    if byte_size(cleaned) <= max do
      inspect(cleaned)
    else
      inspect(binary_part(cleaned, 0, max) <> "…")
    end
  end

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
