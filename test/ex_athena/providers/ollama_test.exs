defmodule ExAthena.Providers.OllamaTest do
  use ExUnit.Case, async: true

  alias ExAthena.{Request, Response}
  alias ExAthena.Providers.Ollama

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  test "query/2 sends POST /api/chat and parses the response", %{bypass: bypass, base_url: base} do
    Bypass.expect_once(bypass, "POST", "/api/chat", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      assert decoded["model"] == "test-model"
      assert decoded["stream"] == false
      assert decoded["messages"] == [%{"role" => "user", "content" => "ping"}]

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "model" => "test-model",
          "message" => %{"role" => "assistant", "content" => "pong"},
          "done" => true,
          "prompt_eval_count" => 4,
          "eval_count" => 5
        })
      )
    end)

    request = Request.new("ping", model: "test-model", timeout_ms: 5_000)

    assert {:ok, %Response{text: "pong", finish_reason: :stop, usage: usage}} =
             Ollama.query(request, base_url: base)

    assert usage.input_tokens == 4
    assert usage.output_tokens == 5
    assert usage.total_tokens == 9
  end

  test "query/2 returns canonical error on HTTP 401", %{bypass: bypass, base_url: base} do
    Bypass.expect_once(bypass, "POST", "/api/chat", fn conn ->
      Plug.Conn.resp(conn, 401, Jason.encode!(%{"error" => "unauthorized"}))
    end)

    request = Request.new("hi", model: "x", timeout_ms: 5_000)

    assert {:error, %ExAthena.Error{kind: :unauthorized, status: 401}} =
             Ollama.query(request, base_url: base)
  end

  test "query/2 returns transport error when server is down", %{base_url: _} do
    request = Request.new("hi", model: "x", timeout_ms: 1_000)

    # Point at a closed port
    assert {:error, %ExAthena.Error{kind: :transport}} =
             Ollama.query(request, base_url: "http://localhost:1")
  end

  test "query/2 surfaces native tool_calls", %{bypass: bypass, base_url: base} do
    Bypass.expect_once(bypass, "POST", "/api/chat", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "model" => "test",
          "message" => %{
            "role" => "assistant",
            "content" => "",
            "tool_calls" => [
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{"name" => "read", "arguments" => ~s({"path": "/tmp"})}
              }
            ]
          },
          "done" => true
        })
      )
    end)

    request = Request.new("read /tmp", model: "test", timeout_ms: 5_000)

    assert {:ok, %Response{tool_calls: [%{name: "read", arguments: %{"path" => "/tmp"}}]}} =
             Ollama.query(request, base_url: base)
  end
end
