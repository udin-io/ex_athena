defmodule ExAthena.Chat.Repl do
  @moduledoc """
  Interactive REPL driver for `mix athena.chat`.

  Sets up `Owl.LiveScreen` with a pinned status block, reads input lines
  from stdin, dispatches slash commands, and routes free-form prompts through
  `ExAthena.run/2` while streaming tokens, tool calls, and tool results to the
  terminal via `ExAthena.Chat.Renderer`.

  Thin glue around the pure modules; manual smoke-test only.
  """

  alias ExAthena.Chat.{Commands, Ollama, Renderer, Session}
  alias ExAthena.Tools

  @modes [:react, :plan_and_solve, :reflexion]

  @spec start(keyword()) :: :ok
  def start(opts \\ []) do
    {:ok, _pid} = ensure_live_screen_started()
    Owl.LiveScreen.add_block(:status, render: &render_status_block/1)

    session = opts |> Session.new() |> reconcile_model_with_ollama()
    update_status(session)
    print_banner(session)

    loop(session)
  after
    Owl.LiveScreen.flush()
  end

  defp reconcile_model_with_ollama(session) do
    case select_initial_model(session.model, Ollama.list_models([])) do
      {:ok, _} ->
        session

      {:fallback, model} ->
        Owl.IO.puts(
          Owl.Data.tag(
            "note: configured model #{inspect(session.model)} is not installed in Ollama; using #{inspect(model)} instead.",
            :yellow
          )
        )

        Session.set_model(session, model)

      {:error, :no_models} ->
        Owl.IO.puts(
          Owl.Data.tag(
            "warning: Ollama has no installed models. Pull one with `ollama pull <name>`, then `/model`.",
            :yellow
          )
        )

        session

      {:error, :ollama_unreachable} ->
        Owl.IO.puts(
          Owl.Data.tag(
            "warning: Ollama is not running at the configured base_url. Start it with `ollama serve`.",
            :yellow
          )
        )

        session

      {:error, reason} ->
        Owl.IO.puts(
          Owl.Data.tag(
            "warning: could not verify model against Ollama: #{inspect(reason)}",
            :yellow
          )
        )

        session
    end
  end

  @doc """
  Reconcile a desired Ollama model against the installed list.

  Returns:

    * `{:ok, model}` — the desired model is installed; use it as-is.
    * `{:fallback, model}` — desired model is missing; the caller should
      switch to this model (the first installed one).
    * `{:error, reason}` — the installed list could not be determined or is
      empty; the caller decides how to surface this to the user.
  """
  @spec select_initial_model(String.t(), {:ok, [String.t()]} | {:error, term()}) ::
          {:ok, String.t()}
          | {:fallback, String.t()}
          | {:error, :no_models | :ollama_unreachable | term()}
  def select_initial_model(_desired, {:ok, []}), do: {:error, :no_models}

  def select_initial_model(desired, {:ok, [_ | _] = installed}) do
    if desired in installed, do: {:ok, desired}, else: {:fallback, hd(installed)}
  end

  def select_initial_model(_desired, {:error, reason}), do: {:error, reason}

  defp loop(session) do
    Owl.LiveScreen.await_render()
    input = Owl.IO.input(label: prompt_label(session))

    case Commands.parse(input) do
      :exit ->
        Owl.IO.puts(Owl.Data.tag("Goodbye.", :light_black))
        :ok

      :noop ->
        loop(session)

      {:message, text} ->
        session
        |> handle_message(text)
        |> loop()

      {:command, verb, args} ->
        session
        |> handle_command(verb, args)
        |> loop()

      {:unknown, verb} ->
        Owl.IO.puts(Owl.Data.tag("Unknown command: /#{verb}. Try /help.", :yellow))
        loop(session)
    end
  end

  defp handle_message(session, text) do
    session = Session.append_user(session, text)
    callback = build_event_callback(session)
    run_opts = build_run_opts(session, callback)

    case ExAthena.run(nil, run_opts) do
      {:ok, result} ->
        new_session = Session.apply_result(session, result)
        update_status(new_session)
        new_session

      {:error, reason} ->
        Owl.IO.puts(Owl.Data.tag("\nrun error: #{inspect(reason)}", :red))
        session
    end
  end

  @doc """
  Build the keyword opts passed to `ExAthena.run/2` for one chat turn.

  When the host application has no `config :ex_athena, :ollama, base_url: ...`
  set, the underlying req_llm adapter falls back to `api.openai.com`. The REPL
  is Ollama-specific, so default `base_url` to `http://localhost:11434` —
  but only when the user hasn't configured one (their config wins via
  `ExAthena.Config.provider_opts/2`).
  """
  @spec build_run_opts(Session.t(), (ExAthena.Loop.Events.t() -> term())) :: keyword()
  def build_run_opts(%Session{} = session, callback) when is_function(callback, 1) do
    base = [
      provider: session.provider,
      model: session.model,
      mode: session.mode,
      tools: session.tools,
      messages: session.messages,
      permission_mode: session.permission_mode,
      on_event: callback
    ]

    case Application.get_env(:ex_athena, :ollama, [])[:base_url] do
      nil -> Keyword.put(base, :base_url, "http://localhost:11434")
      _configured -> base
    end
  end

  defp build_event_callback(session) do
    fn event ->
      Renderer.render_event(event)

      case event do
        {:iteration, n} ->
          update_status(%{session | iteration: n})

        {:usage, u} when is_map(u) ->
          merged = %{
            input_tokens: session.usage.input_tokens + Map.get(u, :input_tokens, 0),
            output_tokens: session.usage.output_tokens + Map.get(u, :output_tokens, 0)
          }

          update_status(%{session | usage: merged})

        _ ->
          :ok
      end
    end
  end

  defp handle_command(session, :help, _) do
    Owl.IO.puts(Commands.help_text())
    session
  end

  defp handle_command(session, :clear, _) do
    cleared = Session.clear_messages(session)
    Owl.IO.puts(Owl.Data.tag("History cleared.", :light_black))
    update_status(cleared)
    cleared
  end

  defp handle_command(session, :tools, _) do
    Owl.IO.puts(Owl.Data.tag("Tools available:", :light_black))

    Tools.builtins()
    |> Enum.each(fn mod ->
      Owl.IO.puts("  - " <> inspect(mod))
    end)

    session
  end

  defp handle_command(session, :mode, [arg | _]) do
    case parse_mode_atom(arg) do
      {:ok, mode} ->
        new = Session.set_mode(session, mode)
        Owl.IO.puts(Owl.Data.tag("Mode → #{inspect(mode)}", :light_black))
        update_status(new)
        new

      :error ->
        Owl.IO.puts(Owl.Data.tag("Unknown mode: #{arg}. Try /mode with no args.", :yellow))
        session
    end
  end

  defp handle_command(session, :mode, []) do
    case Owl.IO.select(@modes, render_as: &inspect/1, label: "Pick a runner mode:") do
      nil ->
        session

      mode ->
        new = Session.set_mode(session, mode)
        Owl.IO.puts(Owl.Data.tag("Mode → #{inspect(mode)}", :light_black))
        update_status(new)
        new
    end
  end

  defp handle_command(session, :model, [arg | _]) when is_binary(arg) do
    new = Session.set_model(session, arg)
    Owl.IO.puts(Owl.Data.tag("Model → #{arg}", :light_black))
    update_status(new)
    new
  end

  defp handle_command(session, :model, []) do
    case Ollama.list_models([]) do
      {:ok, []} ->
        Owl.IO.puts(
          Owl.Data.tag(
            "No models installed. Pull one with: ollama pull llama3.1",
            :yellow
          )
        )

        session

      {:ok, models} ->
        case Owl.IO.select(models, label: "Pick a model:") do
          nil ->
            session

          chosen ->
            new = Session.set_model(session, chosen)
            Owl.IO.puts(Owl.Data.tag("Model → #{chosen}", :light_black))
            update_status(new)
            new
        end

      {:error, :ollama_unreachable} ->
        Owl.IO.puts(
          Owl.Data.tag(
            "Ollama not running. Start it with: ollama serve",
            :red
          )
        )

        session

      {:error, reason} ->
        Owl.IO.puts(Owl.Data.tag("Could not list models: #{inspect(reason)}", :red))
        session
    end
  end

  defp parse_mode_atom(arg) when is_binary(arg) do
    candidate = String.to_existing_atom(arg)
    if candidate in @modes, do: {:ok, candidate}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp prompt_label(session) do
    "[#{session.model} | #{inspect(session.mode)}] you"
  end

  defp print_banner(session) do
    Owl.IO.puts([
      Owl.Data.tag("ExAthena chat", :cyan),
      "  ",
      Owl.Data.tag("(/help for commands, /exit to quit)", :light_black)
    ])

    Owl.IO.puts(
      Owl.Data.tag(
        "provider=#{session.provider}  model=#{session.model}  mode=#{inspect(session.mode)}",
        :light_black
      )
    )
  end

  defp update_status(session) do
    Owl.LiveScreen.update(:status, session_to_status(session))
  end

  defp session_to_status(session) do
    %{
      model: session.model,
      mode: session.mode,
      iteration: session.iteration,
      usage: session.usage,
      cost_usd: session.cost_usd
    }
  end

  defp render_status_block(nil), do: ""
  defp render_status_block(state) when is_map(state), do: Renderer.status_text(state)

  defp ensure_live_screen_started do
    case Process.whereis(Owl.LiveScreen) do
      nil -> Owl.LiveScreen.start_link([])
      pid -> {:ok, pid}
    end
  end
end
