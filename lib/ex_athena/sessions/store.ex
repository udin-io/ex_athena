defmodule ExAthena.Sessions.Store do
  @moduledoc """
  Behaviour for append-only session event storage.

  Sessions emit one event per loop transition (user message, assistant
  message, tool call, tool result, compaction, iteration, session
  start/end). A `Store` module decides where those events live: an
  in-memory ETS table, a JSONL file, an external service, etc.

  The default store is `ExAthena.Sessions.Stores.InMemory` — fast,
  ephemeral, perfect for tests and short-lived runs. The
  `ExAthena.Sessions.Stores.Jsonl` store buffers events in ETS and
  flushes to disk every 250ms, giving you portable + replay-friendly
  storage at near-zero hot-path cost.

  ## Event shape

  Each event is a map:

      %{
        ts: iso8601_string(),
        event: atom(),     # :session_start | :user_message | …
        data: map(),       # event-specific payload
        uuid: binary()     # stable per-event id (for chain patching + rewind)
      }
  """

  @type session_id :: String.t()
  @type event :: %{
          required(:ts) => String.t(),
          required(:event) => atom(),
          required(:data) => map(),
          required(:uuid) => String.t()
        }

  @callback append(session_id(), event()) :: :ok
  @callback read(session_id()) :: {:ok, [event()]} | {:error, term()}
  @callback list() :: [session_id()]
  @callback tail(session_id(), n :: pos_integer()) :: {:ok, [event()]} | {:error, term()}

  @doc """
  Build a new event with a generated uuid + ISO 8601 timestamp.
  """
  @spec new_event(atom(), map()) :: event()
  def new_event(event, data) when is_atom(event) and is_map(data) do
    %{
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      event: event,
      data: data,
      uuid: generate_uuid()
    }
  end

  defp generate_uuid do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
