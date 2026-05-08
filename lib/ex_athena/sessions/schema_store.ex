defmodule ExAthena.Sessions.SchemaStore do
  @moduledoc """
  Behaviour for row-shaped session storage (sessions / messages / snapshots).

  This is a companion to `ExAthena.Sessions.Store` (the append-only event-log
  behaviour). While the event-log store is optimised for sequential replay, this
  behaviour exposes O(1)-lookup CRUD primitives that sub-ticket 2–4 (resume,
  checkpoint, fork, rewind) will call.

  ## Tables

    * **sessions** — one row per session; keyed by `session_id`.
    * **messages** — one row per message; keyed by `(session_id, seq,
      message_id)` so range scans over a session's history are O(log n).
    * **snapshots** — one row per snapshot; keyed by `(session_id,
      message_id, snapshot_id)` so every snapshot associated with a
      fork-point can be enumerated with a prefix scan.

  ## Row shapes

  See the `t:session/0`, `t:message/0`, and `t:snapshot/0` typespecs below.
  All timestamps are ISO 8601 strings produced by
  `DateTime.utc_now() |> DateTime.to_iso8601()`.
  """

  @type session_id :: String.t()
  @type message_id :: String.t()

  @type session :: %{
          required(:id) => session_id(),
          optional(:parent_id) => session_id() | nil,
          optional(:title) => String.t() | nil,
          optional(:model) => String.t() | nil,
          optional(:created_at) => String.t(),
          optional(:updated_at) => String.t(),
          optional(:metadata) => map()
        }

  @type message :: %{
          required(:id) => message_id(),
          required(:session_id) => session_id(),
          required(:role) => :system | :user | :assistant | :tool,
          required(:content) => map(),
          required(:ts) => String.t(),
          optional(:seq) => integer()
        }

  @type snapshot :: %{
          required(:id) => String.t(),
          required(:session_id) => session_id(),
          required(:message_id) => message_id(),
          required(:state) => map(),
          required(:created_at) => String.t()
        }

  @callback put_session(session()) :: :ok
  @callback get_session(session_id()) :: {:ok, session()} | {:error, :not_found}
  @callback list_sessions() :: [session()]
  @callback delete_session(session_id()) :: :ok

  @callback put_message(message()) :: :ok
  @callback list_messages(session_id()) :: {:ok, [message()]}
  @callback delete_messages_after(session_id(), message_id()) :: :ok
  @callback delete_messages_for_session(session_id()) :: :ok

  @callback put_snapshot(snapshot()) :: :ok
  @callback get_snapshot(String.t()) :: {:ok, snapshot()} | {:error, :not_found}
  @callback list_snapshots(session_id()) :: {:ok, [snapshot()]}
  @callback delete_snapshots_for_session(session_id()) :: :ok

  @optional_callbacks [delete_messages_for_session: 1, delete_snapshots_for_session: 1]

  @doc "Generate a unique message id (16 random bytes, url-safe base64)."
  @spec new_message_id() :: message_id()
  def new_message_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc "Generate a unique snapshot id (16 random bytes, url-safe base64)."
  @spec new_snapshot_id() :: String.t()
  def new_snapshot_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
