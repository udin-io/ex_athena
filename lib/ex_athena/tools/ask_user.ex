defmodule ExAthena.Tools.AskUser do
  @moduledoc """
  Ask the human a clarifying question mid-run and block until they answer.

  This tool only works when the host wires an interactive channel into the
  tool context: `assigns: %{ask_user: pid}`, where `pid` receives an
  `{:athena_ask_user, question}` message and replies with
  `{:athena_user_answer, tool_call_id, answer}`. The LiveView chat UI does
  this; headless runs (CLI, cron) do not, so the tool returns an error there
  telling the model to proceed on its own judgement instead of hanging.

  Because the tool returns `parallel_safe?: false`, it executes serially in
  the run-loop process. The blocking `receive` therefore pauses the *entire*
  agent loop until the user answers — exactly the "wait for input" semantics
  we want — without a per-tool timeout killing it (only the concurrent
  dispatch path applies `tool_timeout_ms`).
  """

  @behaviour ExAthena.Tool

  @impl true
  def name, do: "ask_user"

  @impl true
  def description,
    do:
      "Ask the user a clarifying question and wait for their reply. Use this when you " <>
        "are blocked on a decision only the user can make (ambiguous requirements, a " <>
        "choice between approaches, missing information). Prefer this over guessing when " <>
        "guessing wrong would waste significant work. Returns the user's answer as text."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        question: %{
          type: "string",
          description: "The question to ask the user. Be specific and self-contained."
        },
        options: %{
          type: "array",
          items: %{type: "string"},
          description:
            "Optional list of suggested answers, shown to the user as quick-pick buttons. " <>
              "The user may still type a free-form reply."
        }
      },
      required: ["question"]
    }
  end

  @impl true
  def parallel_safe?, do: false

  @impl true
  def execute(args, ctx) do
    question = Map.get(args, "question")
    options = args |> Map.get("options", []) |> List.wrap() |> Enum.filter(&is_binary/1)
    host = Map.get(ctx.assigns, :ask_user)

    cond do
      not is_binary(question) or question == "" ->
        {:error, ~s(ask_user requires a non-empty "question")}

      not is_pid(host) ->
        {:error,
         "interactive questions are not available in this run; proceed using your " <>
           "best judgement instead of asking"}

      true ->
        case ask(host, ctx.tool_call_id, question, options) do
          # Phrase the result so even a small local model cannot miss that the
          # question has been RESOLVED — a bare answer string was read as
          # "still waiting" and stalled runs.
          {:ok, answer} ->
            {:ok,
             ~s(The user answered: "#{answer}"\n) <>
               "Act on this answer now; do not ask again."}

          {:error, :host_down} ->
            {:error, "the user session ended before answering the question"}
        end
    end
  end

  @doc """
  Put a question to the person through `host` and wait for the answer.

  Sends `{:athena_ask_user, %{tool_call_id:, question:, options:, reply_to:}}`
  to `host` and blocks until `{:athena_user_answer, id, answer}` arrives.
  `reply_to` is the asking process, so a host can answer a helper that runs in
  its own process, not only the top-level run. Returns `{:ok, answer}`, or
  `{:error, :host_down}` when the host exits first. `extra` rides in the
  payload: `ExAthena.Chat.Permission` asks for approvals through here with a
  `kind:`, so a host can tell a plan approval from a question the model
  wrote.
  """
  @spec ask(pid(), String.t() | nil, String.t(), [String.t()], map()) ::
          {:ok, String.t()} | {:error, :host_down}
  def ask(host, id, question, options, extra \\ %{}) when is_pid(host) do
    ref = Process.monitor(host)

    payload =
      Map.merge(extra, %{tool_call_id: id, question: question, options: options, reply_to: self()})

    send(host, {:athena_ask_user, payload})

    receive do
      {:athena_user_answer, ^id, answer} ->
        Process.demonitor(ref, [:flush])
        {:ok, answer}

      {:DOWN, ^ref, :process, ^host, _reason} ->
        {:error, :host_down}
    end
  end
end
