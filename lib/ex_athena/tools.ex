defmodule ExAthena.Tools do
  @moduledoc """
  Resolves tool modules into the shape the provider + loop expect.

  Consumers supply tools in one of two ways:

    1. **At config time:**

           config :ex_athena, tools: [MyApp.ToolA, MyApp.ToolB]

    2. **Per-call:**

           ExAthena.Loop.run(messages, tools: [MyApp.ToolA, ExAthena.Tools.Read])

  Per-call wins; the configured list is the default when no tools are passed.
  """

  alias ExAthena.Tool

  @builtins [
    ExAthena.Tools.Read,
    ExAthena.Tools.Glob,
    ExAthena.Tools.Grep,
    ExAthena.Tools.Write,
    ExAthena.Tools.Edit,
    ExAthena.Tools.Bash,
    ExAthena.Tools.WebFetch,
    ExAthena.Tools.TodoWrite,
    ExAthena.Tools.PlanMode,
    ExAthena.Tools.SpawnAgent
  ]

  @doc "List the builtin tool modules."
  @spec builtins() :: [module()]
  def builtins, do: @builtins

  @doc """
  Resolve the tools to use for a call. Accepts:

    * a list of modules
    * `:all` — every builtin
    * `nil` — falls back to `config :ex_athena, tools: ...` or `:all`
  """
  @spec resolve(keyword()) :: [module()]
  def resolve(opts) do
    case Keyword.get(opts, :tools) do
      nil -> Application.get_env(:ex_athena, :tools, :all) |> expand()
      :all -> @builtins
      modules when is_list(modules) -> modules
    end
  end

  defp expand(:all), do: @builtins
  defp expand(modules) when is_list(modules), do: modules
  defp expand(_), do: @builtins

  @doc """
  Build the provider-facing tool schema list — the same shape Ollama /
  OpenAI-compatible providers send on the wire.
  """
  @spec describe_for_provider([module()]) :: [map()]
  def describe_for_provider(modules) do
    Enum.map(modules, fn mod ->
      %{
        type: "function",
        function: %{
          name: mod.name(),
          description: mod.description(),
          parameters: mod.schema()
        }
      }
    end)
  end

  @doc """
  Build the prompt-friendly list used by `ExAthena.ToolCalls.augment_system_prompt/2`
  when we fall back to the TextTagged protocol.
  """
  @spec describe_for_prompt([module()]) :: [map()]
  def describe_for_prompt(modules) do
    Enum.map(modules, fn mod ->
      %{name: mod.name(), description: mod.description(), schema: mod.schema()}
    end)
  end

  @doc "Find the tool module that handles a call by name."
  @spec find([module()], String.t()) :: module() | nil
  def find(modules, name) when is_binary(name) do
    Enum.find(modules, fn mod -> mod.name() == name end)
  end

  @doc "Validate that every module in `modules` implements the Tool behaviour."
  @spec validate!([module()]) :: :ok
  def validate!(modules) do
    Enum.each(modules, fn mod ->
      unless Code.ensure_loaded?(mod) and implements_behaviour?(mod, Tool) do
        raise ArgumentError, "#{inspect(mod)} does not implement ExAthena.Tool"
      end
    end)

    :ok
  end

  defp implements_behaviour?(mod, behaviour) do
    behaviours = mod.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    behaviour in behaviours
  end
end
