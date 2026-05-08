defmodule ExAthena.Lsp do
  @moduledoc """
  Public facade for the LSP subsystem.

  Delegates to `ExAthena.Lsp.Manager` for client lifecycle operations and
  `ExAthena.Lsp.Client` for per-session operations.

  ## Architecture

      ExAthena.Supervisor
      └── ExAthena.Lsp.Supervisor (:rest_for_one)
          ├── Registry (ExAthena.Lsp.Registry)
          ├── DynamicSupervisor (ExAthena.Lsp.ClientSupervisor)
          └── ExAthena.Lsp.Manager
                  └─ spawns ExAthena.Lsp.Client (one per project_root × language)

  ## Usage

      # Get (or spawn) a client for a specific file:
      {:ok, pid} = ExAthena.Lsp.client_for_file(File.cwd!(), "lib/my_app.ex")

      # Make a JSON-RPC request:
      {:ok, result} = ExAthena.Lsp.Client.request(pid, "textDocument/hover", params)

  ## Telemetry

  * `[:ex_athena, :lsp, :spawn]` — emitted on client start/stop/crash
    (exactly once per phase, from the Client itself).
  * `[:ex_athena, :lsp, :client_supervised, :down]` — emitted by the Manager
    when a supervised client process exits, with `%{language, root, pid, reason}`.
  * `[:ex_athena, :lsp, :request, :start | :stop]` — emitted around each
    JSON-RPC request/response cycle.
  """

  alias ExAthena.Lsp.Manager

  defdelegate ensure_started(project_root, language), to: Manager
  defdelegate client_for_file(project_root, file), to: Manager
  defdelegate stop(project_root, language), to: Manager
  defdelegate list(), to: Manager
end
