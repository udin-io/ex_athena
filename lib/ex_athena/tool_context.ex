defmodule ExAthena.ToolContext do
  @moduledoc """
  Context handed to every tool execution.

  Carries the working directory the loop should treat as root, the current
  permission mode, the session id (if any), and a free-form `assigns` map for
  custom tools to stash arbitrary data the consumer needs (project id,
  conversation id, ticket id — whatever the host cares about).

  Tools that don't care about context can ignore it, but `cwd` and `phase`
  are load-bearing for any tool that touches the filesystem or checks
  permissions.
  """

  @enforce_keys [:cwd]
  defstruct cwd: nil,
            phase: :default,
            session_id: nil,
            tool_call_id: nil,
            assigns: %{}

  @type phase :: :plan | :default | :accept_edits | :trusted | :bypass_permissions

  @type t :: %__MODULE__{
          cwd: Path.t(),
          phase: phase(),
          session_id: String.t() | nil,
          tool_call_id: String.t() | nil,
          assigns: map()
        }

  @doc "Build a context. `:cwd` is required; everything else defaults."
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end

  @doc "Resolve a user-supplied relative path against `ctx.cwd`, rejecting traversal."
  @spec resolve_path(t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def resolve_path(%__MODULE__{cwd: cwd}, path) when is_binary(path) do
    cond do
      String.contains?(path, "\0") ->
        {:error, :null_byte_in_path}

      Path.type(path) == :absolute ->
        {:ok, path}

      String.contains?(path, "..") ->
        {:error, :path_traversal_rejected}

      true ->
        {:ok, Path.expand(path, cwd)}
    end
  end

  def resolve_path(_, _), do: {:error, :invalid_path}
end
