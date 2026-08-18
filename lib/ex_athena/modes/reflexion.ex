defmodule ExAthena.Modes.Reflexion do
  @moduledoc """
  Reflexion mode: after each ReAct iteration, insert a short self-critique
  pass before the next turn.

  Per the Reflexion paper (Shinn et al.) — and validated in the research
  phase of v0.3 — self-critique is most useful when capped at **3
  reflection cycles**. Beyond that, models exhibit degeneration-of-thought
  (looping on the same critique or contradicting themselves).

  ## How it works

  Each ReAct iteration calls the provider. On `{:continue, state}` return,
  this mode injects a synthetic user message with a reflection prompt,
  lets the model critique its own last turn, and adds the critique to
  history before the next iteration.

  Skips reflection when:
    * Iteration count ≥ `:max_reflections` (default 3, hard cap at 3).
    * The ReAct turn halted (we're terminating anyway).

  ## State

  `state.mode_state[:reflections]` counts performed reflections.

  ## Trade-off

  Reflexion roughly triples per-loop cost (one extra inference per turn
  for the critique). Best reserved for tasks where correctness matters
  more than speed — research-style fact-checking, structured extraction
  at the edge of the model's ability, etc.
  """

  @behaviour ExAthena.Loop.Mode

  alias ExAthena.Messages
  alias ExAthena.Loop.{Inference, State}
  alias ExAthena.Tuning

  @default_max_reflections 3
  @hard_cap 3

  @reflection_prompt """
  Reflect on your last step. In 1-3 sentences:

  - Did it advance the goal?
  - Did you make any mistakes that will bias the next step?
  - If so, what correction should you take next?

  Keep this terse — the next turn will act on your reflection.
  """

  @impl ExAthena.Loop.Mode
  def init(%State{} = state) do
    max_reflections =
      state.meta
      |> Map.get(:max_reflections, Tuning.get(:modes, :max_reflections, @default_max_reflections))
      |> min(Tuning.get(:modes, :reflections_hard_cap, @hard_cap))

    mode_state = %{reflections: 0, max_reflections: max_reflections}
    {:ok, %{state | mode_state: mode_state}}
  end

  @impl ExAthena.Loop.Mode
  def iterate(%State{mode_state: mode_state} = state) do
    case ExAthena.Modes.ReAct.iterate(state) do
      {:continue, new_state} ->
        if should_reflect?(mode_state) do
          case reflect(new_state) do
            {:ok, reflected_state} ->
              new_mode_state = %{
                mode_state
                | reflections: mode_state.reflections + 1
              }

              {:continue, %{reflected_state | mode_state: new_mode_state}}

            {:error, _reason} ->
              # Reflection failures are non-fatal — just skip and continue.
              {:continue, new_state}
          end
        else
          {:continue, new_state}
        end

      other ->
        other
    end
  end

  # ── Internal ──────────────────────────────────────────────────────

  defp should_reflect?(%{reflections: n, max_reflections: m}), do: n < m
  defp should_reflect?(_), do: false

  defp reflect(state) do
    messages = state.messages ++ [Messages.user(@reflection_prompt)]

    request = %{
      state.request_template
      | messages: messages,
        tools: nil,
        max_tokens: 256
    }

    # Through the shared inference path: queue slot, ChatParams hooks, chat
    # telemetry span, and full usage/cost folding onto the run's budget.
    # `starvation: :tolerate` — a starved critique (256-token cap fully
    # burned on reasoning) is just a failed reflection; it must not trigger
    # the kernel's max_tokens escalation, which would 4x the MAIN turn's
    # completion cap for the rest of the run and re-run the whole iteration.
    case Inference.call(state, request,
           purpose: :reflection,
           starvation: :tolerate
         ) do
      # A ChatParams hook halted the critique call. Reflection is
      # non-fatal — skip it; the next main turn fires ChatParams again, so
      # a host that wants the run stopped halts it there.
      {:halt, reason} ->
        {:error, {:chat_params_halted, reason}}

      {:ok, response, state} ->
        accept_critique(state, response)

      {:error, _} = err ->
        err
    end
  end

  defp accept_critique(state, response) do
    case String.trim(response.text || "") do
      "" ->
        # Blank critique (starved or empty turn): keep the folded budget,
        # but don't append an empty assistant message — and still count
        # the attempt against the reflection cap so a persistently starved
        # critique can't retry forever.
        {:ok, state}

      critique ->
        new_messages =
          state.messages ++
            [
              Messages.user(@reflection_prompt),
              Messages.assistant(critique)
            ]

        if is_binary(response.thinking) and response.thinking != "" do
          ExAthena.Loop.Events.emit(state.on_event, {:thinking, response.thinking})
        end

        ExAthena.Loop.Events.emit(state.on_event, {:content, critique})

        {:ok, %{state | messages: new_messages}}
    end
  end
end
