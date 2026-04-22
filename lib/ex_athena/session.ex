defmodule ExAthena.Session do
  @moduledoc """
  GenServer that owns a multi-turn conversation.

  A `Session` is the right abstraction when you want:

    * the message history to persist across multiple user turns,
    * resumable state across LiveView reconnects,
    * streaming deltas broadcast to subscribers,
    * an identifiable process pid / name you can monitor.

  For one-shot agent runs, use `ExAthena.Loop.run/2` directly. For truly
  stateless single-turn inference, `ExAthena.query/2`.

  ## Usage

      {:ok, pid} = ExAthena.Session.start_link(
        provider: :ollama,
        model: "llama3.1",
        tools: :all,
        cwd: "/path/to/project"
      )

      {:ok, result} = ExAthena.Session.send_message(pid, "read mix.exs and list deps")
      IO.puts(result.text)

      ExAthena.Session.stop(pid)

  Each `send_message` appends to the session's message list, runs the agent
  loop to completion, and returns the final result. Subsequent messages
  include the full prior history, so the model has context.
  """

  use GenServer

  alias ExAthena.Loop

  # ── Client API ─────────────────────────────────────────────────────

  @doc """
  Start a session. Accepts the same options as `ExAthena.Loop.run/2` plus:

    * `:name` — GenServer name.
    * `:system_prompt` — pinned system prompt used on every turn.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Send a user message; blocks until the loop terminates."
  @spec send_message(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(server, message, opts \\ []) do
    GenServer.call(server, {:send_message, message, opts}, :infinity)
  end

  @doc "Return the current message list (for debugging / persistence)."
  @spec messages(GenServer.server()) :: [map()]
  def messages(server), do: GenServer.call(server, :messages)

  @doc "Stop the session."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal)

  # ── Server ──────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       opts: opts,
       messages: [],
       usage: nil
     }}
  end

  @impl GenServer
  def handle_call({:send_message, message, extra_opts}, _from, state) do
    # Merge per-call opts on top of the session's base opts, then append the
    # running message history so the loop sees the full context.
    loop_opts =
      state.opts
      |> Keyword.merge(extra_opts)
      |> Keyword.put(:messages, state.messages)

    case Loop.run(message, loop_opts) do
      {:ok, result} ->
        state = %{
          state
          | messages: result.messages,
            usage: merge_usage(state.usage, result.usage)
        }

        {:reply, {:ok, result}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:messages, _from, state), do: {:reply, state.messages, state}

  # ── Internal ────────────────────────────────────────────────────────

  defp merge_usage(nil, new), do: new
  defp merge_usage(old, nil), do: old

  defp merge_usage(old, new) do
    %{
      input_tokens: sum(old[:input_tokens], new[:input_tokens]),
      output_tokens: sum(old[:output_tokens], new[:output_tokens]),
      total_tokens: sum(old[:total_tokens], new[:total_tokens])
    }
  end

  defp sum(nil, b), do: b
  defp sum(a, nil), do: a
  defp sum(a, b), do: a + b
end
