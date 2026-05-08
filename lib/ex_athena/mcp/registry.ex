defmodule ExAthena.Mcp.Registry do
  @moduledoc false

  @registry __MODULE__

  @doc "Child spec for starting the Registry."
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: @registry)
  end

  @doc "`{:via, Registry, ...}` tuple for naming a process by server name."
  @spec via(String.t()) :: {:via, Registry, {atom(), String.t()}}
  def via(name), do: {:via, Registry, {@registry, name}}

  @doc "Resolve a server name to its pid, or `nil` if not registered."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(name) do
    try do
      case Registry.lookup(@registry, name) do
        [{pid, _}] -> pid
        _ -> nil
      end
    rescue
      ArgumentError -> nil
    end
  end

  @doc "List all `{name, pid}` pairs currently registered."
  @spec list() :: [{String.t(), pid()}]
  def list do
    try do
      Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    rescue
      ArgumentError -> []
    end
  end
end
