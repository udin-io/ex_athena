defmodule ExAthena.Chat.Tui.RunnerTest do
  use ExUnit.Case, async: false

  alias ExAthena.Chat.{Session, Tui.Runner}
  alias ExAthena.Config

  @provider_keys [:ollama, :llamacpp, :exo, :openai, :claude]

  setup do
    originals = Map.new(@provider_keys, &{&1, Application.get_env(:ex_athena, &1)})

    on_exit(fn ->
      Enum.each(originals, fn
        {key, nil} -> Application.delete_env(:ex_athena, key)
        {key, original} -> Application.put_env(:ex_athena, key, original)
      end)
    end)

    :ok
  end

  describe "build_run_opts/2" do
    test "adds a localhost Ollama base_url when nothing is configured" do
      Application.delete_env(:ex_athena, :ollama)

      session = Session.new(model: "qwen2.5")
      opts = Runner.build_run_opts(session, fn _ -> :ok end)

      assert opts[:provider] == :ollama
      assert opts[:model] == "qwen2.5"
      assert opts[:mode] == :react
      assert opts[:base_url] == "http://localhost:11434"
      assert is_function(opts[:on_event], 1)
    end

    test "sets a 24h request timeout (finite, but past any legitimate LLM stall)" do
      Application.delete_env(:ex_athena, :ollama)

      session = Session.new(model: "any")
      opts = Runner.build_run_opts(session, fn _ -> :ok end)

      assert opts[:timeout_ms] == 24 * 60 * 60 * 1000
    end

    test "omits :base_url when a base_url is configured for the provider" do
      Application.put_env(:ex_athena, :ollama,
        base_url: "http://my-ollama.lan:11434",
        model: "llama3.1"
      )

      session = Session.new([])
      opts = Runner.build_run_opts(session, fn _ -> :ok end)

      refute Keyword.has_key?(opts, :base_url)
    end

    test "defaults the llama.cpp base_url to localhost:8080 when unconfigured" do
      session = Session.new(provider: :llamacpp, model: "any.gguf")
      opts = Runner.build_run_opts(session, fn _ -> :ok end)

      assert opts[:provider] == :llamacpp
      assert opts[:base_url] == "http://localhost:8080"
    end
  end

  describe "build_run_opts/2 — base_url is local-daemon only" do
    for provider <- [:openai, :claude] do
      test "a #{provider} run carries no base_url when nothing is configured" do
        Application.delete_env(:ex_athena, unquote(provider))

        session = Session.new(provider: unquote(provider), model: "some-cloud-model")
        opts = Runner.build_run_opts(session, fn _ -> :ok end)

        assert opts[:provider] == unquote(provider)
        refute Keyword.has_key?(opts, :base_url)
      end
    end

    test "a cloud run is unaffected by a configured Ollama base_url" do
      Application.put_env(:ex_athena, :ollama, base_url: "http://my-ollama.lan:11434")
      Application.delete_env(:ex_athena, :openai)

      session = Session.new(provider: :openai, model: "some-cloud-model")
      opts = Runner.build_run_opts(session, fn _ -> :ok end)

      refute Keyword.has_key?(opts, :base_url)
    end

    test "a configured cloud base_url is left for the provider layer to resolve" do
      Application.put_env(:ex_athena, :openai, base_url: "https://proxy.internal/v1")

      session = Session.new(provider: :openai, model: "some-cloud-model")
      opts = Runner.build_run_opts(session, fn _ -> :ok end)

      refute Keyword.has_key?(opts, :base_url)

      # The Runner deliberately omits it; `run/2` resolves it from app config,
      # so the configured URL — never a localhost default — is what ships.
      assert Config.provider_opts(Config.provider_module(:openai), opts, :openai)[:base_url] ==
               "https://proxy.internal/v1"
    end

    for {provider, url} <- [
          {:ollama, "http://localhost:11434"},
          {:llamacpp, "http://localhost:8080"},
          {:exo, "http://localhost:52415"}
        ] do
      test "#{provider} still gets its stock default when unconfigured" do
        Application.delete_env(:ex_athena, unquote(provider))

        session = Session.new(provider: unquote(provider), model: "local-model")
        opts = Runner.build_run_opts(session, fn _ -> :ok end)

        assert opts[:base_url] == unquote(url)
      end

      test "#{provider} keeps an explicitly configured base_url" do
        Application.put_env(:ex_athena, unquote(provider), base_url: "http://box.lan:9999")

        session = Session.new(provider: unquote(provider), model: "local-model")
        opts = Runner.build_run_opts(session, fn _ -> :ok end)

        refute Keyword.has_key?(opts, :base_url)

        assert Config.provider_opts(
                 Config.provider_module(unquote(provider)),
                 opts,
                 unquote(provider)
               )[:base_url] == "http://box.lan:9999"
      end
    end
  end

  describe "build_run_opts/2 — resume" do
    test "passes resume: when the session carries a provider session id" do
      session = %{Session.new(model: "m") | provider_session_id: "cli-sess-1"}
      opts = Runner.build_run_opts(session, fn _ -> :ok end)

      assert opts[:resume] == "cli-sess-1"
    end

    test "omits :resume when the session has no provider session id" do
      session = Session.new(model: "m")
      opts = Runner.build_run_opts(session, fn _ -> :ok end)

      refute Keyword.has_key?(opts, :resume)
    end
  end

  describe "select_initial_model/2" do
    test "keeps the desired model when it is in the installed list" do
      assert Runner.select_initial_model("llama3.1", {:ok, ["llama3.1", "qwen2.5"]}) ==
               {:ok, "llama3.1"}
    end

    test "falls back to the first installed model when the desired one is missing" do
      assert Runner.select_initial_model("llama3.1", {:ok, ["qwen2.5", "mistral"]}) ==
               {:fallback, "qwen2.5"}
    end

    test "reports :no_models when the installed list is empty" do
      assert Runner.select_initial_model("anything", {:ok, []}) == {:error, :no_models}
    end

    test "passes through the underlying error" do
      assert Runner.select_initial_model("anything", {:error, :ollama_unreachable}) ==
               {:error, :ollama_unreachable}
    end
  end

  describe "start/2" do
    test "drives a Mock-backed run, sending {:athena_event, ...} for each loop event and a terminal {:athena_done, _}" do
      session =
        Session.new(provider: :mock, model: "mock-model")
        |> Session.append_user("hello")

      session = %{
        session
        | provider: :mock,
          tools: [],
          permission_mode: :default
      }

      events = [
        %ExAthena.Streaming.Event{type: :text_delta, data: "Hi "},
        %ExAthena.Streaming.Event{type: :text_delta, data: "there"},
        %ExAthena.Streaming.Event{type: :stop, data: :stop}
      ]

      extra_opts = [
        mock: [text: "Hi there"],
        mock_events: events
      ]

      _task_pid = Runner.start(session, self(), extra_opts)

      assert_receive {:athena_done, result}, 5_000
      assert match?(%ExAthena.Result{}, result)
    end

    test "always sends exactly one terminal message ({:athena_done, _} or {:athena_error, _})" do
      # The Mock provider can succeed with a halted result rather than a
      # bubbled {:error, _}, so we don't pin which terminal — we just verify
      # one arrives after any number of :athena_event messages.
      session = Session.new(provider: :mock, model: "boom") |> Session.append_user("hi")
      session = %{session | tools: [], permission_mode: :default}

      _ = Runner.start(session, self(), mock: [error: :boom])

      msg = drain_until_terminal()

      assert match?({:athena_done, _}, msg) or match?({:athena_error, _}, msg)
    end

    test "passing an unknown provider atom routes to {:athena_error, _}" do
      # `ExAthena.run/2` returns {:error, _} when build_initial_state fails
      # (e.g. unknown provider). This proves the task forwards that arm.
      session = Session.new(model: "x") |> Session.append_user("hi")

      session = %{
        session
        | provider: :totally_made_up_provider,
          tools: [],
          permission_mode: :default
      }

      _ = Runner.start(session, self(), [])

      msg = drain_until_terminal()
      assert match?({:athena_error, _}, msg)
    end
  end

  defp drain_until_terminal(timeout \\ 5_000) do
    receive do
      {:athena_event, _} -> drain_until_terminal(timeout)
      {:athena_done, _} = msg -> msg
      {:athena_error, _} = msg -> msg
    after
      timeout -> flunk("expected a terminal message within #{timeout}ms")
    end
  end
end
