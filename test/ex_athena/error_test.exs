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
  end
end
