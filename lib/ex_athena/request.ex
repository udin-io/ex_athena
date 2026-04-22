defmodule ExAthena.Request do
  @moduledoc """
  A normalised inference request.

  Every provider receives an `ExAthena.Request` and is responsible for mapping
  it to its own wire format. Keeping the shared shape here means callers don't
  need to think about whether they're talking to Ollama, OpenAI, or Claude.
  """

  alias ExAthena.Messages
  alias ExAthena.Messages.Message

  @enforce_keys [:messages]
  defstruct [
    :messages,
    :model,
    :system_prompt,
    :max_tokens,
    :temperature,
    :top_p,
    :stop,
    :timeout_ms,
    :tools,
    :tool_choice,
    :response_format,
    :provider_opts,
    :metadata
  ]

  @type t :: %__MODULE__{
          messages: [Message.t()],
          model: String.t() | nil,
          system_prompt: String.t() | nil,
          max_tokens: pos_integer() | nil,
          temperature: float() | nil,
          top_p: float() | nil,
          stop: [String.t()] | String.t() | nil,
          timeout_ms: pos_integer() | nil,
          tools: [map()] | nil,
          tool_choice: :auto | :any | :none | map() | nil,
          response_format: :text | :json | map() | nil,
          provider_opts: keyword() | nil,
          metadata: map() | nil
        }

  @doc """
  Build a request from a raw user prompt and options.

  The prompt is prepended to `opts[:messages]` as a user message. Pass `nil`
  to start from a pre-built message list.
  """
  @spec new(String.t() | nil, keyword()) :: t()
  def new(prompt, opts) do
    existing = opts |> Keyword.get(:messages, []) |> Enum.map(&Messages.from_map/1)

    messages =
      case prompt do
        nil -> existing
        "" -> existing
        str when is_binary(str) -> existing ++ [Messages.user(str)]
      end

    %__MODULE__{
      messages: messages,
      model: Keyword.get(opts, :model),
      system_prompt: Keyword.get(opts, :system_prompt),
      max_tokens: Keyword.get(opts, :max_tokens),
      temperature: Keyword.get(opts, :temperature),
      top_p: Keyword.get(opts, :top_p),
      stop: Keyword.get(opts, :stop),
      timeout_ms: Keyword.get(opts, :timeout_ms, 60_000),
      tools: Keyword.get(opts, :tools),
      tool_choice: Keyword.get(opts, :tool_choice),
      response_format: Keyword.get(opts, :response_format),
      provider_opts: Keyword.get(opts, :provider_opts),
      metadata: Keyword.get(opts, :metadata)
    }
  end
end
