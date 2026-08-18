defmodule ExAthena.ErrorTest do
  use ExUnit.Case, async: true

  alias ExAthena.Error

  describe "from_status/1" do
    test "maps HTTP statuses to canonical kinds" do
      for {status, kind} <- [
            {401, :unauthorized},
            {403, :unauthorized},
            {404, :not_found},
            {408, :timeout},
            {413, :context_length_exceeded},
            {429, :rate_limited},
            {400, :bad_request},
            {418, :bad_request},
            {422, :bad_request},
            {451, :bad_request},
            {500, :server_error},
            {502, :server_error},
            {503, :server_error},
            {599, :server_error},
            {200, :unknown},
            {302, :unknown}
          ] do
        assert Error.from_status(status) == kind,
               "expected #{status} -> #{inspect(kind)}, got #{inspect(Error.from_status(status))}"
      end
    end
  end

  describe "new/3" do
    test "builds a canonical error with provider/status/raw" do
      error = Error.new(:rate_limited, "slow down", provider: :req_llm, status: 429, raw: %{a: 1})

      assert %Error{
               kind: :rate_limited,
               message: "slow down",
               provider: :req_llm,
               status: 429,
               raw: %{a: 1}
             } = error
    end

    test "stores retry_after_ms when given, defaults to nil" do
      assert %Error{retry_after_ms: 30_000} =
               Error.new(:rate_limited, "slow down", retry_after_ms: 30_000)

      assert %Error{retry_after_ms: nil} = Error.new(:rate_limited, "slow down")
    end
  end

  describe "retry_after_from_headers/1" do
    test "parses delta-seconds from Req-style header maps" do
      assert Error.retry_after_from_headers(%{"retry-after" => ["30"]}) == 30_000
      assert Error.retry_after_from_headers(%{"retry-after" => ["0"]}) == 0
    end

    test "parses delta-seconds from tuple lists, case-insensitively" do
      assert Error.retry_after_from_headers([{"Retry-After", "5"}]) == 5_000
      assert Error.retry_after_from_headers([{"RETRY-AFTER", ["12"]}]) == 12_000
    end

    test "parses the HTTP-date form as a delay from now" do
      future = DateTime.add(DateTime.utc_now(), 60, :second)
      header = Calendar.strftime(future, "%a, %d %b %Y %H:%M:%S GMT")

      ms = Error.retry_after_from_headers(%{"retry-after" => [header]})
      assert is_integer(ms)
      assert ms > 50_000 and ms <= 60_000
    end

    test "an HTTP-date in the past clamps to 0" do
      past = DateTime.add(DateTime.utc_now(), -3_600, :second)
      header = Calendar.strftime(past, "%a, %d %b %Y %H:%M:%S GMT")

      assert Error.retry_after_from_headers([{"retry-after", header}]) == 0
    end

    test "returns nil for missing, empty, malformed, or negative values" do
      assert Error.retry_after_from_headers(%{}) == nil
      assert Error.retry_after_from_headers(%{"retry-after" => []}) == nil
      assert Error.retry_after_from_headers(%{"retry-after" => ["soon"]}) == nil
      assert Error.retry_after_from_headers(%{"retry-after" => ["-5"]}) == nil
      assert Error.retry_after_from_headers(%{"content-type" => ["application/json"]}) == nil
      assert Error.retry_after_from_headers(nil) == nil
    end
  end

  describe "retry_delay_ms/2" do
    test "honors the server hint when present" do
      error = Error.new(:rate_limited, "slow down", retry_after_ms: 5_000)
      assert Error.retry_delay_ms(error) == 5_000
    end

    test "caps a hostile/huge hint at 30s by default" do
      error = Error.new(:rate_limited, "slow down", retry_after_ms: 999_999_999)
      assert Error.retry_delay_ms(error) == 30_000
    end

    test "falls back to the 2s default when the hint is absent" do
      assert Error.retry_delay_ms(Error.new(:server_error, "boom")) == 2_000
    end

    test "falls back to the default for non-Error terms" do
      assert Error.retry_delay_ms(:timeout) == 2_000
      assert Error.retry_delay_ms({:unexpected, 42}) == 2_000
    end

    test "accepts :default and :cap overrides" do
      error = Error.new(:rate_limited, "slow down", retry_after_ms: 10_000)
      assert Error.retry_delay_ms(error, cap: 4_000) == 4_000
      assert Error.retry_delay_ms(:other, default: 100) == 100
    end
  end
end
