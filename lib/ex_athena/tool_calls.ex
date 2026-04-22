defmodule ExAthena.ToolCalls do
  @moduledoc """
  Extracts tool calls from a provider response.

  Two protocols, two parsers:

    * `ExAthena.ToolCalls.Native` — structured `tool_calls` array from the
      provider (OpenAI-style `function` + `arguments`, Claude `tool_use`
      blocks, Ollama's OpenAI-compatible payload).
    * `ExAthena.ToolCalls.TextTagged` — prompt-engineered
      `~~~tool_call <json> ~~~` blocks embedded in the assistant's text.

  ## Auto-fallback

  `extract/2` picks the protocol based on `provider_capabilities.native_tool_calls`.
  If native is claimed but the parser finds no tool calls AND the assistant
  text contains `~~~tool_call` fences, it falls back to TextTagged. Conversely,
  if native returns tool calls, TextTagged is skipped. The agent loop (Phase 2)
  uses `augment_system_prompt/2` to add text-tagged instructions when a
  provider lacks native support.
  """

  alias ExAthena.Messages.ToolCall
  alias ExAthena.ToolCalls.{Native, TextTagged}

  @type provider_response :: %{
          optional(:text) => String.t() | nil,
          optional(:tool_calls) => list() | nil
        }

  @doc """
  Extract tool calls from a provider response.

  Returns `{:ok, [ToolCall.t()]}` — always a list (possibly empty), never
  `nil`. Pass capabilities so the parser can pick the right protocol.
  """
  @spec extract(provider_response(), ExAthena.Capabilities.t()) ::
          {:ok, [ToolCall.t()]} | {:error, term()}
  def extract(response, capabilities \\ %{})

  def extract(%{tool_calls: [_ | _] = calls}, _caps) when is_list(calls) do
    Native.parse(calls)
  end

  def extract(%{text: text}, %{native_tool_calls: false}) when is_binary(text) do
    TextTagged.parse(text)
  end

  def extract(%{text: text}, _caps) when is_binary(text) do
    # Native was claimed (or unknown) but came back empty — look for text-tagged
    # blocks as an auto-fallback.
    if String.contains?(text || "", "~~~tool_call") do
      TextTagged.parse(text)
    else
      {:ok, []}
    end
  end

  def extract(_response, _caps), do: {:ok, []}

  @doc """
  Append text-tagged tool-call instructions to a system prompt so
  non-native-tool-call providers know how to respond.

  The agent loop (Phase 2) calls this when the chosen provider lacks native
  tool-call support, or when the user has forced TextTagged mode.
  """
  @spec augment_system_prompt(String.t() | nil, [map()]) :: String.t()
  def augment_system_prompt(existing, tools) when is_list(tools) do
    existing = existing || ""

    preamble = """
    You have access to the following tools. When you want to call a tool,
    respond with a fenced block using this exact shape — no other format is
    accepted:

        ~~~tool_call
        {"name": "<tool>", "arguments": {"arg1": "...", "arg2": "..."}}
        ~~~

    Emit one `~~~tool_call` block per call. Multiple blocks in a single
    response are allowed. When you are done using tools, respond with plain
    text only (no fences) and the runtime will stop.

    Available tools:

    #{format_tool_list(tools)}
    """

    if String.trim(existing) == "" do
      preamble
    else
      existing <> "\n\n" <> preamble
    end
  end

  defp format_tool_list(tools) do
    tools
    |> Enum.map_join("\n\n", fn tool ->
      name = Map.get(tool, :name) || Map.get(tool, "name")
      desc = Map.get(tool, :description) || Map.get(tool, "description") || ""
      schema = Map.get(tool, :schema) || Map.get(tool, "schema") || %{}

      """
      - `#{name}` — #{desc}
        Schema: #{Jason.encode!(schema)}
      """
    end)
  end
end
