defmodule ExAthena.Tools.WebFetch do
  @moduledoc """
  HTTP GET via `Req`, returning the body as text.

  Arguments:

    * `url` (required) — `http://` or `https://` only; other schemes rejected.
    * `timeout_ms` (optional, default 10_000).

  Response body capped at 1 MB. Redirects followed up to 5 hops.

  This is deliberately minimal — it's here so agents can fetch documentation
  pages, not to replace a full HTTP client. For richer access (auth headers,
  POST bodies, etc.), implement a custom tool that wraps `Req` directly.
  """

  @behaviour ExAthena.Tool

  @default_timeout 10_000
  @max_bytes 1_000_000

  @impl true
  def name, do: "web_fetch"

  @impl true
  def description,
    do: "GET a public URL (http/https only). Returns up to 1 MB of body text."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        url: %{type: "string"},
        timeout_ms: %{type: "integer"}
      },
      required: ["url"]
    }
  end

  @impl true
  def parallel_safe?, do: true

  @impl true
  def execute(%{"url" => url} = args, _ctx) when is_binary(url) do
    timeout = Map.get(args, "timeout_ms", @default_timeout)

    with {:ok, uri} <- validate(url),
         {:ok, body} <- fetch(uri, timeout) do
      {:ok, body}
    end
  end

  def execute(_, _), do: {:error, :missing_url}

  defp validate(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] -> {:error, {:invalid_scheme, uri.scheme}}
      is_nil(uri.host) or uri.host == "" -> {:error, :missing_host}
      true -> {:ok, uri}
    end
  end

  defp fetch(uri, timeout) do
    case Req.get(URI.to_string(uri),
           receive_timeout: timeout,
           max_redirects: 5,
           retry: false,
           decode_body: false
         ) do
      {:ok, %Req.Response{status: s, body: body}} when s in 200..299 ->
        body = to_binary(body)

        if byte_size(body) > @max_bytes do
          {:ok, binary_part(body, 0, @max_bytes) <> "\n\n[...truncated...]"}
        else
          {:ok, body}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, exception} ->
        {:error, {:fetch_failed, Exception.message(exception)}}
    end
  end

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body), do: inspect(body)
end
