defmodule ExAthena.Error do
  @moduledoc "Canonical error surface across providers."

  @type kind ::
          :unauthorized
          | :not_found
          | :rate_limited
          | :timeout
          | :context_length_exceeded
          | :bad_request
          | :server_error
          | :transport
          | :capability
          | :unknown

  defstruct [:kind, :message, :provider, :status, :raw]

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          provider: atom() | module() | nil,
          status: integer() | nil,
          raw: term() | nil
        }

  @doc "Build a canonical error."
  @spec new(kind(), String.t(), keyword()) :: t()
  def new(kind, message, opts \\ []) do
    %__MODULE__{
      kind: kind,
      message: message,
      provider: Keyword.get(opts, :provider),
      status: Keyword.get(opts, :status),
      raw: Keyword.get(opts, :raw)
    }
  end

  @doc """
  Classify an HTTP status code into an error kind.

  Used by providers that share the OpenAI-style response shape.
  """
  @spec from_status(integer()) :: kind()
  def from_status(401), do: :unauthorized
  def from_status(403), do: :unauthorized
  def from_status(404), do: :not_found
  def from_status(408), do: :timeout
  def from_status(429), do: :rate_limited
  def from_status(413), do: :context_length_exceeded
  def from_status(status) when status in 400..499, do: :bad_request
  def from_status(status) when status in 500..599, do: :server_error
  def from_status(_), do: :unknown
end
