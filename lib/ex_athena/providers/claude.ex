defmodule ExAthena.Providers.Claude do
  @moduledoc """
  Anthropic Claude provider — thin wrapper around the `claude_code` SDK.

  This provider preserves everything the SDK does natively: native tool_use
  blocks, hooks, `can_use_tool` callbacks, MCP servers, session resume,
  prompt cache reuse. In Phase 3 (udin migration), the existing udin hooks /
  MCP server configs slot in here via `:provider_opts`.

  ## Configuration

      config :ex_athena, :claude,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        model: "claude-opus-4-5"

  `claude_code` must be available as a dep. It's declared `optional: true`
  on `ex_athena`, so consumers that don't use Claude don't need to install it.
  """

  @behaviour ExAthena.Provider

  alias ExAthena.{Config, Error, Response}
  alias ExAthena.Messages.Message

  @impl ExAthena.Provider
  def capabilities do
    %{
      native_tool_calls: true,
      streaming: true,
      json_mode: false,
      max_tokens: 200_000,
      supports_resume: true,
      supports_system_prompt: true,
      supports_temperature: true
    }
  end

  @impl ExAthena.Provider
  def query(request, opts) do
    ensure_claude_code!()

    prompt = build_prompt(request)
    sdk_opts = build_sdk_opts(request, opts)

    case apply(ClaudeCode, :query, [prompt, sdk_opts]) do
      {:ok, result} ->
        {:ok, to_response(result, request)}

      {:error, reason} ->
        {:error,
         Error.new(:server_error, "Claude query failed: #{inspect(reason)}",
           provider: :claude,
           raw: reason
         )}
    end
  end

  @impl ExAthena.Provider
  def stream(_request, _callback, _opts) do
    # ClaudeCode.stream requires a live session — the richer stream integration
    # lands in Phase 2 as part of ExAthena.Session. For Phase 1 we surface a
    # clear capability error.
    {:error,
     Error.new(:capability, "Claude streaming ships in ExAthena Phase 2. Use query/3 for now.",
       provider: :claude
     )}
  end

  # ── Internal ──────────────────────────────────────────────────────

  defp ensure_claude_code! do
    if not Code.ensure_loaded?(ClaudeCode) do
      raise ArgumentError,
            "ExAthena.Providers.Claude requires the `claude_code` dep. Add " <>
              "`{:claude_code, \"~> 0.36\"}` to your deps."
    end
  end

  # Collapse the message list into a single prompt. The SDK expects a prompt
  # string and manages conversation internally via sessions. We flatten here
  # and preserve the final user turn. This is a Phase 1 simplification —
  # Phase 2 sessions will use the native multi-turn API.
  defp build_prompt(%{messages: messages}) do
    messages
    |> Enum.map_join("\n\n", &render_message/1)
    |> String.trim()
  end

  defp render_message(%Message{role: :user, content: c}), do: "User: " <> (c || "")
  defp render_message(%Message{role: :assistant, content: c}), do: "Assistant: " <> (c || "")
  defp render_message(%Message{role: :system, content: c}), do: "System: " <> (c || "")
  defp render_message(%Message{role: :tool, tool_results: [first | _]}),
    do: "Tool result: " <> (first.content || "")

  defp render_message(_), do: ""

  defp build_sdk_opts(request, opts) do
    sdk_opts =
      [
        api_key: Config.get(__MODULE__, :api_key, opts),
        model: request.model || Config.get(__MODULE__, :model, opts),
        system_prompt: request.system_prompt,
        max_turns: 1
      ]
      |> Keyword.reject(fn {_k, v} -> is_nil(v) end)

    # Allow callers to slot any additional SDK options through :provider_opts —
    # that's how udin passes hooks, can_use_tool, MCP servers, permission_mode.
    provider_opts = Keyword.get(opts, :provider_opts, [])
    Keyword.merge(sdk_opts, provider_opts)
  end

  defp to_response(%{result: text} = raw, request) when is_binary(text) do
    %Response{
      text: text,
      tool_calls: [],
      finish_reason: :stop,
      model: request.model,
      provider: :claude,
      raw: raw
    }
  end

  defp to_response(raw, request) do
    %Response{
      text: to_string(raw),
      tool_calls: [],
      finish_reason: :stop,
      model: request.model,
      provider: :claude,
      raw: raw
    }
  end
end
