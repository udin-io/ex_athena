defmodule ExAthena.Tools.SpawnAgent do
  @moduledoc """
  Synchronously run a sub-agent-loop with its own prompt, tools, and budget.

  Useful for delegating a bounded task (exploring a codebase, summarising a
  file) to a fresh conversation with its own message history — so the parent
  loop doesn't pay the token cost of the sub-task's intermediate steps.

  Arguments:

    * `prompt` (required) — the sub-agent's opening message.
    * `tools` (optional) — list of tool names to expose to the sub-agent; defaults
      to whatever the parent had (minus PlanMode + SpawnAgent to avoid loops).
    * `max_iterations` (optional, default 10) — cap on agent-loop iterations.
    * `system_prompt` (optional) — system prompt override for the sub-agent.

  Inherits the parent's provider / model / permissions unless overridden in
  `ctx.assigns[:spawn_agent_opts]`.
  """

  @behaviour ExAthena.Tool

  @default_max_iterations 10

  @impl true
  def name, do: "spawn_agent"

  @impl true
  def description,
    do:
      "Run a synchronous sub-agent with its own fresh conversation to accomplish a focused sub-task. Returns the sub-agent's final text."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        prompt: %{type: "string"},
        tools: %{type: "array", items: %{type: "string"}},
        max_iterations: %{type: "integer"},
        system_prompt: %{type: "string"}
      },
      required: ["prompt"]
    }
  end

  @impl true
  def execute(%{"prompt" => prompt} = args, ctx) when is_binary(prompt) do
    sub_opts =
      (ctx.assigns[:spawn_agent_opts] || [])
      |> Keyword.put_new(:max_iterations, Map.get(args, "max_iterations", @default_max_iterations))
      |> maybe_put(:system_prompt, Map.get(args, "system_prompt"))
      |> maybe_put(:tools, resolve_tools(Map.get(args, "tools"), ctx))
      |> Keyword.put(:assigns, ctx.assigns)
      |> Keyword.put(:cwd, ctx.cwd)

    case ExAthena.Loop.run(prompt, sub_opts) do
      {:ok, %{text: text}} -> {:ok, text || ""}
      {:error, reason} -> {:error, {:sub_agent_failed, reason}}
    end
  end

  def execute(_, _), do: {:error, :missing_prompt}

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  # Pass names through; the loop resolves names → modules. Filter out the
  # meta tools to avoid runaway recursion.
  defp resolve_tools(nil, _ctx), do: nil

  defp resolve_tools(names, _ctx) when is_list(names) do
    names
    |> Enum.reject(&(&1 in ["plan_mode", "spawn_agent"]))
  end
end
