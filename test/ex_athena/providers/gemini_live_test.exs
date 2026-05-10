defmodule ExAthena.Providers.GeminiLiveTest do
  use ExUnit.Case, async: false

  @moduletag :external

  test "live gemini call returns a Response" do
    api_key = System.fetch_env!("GEMINI_API_KEY")

    assert {:ok, %ExAthena.Response{} = resp} =
             ExAthena.query("ping",
               provider: :gemini,
               model: "gemini-2.5-flash",
               api_key: api_key
             )

    assert is_binary(resp.text) and resp.text != ""
    assert resp.finish_reason in [:stop, :length]
  end
end
