defmodule ExAthena.ListModelsTest do
  use ExUnit.Case, async: false

  alias ExAthena.{Error, Model, ModelDiscovery}

  setup do
    ModelDiscovery.clear_cache()
    bypass = Bypass.open()

    on_exit(fn ->
      Application.delete_env(:ex_athena, :ollama)
      Application.delete_env(:ex_athena, :default_provider)
    end)

    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp tags(conn, names) do
    body = Jason.encode!(%{"models" => Enum.map(names, &%{"name" => &1})})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, body)
  end

  test "lists a provider's models using its configured base_url", ctx do
    Application.put_env(:ex_athena, :ollama, base_url: ctx.base_url)

    Bypass.expect_once(ctx.bypass, "GET", "/api/tags", fn conn ->
      tags(conn, ["qwen3-coder:30b", "llama3.1:latest"])
    end)

    assert {:ok, models} = ExAthena.list_models(:ollama)
    assert Enum.map(models, & &1.id) == ["llama3.1:latest", "qwen3-coder:30b"]
    assert Enum.all?(models, &match?(%Model{}, &1))
  end

  test "per-call opts override configuration", ctx do
    Application.put_env(:ex_athena, :ollama, base_url: "http://127.0.0.1:1")

    Bypass.expect_once(ctx.bypass, "GET", "/api/tags", fn conn ->
      tags(conn, ["override"])
    end)

    assert {:ok, [%Model{id: "override"}]} =
             ExAthena.list_models(:ollama, base_url: ctx.base_url)
  end

  test "falls back to the default provider when none is given", ctx do
    Application.put_env(:ex_athena, :default_provider, :ollama)
    Application.put_env(:ex_athena, :ollama, base_url: ctx.base_url)

    Bypass.expect_once(ctx.bypass, "GET", "/api/tags", fn conn ->
      tags(conn, ["default-provider-model"])
    end)

    assert {:ok, [%Model{id: "default-provider-model"}]} = ExAthena.list_models()
  end

  # Regression for #189: pre-#183 the per-backend shims defaulted the local
  # daemons' base URLs, so listing worked on a stock setup with zero config.
  # The plug intercepts before any network I/O, so these tests observe exactly
  # which host the request would target without needing the daemon (or the
  # port) to exist.
  describe "local daemon base-url defaults" do
    defp capture_plug(test_pid, body) do
      fn conn ->
        send(test_pid, {:req, conn.host, conn.port, conn.request_path, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end
    end

    test "ollama defaults to http://localhost:11434 when nothing is configured" do
      plug = capture_plug(self(), %{"models" => [%{"name" => "qwen3-coder:30b"}]})

      assert {:ok, [%Model{id: "qwen3-coder:30b"}]} =
               ExAthena.list_models(:ollama, cache: false, req_options: [plug: plug])

      assert_received {:req, "localhost", 11_434, "/api/tags", _}
    end

    test "llamacpp defaults to http://localhost:8080 when nothing is configured" do
      plug = capture_plug(self(), %{"data" => [%{"id" => "qwen3.gguf"}]})

      assert {:ok, [%Model{id: "qwen3.gguf"}]} =
               ExAthena.list_models(:llamacpp, cache: false, req_options: [plug: plug])

      assert_received {:req, "localhost", 8080, "/v1/models", _}
    end

    test "exo defaults to http://localhost:52415 when nothing is configured" do
      plug = capture_plug(self(), %{"data" => [%{"id" => "mlx-community/Llama-3.2-1B"}]})

      assert {:ok, [%Model{id: "mlx-community/Llama-3.2-1B"}]} =
               ExAthena.list_models(:exo, cache: false, req_options: [plug: plug])

      assert_received {:req, "localhost", 52_415, "/v1/models", "status=downloaded"}
    end

    test "a configured base_url always beats the local-daemon default" do
      Application.put_env(:ex_athena, :ollama, base_url: "http://localhost:9999")
      plug = capture_plug(self(), %{"models" => [%{"name" => "configured"}]})

      assert {:ok, [%Model{id: "configured"}]} =
               ExAthena.list_models(:ollama, cache: false, req_options: [plug: plug])

      assert_received {:req, "localhost", 9999, "/api/tags", _}
    end

    test "cloud providers gain no localhost default and stay on the catalog" do
      assert {:ok, models} = ExAthena.list_models(:openai, cache: false)

      assert models != []
      assert Enum.all?(models, &(&1.source == :catalog))
    end
  end

  test "wraps a provider that only implements the zero-arity callback" do
    # ClaudeCode enumerates a fixed CLI-reported set; it has no list_models/1.
    Application.put_env(:ex_athena, :claude_code_model_source, __MODULE__.StubSource)
    on_exit(fn -> Application.delete_env(:ex_athena, :claude_code_model_source) end)

    assert {:ok, models} = ExAthena.list_models(:claude_code)

    assert [%Model{id: "claude-opus-4-8", provider: :claude_code, source: :catalog}] = models
  end

  test "reports a capability error for a provider that cannot enumerate models" do
    assert {:error, %Error{kind: :capability}} = ExAthena.list_models(:mock)
  end

  test "surfaces listing failures rather than pretending the list is empty" do
    Application.put_env(:ex_athena, :ollama, base_url: "http://127.0.0.1:1")

    assert {:error, %Error{kind: :transport}} = ExAthena.list_models(:ollama)
  end

  defmodule StubSource do
    @behaviour ExAthena.Providers.ClaudeCode.ModelSource

    @impl true
    def supported_models, do: {:ok, [%{value: "claude-opus-4-8"}]}
  end
end
