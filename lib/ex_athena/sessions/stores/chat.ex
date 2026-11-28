defmodule ExAthena.Sessions.Stores.Chat do
  @moduledoc """
  `ExAthena.Session`'s door to the saved chat record (`ExAthena.Chats`), the
  one the terminal and web UIs read and write: `store: :chat`.

  The session writes each turn's messages with `save/3`, so a library session
  can be opened in `mix athena.chat --resume <id>` or the web UI. `read/1`
  hands the event-log reader of `Session.resume/2` one message event per
  saved message. Turn events (`append/2`) are not kept: the record holds the
  messages themselves.
  """

  @behaviour ExAthena.Sessions.Store

  alias ExAthena.Chats

  @message_events %{
    user: :user_message,
    assistant: :assistant_message,
    tool: :tool_result,
    system: :system_message
  }

  @doc "Start or update the record of chat `id` with `messages` (a whole history)."
  @spec save(String.t(), map(), list()) :: :ok | {:error, term()}
  def save(id, fields, messages), do: Chats.save(id, fields, messages)

  @impl ExAthena.Sessions.Store
  def append(_session_id, _event), do: :ok

  @impl ExAthena.Sessions.Store
  def read(session_id) do
    case Chats.load(session_id) do
      {:ok, %{messages: messages}} ->
        {:ok,
         Enum.map(messages, fn m ->
           %{event: Map.fetch!(@message_events, m.role), data: %{message: m}, ts: nil, uuid: nil}
         end)}

      {:error, :not_found} ->
        {:ok, []}

      err ->
        err
    end
  end

  @impl ExAthena.Sessions.Store
  def list, do: Enum.map(Chats.list(), & &1.id)

  @impl ExAthena.Sessions.Store
  def tail(session_id, n) do
    with {:ok, events} <- read(session_id), do: {:ok, Enum.take(events, -n)}
  end
end
