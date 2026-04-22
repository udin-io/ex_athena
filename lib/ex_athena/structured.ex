defmodule ExAthena.Structured do
  @moduledoc """
  One-shot structured extraction backed by a JSON schema.

  Two implementation paths depending on provider capability:

    * **JSON mode** (provider declares `json_mode: true`) — we set
      `response_format: :json` on the request. The provider asks the model
      to emit JSON only.

    * **Fenced-block fallback** — for providers without JSON mode we append
      instructions to the system prompt telling the model to emit exactly one
      `~~~json ... ~~~` block, then extract and parse it.

  Regardless of path, the returned JSON is validated against the supplied
  schema. Validation is best-effort (we check types + required keys — no
  fancy `$ref` chasing); for stricter validation, pass your own validator via
  `:validator` opt.
  """

  alias ExAthena.{Config, Request}

  @fence_regex ~r/~~~json\s*\n(.*?)\n~~~/s

  @doc """
  Extract structured JSON from a single inference call.

  Options:

    * All of `ExAthena.query/2`'s options.
    * `:schema` (required) — a JSON Schema map. Describes the output shape.
    * `:validator` (optional) — `(map, schema -> :ok | {:error, reason})`.
      Defaults to `validate_basic/2`.
    * `:instructions` (optional) — extra natural-language hint prepended to
      the prompt before the schema block.
  """
  @spec extract(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def extract(prompt, opts) do
    schema = Keyword.fetch!(opts, :schema)
    validator = Keyword.get(opts, :validator, &validate_basic/2)
    instructions = Keyword.get(opts, :instructions)

    {provider_mod, opts} = Config.pop_provider!(opts)
    caps = provider_mod.capabilities()

    {augmented_prompt, request_opts} = build_request_opts(prompt, schema, instructions, caps, opts)
    request = Request.new(augmented_prompt, request_opts)

    with {:ok, response} <- provider_mod.query(request, Config.provider_opts(provider_mod, opts)),
         {:ok, json} <- extract_json(response.text, caps),
         :ok <- validator.(json, schema) do
      {:ok, json}
    end
  end

  # ── Request building ───────────────────────────────────────────────

  defp build_request_opts(prompt, schema, instructions, %{json_mode: true}, opts) do
    # Provider supports JSON mode — ask it to return JSON directly.
    full_prompt = """
    #{instructions || ""}

    Respond with a JSON object conforming to this schema:

        #{Jason.encode!(schema, pretty: true)}

    #{prompt}
    """

    {full_prompt, Keyword.put(opts, :response_format, :json)}
  end

  defp build_request_opts(prompt, schema, instructions, _caps, opts) do
    # Fenced-block fallback — bake instructions into the prompt.
    full_prompt = """
    #{instructions || ""}

    Respond with exactly one fenced JSON block:

        ~~~json
        {...}
        ~~~

    The JSON must conform to this schema:

        #{Jason.encode!(schema, pretty: true)}

    #{prompt}
    """

    {full_prompt, opts}
  end

  # ── JSON extraction ────────────────────────────────────────────────

  defp extract_json(text, %{json_mode: true}) when is_binary(text) do
    # In JSON mode we expect the whole response to be JSON. Providers often
    # still wrap it in a fence though; try raw first, then fenced.
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> extract_from_fence(text)
    end
  end

  defp extract_json(text, _caps) when is_binary(text), do: extract_from_fence(text)

  defp extract_json(_, _), do: {:error, :no_json_in_response}

  defp extract_from_fence(text) do
    case Regex.scan(@fence_regex, text, capture: :all_but_first) do
      [[json] | _] ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> {:error, :invalid_json}
        end

      _ ->
        # Try decoding the raw text as a last resort.
        case Jason.decode(text) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> {:error, :no_json_in_response}
        end
    end
  end

  # ── Basic validation ───────────────────────────────────────────────

  @doc """
  Best-effort JSON Schema validation. Enough to catch shape errors without
  pulling in a full schema validator.

  Checks:

    * Top-level `type`
    * `required` keys are present
    * Property types match (for string / integer / number / boolean / array / object)

  Does NOT check `$ref`, `oneOf`, `anyOf`, `allOf`, `patternProperties`, etc.
  Pass your own validator via the `:validator` opt for strict checking.
  """
  @spec validate_basic(map(), map()) :: :ok | {:error, term()}
  def validate_basic(json, schema) do
    with :ok <- check_type(json, Map.get(schema, "type") || Map.get(schema, :type)),
         :ok <- check_required(json, Map.get(schema, "required") || Map.get(schema, :required)),
         :ok <-
           check_properties(json, Map.get(schema, "properties") || Map.get(schema, :properties)) do
      :ok
    end
  end

  defp check_type(json, "object") when is_map(json), do: :ok
  defp check_type(json, "array") when is_list(json), do: :ok
  defp check_type(json, "string") when is_binary(json), do: :ok
  defp check_type(json, "integer") when is_integer(json), do: :ok
  defp check_type(json, "number") when is_number(json), do: :ok
  defp check_type(json, "boolean") when is_boolean(json), do: :ok
  defp check_type(_, nil), do: :ok
  defp check_type(value, type), do: {:error, {:type_mismatch, type, value}}

  defp check_required(_json, nil), do: :ok
  defp check_required(_json, []), do: :ok

  defp check_required(json, required) when is_list(required) and is_map(json) do
    missing =
      Enum.reject(required, fn key ->
        Map.has_key?(json, key) or Map.has_key?(json, to_string(key))
      end)

    if missing == [], do: :ok, else: {:error, {:missing_required_keys, missing}}
  end

  defp check_required(_, _), do: :ok

  defp check_properties(_json, nil), do: :ok

  defp check_properties(json, properties) when is_map(json) and is_map(properties) do
    Enum.reduce_while(properties, :ok, fn {key, prop_schema}, :ok ->
      value = Map.get(json, key) || Map.get(json, to_string(key))

      case value do
        nil -> {:cont, :ok}
        v -> if validate_basic(v, prop_schema) == :ok, do: {:cont, :ok}, else: {:halt, {:error, {:property_invalid, key}}}
      end
    end)
  end

  defp check_properties(_, _), do: :ok
end
