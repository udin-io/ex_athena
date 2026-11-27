defmodule Mix.Tasks.Athena.Chat do
  @shortdoc "Interactive terminal chat REPL against the ExAthena agent loop"

  @moduledoc """
  Drops you into an interactive chat session against the ExAthena agent loop.

  Defaults to the provider set in `config :ex_athena, default_provider: :ollama`
  (falls back to `:ollama` when unset). The model is read from the provider's
  config block, e.g. `config :ex_athena, :llamacpp, model: "my-model"`.

  For a full walkthrough — keybindings, permission levels, JSON provider setup,
  and screenshot tour — see the [TUI guide](guides/tui.md).

  ## Usage

      mix athena.chat
      mix athena.chat --provider llamacpp
      mix athena.chat --provider ollama --model qwen2.5-coder:14b
      mix athena.chat --permission read_only
      mix athena.chat -p ~/projects/my_app

  ## Flags

    * `--provider NAME` — `:ollama`, `:llamacpp`, `:openai`, etc. (overrides config).
    * `--model NAME`    — initial model (overrides config).
    * `--permission LEVEL` — how much the chat may do without asking:
      `read_only` (it shows a plan first), `ask` (the default), `edit`, or
      `trusted`. See `ExAthena.Chat.Permission`.
    * `--path PATH` (`-p`) — working directory for tools that touch the
      filesystem. `~` is expanded. The chat process does NOT `cd` into
      this path; tools just receive it as their `cwd`.
    * `--log` — also write log output to `log/phoenix_output.log`.

  ## Provider-specific requirements

    * `:ollama`   — requires a running Ollama daemon (`ollama serve`).
    * `:llamacpp` — requires a running llama.cpp server (`llama-server --model ...`).
  """

  use Mix.Task

  alias ExAthena.Chat.Tui

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start", [])

    {parsed, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [
          model: :string,
          permission: :string,
          mode: :string,
          provider: :string,
          path: :string,
          log: :boolean
        ],
        aliases: [p: :path]
      )

    if parsed[:mode] do
      Mix.raise(
        "--mode was removed: pick how much the chat may do with --permission " <>
          "read_only | ask | edit | trusted (read_only shows a plan first)"
      )
    end

    if parsed[:log] do
      path = ExAthena.LogFile.attach!()
      Mix.shell().info("Logging to #{path}")
    end

    opts =
      []
      |> maybe_put_provider(parsed[:provider])
      |> maybe_put(:model, parsed[:model])
      |> maybe_put_permission(parsed[:permission])
      |> maybe_put_path(parsed[:path])

    # The TUI is only compiled when the optional :ex_ratatui dep is present.
    # Dispatch dynamically so this task still compiles when Tui is absent.
    if Code.ensure_loaded?(Tui) do
      apply(Tui, :start, [opts])
    else
      Mix.raise(
        "mix athena.chat requires the optional :ex_ratatui dependency. " <>
          "Add `{:ex_ratatui, \"~> 0.10\"}` to your deps and re-run."
      )
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_provider(opts, nil), do: opts

  defp maybe_put_provider(opts, raw) when is_binary(raw) do
    try do
      Keyword.put(opts, :provider, String.to_existing_atom(raw))
    rescue
      ArgumentError ->
        Mix.shell().error("Unknown --provider #{raw}.")
        opts
    end
  end

  defp maybe_put_permission(opts, nil), do: opts

  defp maybe_put_permission(opts, raw) when is_binary(raw) do
    valid = Enum.map(ExAthena.Chat.Permission.levels(), &Atom.to_string/1)

    if raw in valid do
      Keyword.put(opts, :permission, ExAthena.Chat.Permission.parse(raw))
    else
      Mix.raise("Unknown --permission #{raw}. Valid: " <> Enum.join(valid, ", "))
    end
  end

  defp maybe_put_path(opts, nil), do: opts

  defp maybe_put_path(opts, raw) when is_binary(raw) do
    expanded = Path.expand(raw)

    if File.dir?(expanded) do
      Keyword.put(opts, :cwd, expanded)
    else
      Mix.shell().error("--path #{raw} (expanded to #{expanded}) is not an existing directory.")
      opts
    end
  end
end
