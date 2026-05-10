defmodule ExAthena.Providers.GeminiLiveTest do
  use ExUnit.Case, async: false

  @moduletag :external

  test "live gemini call returns a Response" do
    api_key = System.fetch_env!("GEMINI_API_KEY")

    assert {:ok, %ExAthena.Response{}} =
             ExAthena.query("ping",
               provider: :gemini,
               model: "gemini-2.5-flash",
               api_key: api_key
             )
  end
end
