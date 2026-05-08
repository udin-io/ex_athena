defmodule ExAthena.Lsp.Manager do
  @moduledoc """
  Manages one `ExAthena.Lsp.Client` per `{project_root, language}` pair.

  Clients are lazily spawned under `ExAthena.Lsp.ClientSupervisor` and
  registered in `ExAthena.Lsp.Registry` — the registry is the source of
  truth for "is this client running?", not Manager state.

  Manager state holds only a `%{monitor_ref => {root, language}}` map for
  crash telemetry; pids are always looked up from the Registry.
  """

  use GenServer

  require Logger

  alias ExAthena.Lsp.{Client, ServerRegistry}
  alias ExAthena.Telemetry

  # --- public API ---

  @doc """
  Return `{:ok, pid}` for the LSP client serving `(project_root, language)`,
  spawning one if none is running yet.
  """
  @spec ensure_started(String.t(), atom()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(project_root, language) do
    GenServer.call(__MODULE__, {:ensure_started, project_root, language})
  end

  @doc """
  Return `{:ok, pid}` for the LSP client that handles files with the
  extension of `file`, or `{:error, :unsupported_language}` if the
  extension is not mapped.
  """
  @spec client_for_file(String.t(), String.t()) ::
          {:ok, pid()} | {:error, :unsupported_language | term()}
  def client_for_file(project_root, file) do
    case ServerRegistry.language_for_path(file) do
      nil -> {:error, :unsupported_language}
      language -> ensure_started(project_root, language)
    end
  end

  @doc "Terminate the client for `(project_root, language)` if one is running."
  @spec stop(String.t(), atom()) :: :ok
  def stop(project_root, language) do
    GenServer.call(__MODULE__, {:stop, project_root, language})
  end

  @doc "Return a list of all running clients."
  @spec list() :: [%{root: String.t(), language: atom(), pid: pid()}]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  # --- GenServer ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:ensure_started, root, language}, _from, state) do
    case lookup(root, language) do
      {:ok, pid} ->
        {:reply, {:ok, pid}, state}

      :not_found ->
        case do_start(root, language) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            state = put_in(state, [:monitors, ref], {root, language})
            {:reply, {:ok, pid}, state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:stop, root, language}, _from, state) do
    case lookup(root, language) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(ExAthena.Lsp.ClientSupervisor, pid)
        {:reply, :ok, state}

      :not_found ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:list, _from, state) do
    entries =
      Registry.select(ExAthena.Lsp.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.map(fn {{root, language}, pid} ->
        %{root: root, language: language, pid: pid}
      end)

    {:reply, entries, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{root, language}, monitors} ->
        # Use a distinct event name from the Client's own `:spawn` telemetry —
        # the Client already emits `[:ex_athena, :lsp, :spawn]` from terminate/2,
        # so consumers would otherwise count crashes twice.
        Telemetry.event(
          [:ex_athena, :lsp, :client_supervised, :down],
          %{system_time: System.system_time()},
          %{language: language, root: root, pid: pid, reason: reason}
        )

        Logger.info(
          "[ExAthena.Lsp.Manager] client for {#{root}, #{language}} exited: #{inspect(reason)}"
        )

        {:noreply, %{state | monitors: monitors}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- private ---

  defp lookup(root, language) do
    case Registry.lookup(ExAthena.Lsp.Registry, {root, language}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  defp via(root, language) do
    {:via, Registry, {ExAthena.Lsp.Registry, {root, language}}}
  end

  defp do_start(root, language) do
    case ServerRegistry.spawn_spec(language) do
      {:error, :unsupported} ->
        {:error, {:no_server, language}}

      {:ok, %{binary: binary, args: args}} ->
        child_spec = %{
          id: {Client, root, language},
          start:
            {Client, :start_link,
             [
               [
                 binary: binary,
                 args: args,
                 root_uri: "file://#{root}",
                 root: root,
                 language: language,
                 name: via(root, language)
               ]
             ]},
          restart: :transient
        }

        case DynamicSupervisor.start_child(ExAthena.Lsp.ClientSupervisor, child_spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
