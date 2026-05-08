defmodule ExAthena.Lsp.Supervisor do
  @moduledoc """
  Top-level supervisor for the LSP subsystem.

  Starts three children in `:rest_for_one` order:

  1. `Registry` (unique, named `ExAthena.Lsp.Registry`) — clients register
     under `{root, language}` via-tuples so the Manager can look them up
     without holding a mutable pid map.
  2. `DynamicSupervisor` (named `ExAthena.Lsp.ClientSupervisor`) — owns
     client lifecycle; restarts failed clients up to 3 times per 60 s.
  3. `ExAthena.Lsp.Manager` — the public façade for spawning and locating
     clients.

  Enabled by default; set `config :ex_athena, enable_lsp: false` to skip
  (used in test config so individual tests opt in via `start_supervised!/1`).
  """

  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      {Registry, keys: :unique, name: ExAthena.Lsp.Registry},
      {DynamicSupervisor,
       name: ExAthena.Lsp.ClientSupervisor,
       strategy: :one_for_one,
       max_restarts: 3,
       max_seconds: 60},
      ExAthena.Lsp.Manager
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
