defmodule ExAthena.Tools.Finish do
  @moduledoc """
  Built-in completion signal tool.

  The model calls `finish` to declare that the current task or phase is done
  and optionally supply a deliverable payload. The loop recognises this call,
  stops cleanly with `finish_reason: :submitted`, and surfaces the deliverable
  on `Result.deliverable`.

  This is far more reliable than free-text sentinels for weak or local models:
  a structured tool call is explicit and unambiguous regardless of model size or
  provider.

  Arguments (all optional):

    * `deliverable` — the primary output of the completed task (plan text, a
      JSON summary, a file path, etc.).
    * `summary` — a brief human-readable description of what was accomplished.
      Used as the deliverable when `deliverable` is absent.

  ## The halt payload names the argument

  `execute/2` halts with `{:submitted, payload, source}`, where `source` is
  `:deliverable`, `:summary` or `:none`. `ExAthena.Loop` carries it onto
  `Result.deliverable_source`, and `ExAthena.Tools.SpawnAgent` reads it to
  decide whether a worker's payload reaches its parent verbatim (issue 263).

  The two arguments are not interchangeable for that decision. `deliverable` is
  the task's primary output, packaged deliberately for the caller; `summary` is
  by its own description a brief account of what was done — the shape issue 251
  was about, where a worker's self-summary replaced the work it referred to.

  ## Usage rules

  Add `ExAthena.Tools.Finish` to the tool list (or use the default `:all`
  builtin set) and instruct the model in the system prompt to call `finish`
  when its task is complete:

      system_prompt: \"""
      When you have finished the task, call the `finish` tool with your
      deliverable so the caller can capture it.
      \"""

  The caller receives `result.finish_reason == :submitted` and
  `result.deliverable` instead of needing to parse free text.
  """

  @behaviour ExAthena.Tool

  @impl true
  def name, do: "finish"

  @impl true
  def description,
    do:
      "Signal that the current task or phase is complete. " <>
        "Call this tool when you have finished your work. " <>
        "Optionally supply a `deliverable` (your primary output) or `summary` " <>
        "(a brief description of what you accomplished). " <>
        "The loop will stop and surface the deliverable to the caller."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        deliverable: %{
          type: "string",
          description:
            "The primary output or result of the completed task " <>
              "(plan text, summary, file path, etc.)."
        },
        summary: %{
          type: "string",
          description:
            "A brief human-readable description of what was accomplished. " <>
              "Used as the deliverable when `deliverable` is not provided."
        }
      },
      required: []
    }
  end

  @impl true
  def parallel_safe?, do: false

  @impl true
  def execute(args, _ctx) do
    {:halt, submitted(Map.get(args, "deliverable"), Map.get(args, "summary"))}
  end

  # A blank `deliverable` is not an output, so it falls through to `summary`
  # rather than declaring an empty one.
  defp submitted(deliverable, summary) do
    cond do
      not blank?(deliverable) -> {:submitted, deliverable, :deliverable}
      not blank?(summary) -> {:submitted, summary, :summary}
      true -> {:submitted, deliverable || summary, :none}
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_other), do: false
end
