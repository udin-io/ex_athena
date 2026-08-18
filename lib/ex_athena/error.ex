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

  defstruct [:kind, :message, :provider, :status, :retry_after_ms, :raw]

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          provider: atom() | module() | nil,
          status: integer() | nil,
          retry_after_ms: non_neg_integer() | nil,
          raw: term() | nil
        }

  # Default backoff before retrying a transient provider error, and the cap
  # applied to server-supplied Retry-After hints. The cap exists so a hostile
  # or misconfigured server can't stall a run for minutes/hours with one
  # header; 30s comfortably covers real rate-limit windows while keeping the
  # loop's single transient retry bounded.
  @default_retry_delay_ms 2_000
  @retry_after_cap_ms 30_000

  @doc "Build a canonical error."
  @spec new(kind(), String.t(), keyword()) :: t()
  def new(kind, message, opts \\ []) do
    %__MODULE__{
      kind: kind,
      message: message,
      provider: Keyword.get(opts, :provider),
      status: Keyword.get(opts, :status),
      retry_after_ms: Keyword.get(opts, :retry_after_ms),
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

  @doc """
  Extract a `Retry-After` hint (in milliseconds) from HTTP response headers.

  Accepts Req-style header maps (`%{"retry-after" => ["30"]}`) or tuple
  lists (`[{"Retry-After", "30"}]`), matching the header name
  case-insensitively. Both RFC 9110 value forms are supported:

    * delta-seconds — `"30"` → `30_000`
    * HTTP-date (IMF-fixdate) — `"Sun, 06 Nov 1994 08:49:37 GMT"` → the
      delay from now, clamped to `0` for dates in the past

  Returns `nil` when the header is absent or unparseable.
  """
  @spec retry_after_from_headers(term()) :: non_neg_integer() | nil
  def retry_after_from_headers(headers) when is_map(headers) or is_list(headers) do
    headers
    |> Enum.find_value(fn
      {name, value} ->
        if String.downcase(to_string(name)) == "retry-after", do: value

      _ ->
        nil
    end)
    |> case do
      [value | _] -> parse_retry_after(to_string(value))
      value when is_binary(value) -> parse_retry_after(value)
      _ -> nil
    end
  end

  def retry_after_from_headers(_), do: nil

  @doc """
  Delay (ms) to honor before retrying a transient provider error.

  Uses the server's `retry_after_ms` hint when the error carries one,
  bounded by `:cap` (default #{@retry_after_cap_ms}ms) so a hostile or huge
  `Retry-After` header can't stall a run. Falls back to `:default`
  (#{@default_retry_delay_ms}ms) when the hint is absent or the term isn't
  an `ExAthena.Error`.
  """
  @spec retry_delay_ms(term(), keyword()) :: non_neg_integer()
  def retry_delay_ms(error, opts \\ [])

  def retry_delay_ms(%__MODULE__{retry_after_ms: ms}, opts) when is_integer(ms) and ms >= 0 do
    min(ms, Keyword.get(opts, :cap, @retry_after_cap_ms))
  end

  def retry_delay_ms(_other, opts), do: Keyword.get(opts, :default, @default_retry_delay_ms)

  # ── Retry-After parsing ───────────────────────────────────────────

  defp parse_retry_after(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> parse_http_date_delay(trimmed)
    end
  end

  defp parse_http_date_delay(value) do
    case parse_imf_fixdate(value) do
      {:ok, dt} -> dt |> DateTime.diff(DateTime.utc_now(), :millisecond) |> max(0)
      :error -> nil
    end
  end

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  # RFC 9110 IMF-fixdate: "Sun, 06 Nov 1994 08:49:37 GMT" — the only
  # obsolete-free HTTP-date form servers are required to emit.
  defp parse_imf_fixdate(
         <<_wkday::binary-size(3), ", ", dd::binary-size(2), " ", mon::binary-size(3), " ",
           yyyy::binary-size(4), " ", hh::binary-size(2), ":", mi::binary-size(2), ":",
           ss::binary-size(2), " GMT">>
       ) do
    with {:ok, month} <- Map.fetch(@months, mon),
         {day, ""} <- Integer.parse(dd),
         {year, ""} <- Integer.parse(yyyy),
         {hour, ""} <- Integer.parse(hh),
         {minute, ""} <- Integer.parse(mi),
         {second, ""} <- Integer.parse(ss),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, dt} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, dt}
    else
      _ -> :error
    end
  end

  defp parse_imf_fixdate(_), do: :error
end
