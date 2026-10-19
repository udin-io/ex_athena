defmodule ExAthena.Providers.ReqLLM.Gemini do
  @moduledoc false

  # Where ex_athena works around req_llm 1.15's Google adapter (issue 283).
  # Shapes follow Google's reference: https://ai.google.dev/api/generate-content
  #
  #   * Its chat path refuses `:response_format` (a NimbleOptions error before
  #     any request), and only its `:object` path writes a schema — as the
  #     OpenAPI `responseSchema` for any id outside `gemini-2.5-*`/`gemini-3*`,
  #     which drops `anyOf` with null. We run the chat request ourselves and add
  #     `generationConfig.responseMimeType` and `responseJsonSchema` after the
  #     adapter has encoded the body.
  #   * `attach/3` always puts the key in the URL as `?key=`; its
  #     `google_auth_header` flag moves it to `x-goog-api-key` on streams only.
  #     We drop the query parameter and set the header before Req builds the URL.
  #   * A missing key raises from `ReqLLM.Keys.get!/2` after it falls back to
  #     `config :req_llm`, `GOOGLE_API_KEY` and dotenvy's `.env`. We refuse it
  #     before req_llm runs.
  #   * A blocked prompt (`promptFeedback.blockReason`, no candidates) decodes
  #     as an empty answer, and BLOCKLIST, PROHIBITED_CONTENT and SPII map to
  #     `"error"`. We read the raw body before the adapter decodes it.

  alias ExAthena.Error
  alias ReqLLM.Providers.Google

  # Candidate finish reasons that mean a filter stopped the answer. LANGUAGE
  # (an unsupported language) is left to req_llm's `:error`.
  @filtered_finish_reasons ~w(SAFETY RECITATION BLOCKLIST PROHIBITED_CONTENT SPII
                              IMAGE_SAFETY IMAGE_PROHIBITED_CONTENT IMAGE_RECITATION)

  @blocked_key :ex_athena_gemini_blocked

  @doc "True when the resolved req_llm model spec talks to Google's Gemini API."
  @spec model?(term()) :: boolean()
  def model?(%LLMDB.Model{provider: :google}), do: true

  # req_llm reads "google:<id>" and "<id>@google" alike; ask it rather than
  # match one spelling.
  def model?(spec) when is_binary(spec) do
    match?({:ok, %LLMDB.Model{provider: :google}}, ReqLLM.model(spec))
  end

  def model?(_), do: false

  @doc """
  Checks a Gemini call before req_llm sees it: a key is present, and a stream
  does not ask for a JSON shape (the streaming path has no place to put it).
  """
  @spec preflight(keyword(), :query | :stream | :embed) :: :ok | {:error, Error.t()}
  def preflight(req_opts, kind) do
    cond do
      not present?(Keyword.get(req_opts, :api_key)) ->
        {:error,
         Error.new(
           :unauthorized,
           "no Gemini API key. Pass api_key: or set config :ex_athena, :gemini, api_key: ...",
           provider: :req_llm
         )}

      not (is_list(Keyword.get(req_opts, :provider_options, [])) or
               is_map(Keyword.get(req_opts, :provider_options))) ->
        {:error,
         Error.new(:bad_request, "provider_options must be a keyword list", provider: :req_llm)}

      kind == :stream and Keyword.has_key?(req_opts, :response_format) ->
        {:error,
         Error.new(
           :bad_request,
           "Gemini takes a JSON shape on a query, not a stream. Use ExAthena.query/2 " <>
             "or ExAthena.StructuredOutput.request/3.",
           provider: :req_llm
         )}

      true ->
        :ok
    end
  end

  defp present?(key), do: is_binary(key) and key != ""

  @doc """
  Forces header auth for req_llm's streaming path, whatever the caller passed.
  """
  @spec with_header_auth(keyword()) :: keyword()
  def with_header_auth(req_opts) do
    provider_options =
      req_opts
      |> Keyword.get(:provider_options, [])
      |> Enum.to_list()
      |> Keyword.put(:google_auth_header, true)

    Keyword.put(req_opts, :provider_options, provider_options)
  end

  @doc """
  The non-streaming call: req_llm's own Google request, with the key moved to
  the header, the JSON shape added to the body, and blocks reported as
  `:content_filter`.
  """
  @spec generate_text(term(), list(), keyword()) ::
          {:ok, ReqLLM.Response.t()} | {:error, term()}
  def generate_text(model_spec, messages, req_opts) do
    {response_format, req_opts} = Keyword.pop(req_opts, :response_format)
    api_key = Keyword.fetch!(req_opts, :api_key)

    with {:ok, generation_config} <- json_generation_config(response_format),
         {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(messages, req_opts),
         {:ok, request} <-
           Google.prepare_request(
             :chat,
             model,
             context,
             with_header_auth(req_opts)
           ),
         {:ok, request} <- adapt_request(request, api_key, generation_config) do
      request
      |> send_request()
      |> handle_response()
    end
  end

  # req_llm's Google decoder raises on bodies outside Google's documented
  # shapes (`"candidates": "x"`, a top-level list). The request is ours here,
  # so a hostile or broken server yields an error, not a crash.
  defp send_request(request) do
    Req.request(request)
  rescue
    e ->
      {:error,
       Error.new(
         :server_error,
         "Gemini returned a response ex_athena could not read (#{inspect(e.__struct__)})",
         provider: :req_llm
       )}
  end

  defp adapt_request(%Req.Request{} = request, api_key, generation_config) do
    with {:ok, request_steps} <-
           insert_step(
             request.request_steps,
             :after,
             :llm_encode_body,
             {:ex_athena_gemini_json, &put_generation_config(&1, generation_config)}
           ),
         {:ok, response_steps} <-
           insert_step(
             request.response_steps,
             :before,
             :llm_decode_response,
             {:ex_athena_gemini_block, &record_block/1}
           ) do
      request =
        %{request | request_steps: request_steps, response_steps: response_steps}
        |> with_header_key(api_key)

      {:ok, request}
    end
  end

  # The adapter names its body encoder and decoder; if a req_llm upgrade
  # renames them we fail the call loudly rather than send a body without its
  # schema or miss a block.
  defp insert_step(steps, position, anchor, {name, fun}) do
    if Keyword.has_key?(steps, anchor) do
      {:ok,
       Enum.flat_map(steps, fn
         {^anchor, _} = step when position == :after -> [step, {name, fun}]
         {^anchor, _} = step when position == :before -> [{name, fun}, step]
         step -> [step]
       end)}
    else
      {:error,
       Error.new(
         :server_error,
         "req_llm's Google request has no #{anchor} step; ex_athena cannot adapt it",
         provider: :req_llm
       )}
    end
  end

  # Req follows redirects by default and strips only `authorization` when the
  # host changes, so a redirect would carry `x-goog-api-key` to another host.
  defp with_header_key(request, api_key) do
    request
    |> Req.Request.merge_options(redirect: false)
    |> Req.Request.prepend_request_steps(ex_athena_gemini_auth: &header_auth(&1, api_key))
  end

  # `attach/3` stored `params: [key: api_key]`; Req's `put_params` step,
  # which runs after this one, would copy it into the URL.
  defp header_auth(%Req.Request{} = request, api_key) do
    params = request.options |> Map.get(:params, []) |> drop_key_param()

    %{request | options: Map.put(request.options, :params, params)}
    |> Req.Request.put_header("x-goog-api-key", api_key)
  end

  defp drop_key_param(params) when is_map(params),
    do: params |> Map.drop([:key, "key"]) |> Map.to_list()

  defp drop_key_param(params) when is_list(params),
    do: Enum.reject(params, fn {k, _} -> k in [:key, "key"] end)

  defp put_generation_config(%Req.Request{} = request, nil), do: request

  defp put_generation_config(%Req.Request{options: %{json: body}} = request, extra)
       when is_map(body) do
    config = Map.merge(Map.get(body, :generationConfig) || %{}, extra)

    %{
      request
      | options: Map.put(request.options, :json, Map.put(body, :generationConfig, config))
    }
  end

  defp put_generation_config(request, _extra), do: request

  @doc false
  # `response_format` as ex_athena callers pass it, turned into the
  # generationConfig fields Google documents.
  def json_generation_config(nil), do: {:ok, nil}
  def json_generation_config(:text), do: {:ok, nil}
  def json_generation_config(:json), do: {:ok, %{responseMimeType: "application/json"}}

  def json_generation_config(format) when is_map(format) do
    case {fetch(format, :type), fetch(format, :json_schema)} do
      {"json_object", _} ->
        {:ok, %{responseMimeType: "application/json"}}

      {"json_schema", json_schema} when is_map(json_schema) ->
        case fetch(json_schema, :schema) do
          schema when is_map(schema) ->
            {:ok, %{responseMimeType: "application/json", responseJsonSchema: schema}}

          _ ->
            bad_format()
        end

      _ ->
        bad_format()
    end
  end

  def json_generation_config(_), do: bad_format()

  defp bad_format do
    {:error,
     Error.new(
       :bad_request,
       "unsupported response_format for Gemini: use :json, %{type: \"json_object\"} or " <>
         "%{type: \"json_schema\", json_schema: %{schema: map}}",
       provider: :req_llm
     )}
  end

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp record_block({req, %Req.Response{status: 200} = resp}) do
    {req, Req.Response.put_private(resp, @blocked_key, blocked?(parse(resp.body)))}
  end

  defp record_block(pair), do: pair

  defp parse(body) when is_map(body), do: body

  defp parse(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp parse(_), do: %{}

  @doc false
  def blocked?(%{"promptFeedback" => %{"blockReason" => reason}})
      when is_binary(reason) and reason != "BLOCK_REASON_UNSPECIFIED",
      do: true

  def blocked?(%{"candidates" => [%{"finishReason" => reason} | _]}),
    do: reason in @filtered_finish_reasons

  def blocked?(_), do: false

  defp handle_response(
         {:ok, %Req.Response{status: status, body: %ReqLLM.Response{} = body} = resp}
       )
       when status in 200..299 do
    if Req.Response.get_private(resp, @blocked_key, false),
      do: {:ok, %{body | finish_reason: :content_filter}},
      else: {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error,
     ReqLLM.Error.API.Request.exception(
       reason: "HTTP #{status}: Request failed",
       status: status,
       response_body: body
     )}
  end

  defp handle_response({:error, _} = error), do: error

  @doc """
  Embeddings through req_llm's Google request, with the key in the header.
  Returns what `ReqLLM.embed/3` returns with `return_usage: true`.
  """
  @spec embed(term(), String.t() | [String.t()], keyword()) ::
          {:ok, %{embedding: list(), usage: map() | nil}} | {:error, term()}
  def embed(_model_spec, input, _req_opts) when input in ["", []] do
    {:error, Error.new(:bad_request, "nothing to embed", provider: :req_llm)}
  end

  def embed(model_spec, input, req_opts) do
    req_opts = Keyword.delete(req_opts, :return_usage)
    api_key = Keyword.fetch!(req_opts, :api_key)

    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, request} <-
           Google.prepare_request(
             :embedding,
             model,
             input,
             with_header_auth(req_opts)
           ) do
      request
      |> with_header_key(api_key)
      |> send_request()
      |> embed_response(input)
    end
  end

  defp embed_response(
         {:ok, %Req.Response{status: status, body: %{"data" => data}} = resp},
         input
       )
       when status in 200..299 and is_list(data) do
    vectors = data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])

    if length(vectors) == length(List.wrap(input)) and
         Enum.all?(vectors, &(is_list(&1) and &1 != [])) do
      embedding = if is_list(input), do: vectors, else: List.first(vectors)
      {:ok, %{embedding: embedding, usage: embed_usage(resp)}}
    else
      embed_shape_error()
    end
  end

  defp embed_response({:ok, %Req.Response{status: status}}, _input) when status in 200..299,
    do: embed_shape_error()

  defp embed_response({:ok, %Req.Response{status: status, body: body}}, _input) do
    {:error,
     ReqLLM.Error.API.Request.exception(
       reason: "HTTP #{status}: Request failed",
       status: status,
       response_body: body
     )}
  end

  defp embed_response({:error, _} = error, _input), do: error

  defp embed_shape_error do
    {:error,
     Error.new(
       :server_error,
       "Gemini returned embeddings that do not match the inputs",
       provider: :req_llm
     )}
  end

  # Same reading of req_llm's usage step as `ReqLLM.Embedding`.
  defp embed_usage(%Req.Response{private: private}) do
    case get_in(private, [:req_llm, :usage]) do
      %{tokens: tokens} = meta when is_map(tokens) ->
        meta
        |> Map.take([:input_cost, :output_cost, :reasoning_cost, :total_cost])
        |> Enum.reduce(tokens, fn
          {_key, nil}, acc -> acc
          {key, value}, acc -> Map.put(acc, key, value)
        end)

      usage when is_map(usage) ->
        usage

      _ ->
        nil
    end
  end
end
