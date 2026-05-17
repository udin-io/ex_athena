defmodule ExAthena.Messages.ContentPart do
  @moduledoc """
  A single piece of content within a message — text, inline image, image URL, or file.

  Provider-agnostic counterpart to `ReqLLM.Message.ContentPart`. The req_llm adapter
  maps each variant to the matching `ReqLLM.Message.ContentPart` factory.
  """

  @enforce_keys [:type]
  defstruct [:type, :text, :url, :data, :media_type, :filename]

  @type type :: :text | :image | :image_url | :file

  @type t :: %__MODULE__{
          type: type(),
          text: String.t() | nil,
          url: String.t() | nil,
          data: binary() | nil,
          media_type: String.t() | nil,
          filename: String.t() | nil
        }

  @spec text(String.t()) :: t()
  def text(content), do: %__MODULE__{type: :text, text: content}

  @spec image(binary(), String.t()) :: t()
  def image(data, media_type \\ "image/png"),
    do: %__MODULE__{type: :image, data: data, media_type: media_type}

  @spec image_url(String.t()) :: t()
  def image_url(url), do: %__MODULE__{type: :image_url, url: url}

  @spec file(binary(), String.t(), String.t()) :: t()
  def file(data, filename, media_type \\ "application/octet-stream"),
    do: %__MODULE__{type: :file, data: data, filename: filename, media_type: media_type}
end
