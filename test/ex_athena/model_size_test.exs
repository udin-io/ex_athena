defmodule ExAthena.ModelSizeTest do
  use ExUnit.Case, async: false

  alias ExAthena.ModelSize

  doctest ExAthena.ModelSize

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  # The body Ollama 0.32 returned for qwen2.5-coder:14b, cut to the fields read.
  defp show(conn, size) do
    body = Jason.encode!(%{"details" => %{"family" => "qwen2", "parameter_size" => size}})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, body)
  end

  test "names without a size read as unknown" do
    for name <- [
          "qwen2.5-coder",
          "gpt-4o",
          "claude-sonnet-4",
          "llama3.2:latest",
          "claude-sonnet-4-5[1m]",
          "llama-4-scout:1m",
          nil
        ] do
      assert ModelSize.from_name(name) == nil, inspect(name)
    end
  end

  test "a size in the name wins and asks no server" do
    assert ModelSize.lookup(model: "llama3.2:3b", openai_compatible_backend: :ollama) == 3.0
  end

  test "an Ollama model with no size in its name is asked once",
       %{bypass: bypass, base_url: base_url} do
    model = "custom-coder-#{System.unique_integer([:positive])}"
    Bypass.expect_once(bypass, "POST", "/api/show", &show(&1, "14.8B"))

    opts = [model: model, openai_compatible_backend: :ollama, base_url: base_url <> "/v1"]

    assert ModelSize.lookup(opts) == 14.8
    assert ModelSize.lookup(opts) == 14.8
  end

  test "an Ollama answer without a size reads as unknown",
       %{bypass: bypass, base_url: base_url} do
    model = "no-size-#{System.unique_integer([:positive])}"

    Bypass.expect_once(bypass, "POST", "/api/show", fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"error":"model not found"}))
    end)

    assert ModelSize.lookup(model: model, openai_compatible_backend: :ollama, base_url: base_url) ==
             nil
  end

  test "a down server reads as unknown", %{bypass: bypass, base_url: base_url} do
    Bypass.down(bypass)
    model = "down-#{System.unique_integer([:positive])}"

    assert ModelSize.lookup(model: model, openai_compatible_backend: :ollama, base_url: base_url) ==
             nil
  end

  test "the provider tag comes off the name before Ollama is asked",
       %{bypass: bypass, base_url: base_url} do
    model = "tagged-#{System.unique_integer([:positive])}"

    Bypass.expect_once(bypass, "POST", "/api/show", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["model"] == model
      show(conn, "268.10M")
    end)

    assert ModelSize.lookup(
             model: "ollama:" <> model,
             req_llm_provider_tag: "ollama",
             openai_compatible_backend: :ollama,
             base_url: base_url
           ) == 0.2681
  end

  test "with no base URL the configured Ollama address is asked",
       %{bypass: bypass, base_url: base_url} do
    previous = Application.get_env(:ex_athena, :ollama)
    Application.put_env(:ex_athena, :ollama, base_url: base_url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ex_athena, :ollama, previous),
        else: Application.delete_env(:ex_athena, :ollama)
    end)

    model = "configured-#{System.unique_integer([:positive])}"
    Bypass.expect_once(bypass, "POST", "/api/show", &show(&1, "7.6B"))

    assert ModelSize.lookup(model: model, openai_compatible_backend: :ollama) == 7.6
  end

  # A listener that accepts and never answers: a hung server.
  defp silent_server do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test_pid = self()

    pid =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        send(test_pid, :asked)
        receive do: (:stop -> :gen_tcp.close(socket))
      end)

    on_exit(fn ->
      send(pid, :stop)
      :gen_tcp.close(listen)
    end)

    "http://localhost:#{port}"
  end

  test "a server that does not answer in time reads as unknown, and is not asked again at once" do
    model = "slow-#{System.unique_integer([:positive])}"
    opts = [model: model, openai_compatible_backend: :ollama, base_url: silent_server()]

    {micros, size} = :timer.tc(fn -> ModelSize.lookup(opts) end)

    assert size == nil
    assert micros < 4_500_000
    {again, nil} = :timer.tc(fn -> ModelSize.lookup(opts) end)
    assert again < 500_000
    assert_received :asked
  end

  test "only Ollama is asked" do
    assert ModelSize.lookup(model: "my-model", openai_compatible_backend: :llamacpp) == nil
  end
end
