defmodule Mix.Tasks.Athena.Chat do
  @shortdoc "Interactive terminal chat REPL against the ExAthena agent loop"

  @moduledoc """
  Drops you into an interactive chat session against the ExAthena agent loop.

  Defaults to the `:ollama` provider, the model configured under
  `config :ex_athena, :ollama, model: ...`, the `:react` runner mode, and
  every builtin tool. Slash commands (`/model`, `/mode`, `/tools`, `/clear`,
  `/help`, `/exit`) switch state in-session.

  ## Usage

      mix athena.chat
      mix athena.chat --model qwen2.5-coder:14b
      mix athena.chat --mode plan_and_solve

  ## Flags

    * `--model NAME`  — initial model (overrides config).
    * `--mode NAME`   — `react`, `plan_and_solve`, or `reflexion`.

  Requires a running Ollama daemon (`ollama serve`) for the default provider.
  """

  use Mix.Task

  alias ExAthena.Chat.Repl

  @valid_modes ~w(react plan_and_solve reflexion)a

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start", [])

    {parsed, _rest, _invalid} =
      OptionParser.parse(argv, strict: [model: :string, mode: :string])

    opts =
      []
      |> maybe_put(:model, parsed[:model])
      |> maybe_put_mode(parsed[:mode])

    Repl.start(opts)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_mode(opts, nil), do: opts

  defp maybe_put_mode(opts, raw) when is_binary(raw) do
    atom = String.to_atom(raw)

    if atom in @valid_modes do
      Keyword.put(opts, :mode, atom)
    else
      Mix.shell().error(
        "Unknown --mode #{raw}. Valid: " <> Enum.map_join(@valid_modes, ", ", &Atom.to_string/1)
      )

      opts
    end
  end
end
