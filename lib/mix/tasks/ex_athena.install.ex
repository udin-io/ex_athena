if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.ExAthena.Install do
    @shortdoc "Installs ExAthena — writes sensible config defaults."

    @moduledoc """
    Installs ExAthena into your project.

    Run once after adding `{:ex_athena, "~> 0.1"}` to `mix.exs`, or via Igniter:

        mix igniter.install ex_athena
        mix ex_athena.install

    ## What it does

      * Writes a `config :ex_athena, default_provider: :ollama` default to
        `config/config.exs` (only if no default is already configured).
      * Writes sensible per-provider defaults for Ollama (base URL pointing at
        `http://localhost:11434`), OpenAI-compatible (`https://api.openai.com/v1`),
        and Claude (picks up `ANTHROPIC_API_KEY` from env).
      * Does NOT write API keys inline — the installer uses
        `{:system, "VAR"}` tuples so secrets stay in the environment.

    Idempotent: re-running preserves whatever you've already set.
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :ex_athena,
        example: "mix ex_athena.install",
        schema: [],
        aliases: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> configure_default_provider()
      |> configure_ollama()
      |> configure_openai_compatible()
      |> configure_claude()
      |> Igniter.add_notice("""
      ExAthena installed.

      • Default provider set to :ollama (pointing at http://localhost:11434).
      • To use OpenAI / OpenRouter / LM Studio / llama.cpp, set
        `config :ex_athena, default_provider: :openai_compatible` and point
        base_url + api_key at your endpoint.
      • To use Anthropic Claude, set
        `config :ex_athena, default_provider: :claude` and provide
        ANTHROPIC_API_KEY in the environment.
      • Full docs: https://hexdocs.pm/ex_athena.
      """)
    end

    defp configure_default_provider(igniter) do
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        :ex_athena,
        [:default_provider],
        :ollama,
        updater: &keep_existing/1
      )
    end

    defp configure_ollama(igniter) do
      igniter
      |> Igniter.Project.Config.configure(
        "config.exs",
        :ex_athena,
        [:ollama, :base_url],
        "http://localhost:11434",
        updater: &keep_existing/1
      )
      |> Igniter.Project.Config.configure(
        "config.exs",
        :ex_athena,
        [:ollama, :model],
        "llama3.1",
        updater: &keep_existing/1
      )
    end

    defp configure_openai_compatible(igniter) do
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        :ex_athena,
        [:openai_compatible, :base_url],
        "https://api.openai.com/v1",
        updater: &keep_existing/1
      )
    end

    defp configure_claude(igniter) do
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        :ex_athena,
        [:claude, :model],
        "claude-opus-4-5",
        updater: &keep_existing/1
      )
    end

    # Preserve whatever the user already has.
    defp keep_existing(zipper), do: {:ok, zipper}
  end
else
  defmodule Mix.Tasks.ExAthena.Install do
    @shortdoc "Installs ExAthena (requires Igniter)."
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.raise("""
      mix ex_athena.install requires `igniter` to be in your deps.

      Add it to your mix.exs:

          {:igniter, "~> 0.6", only: [:dev]}

      Then run `mix deps.get` and retry.
      """)
    end
  end
end
