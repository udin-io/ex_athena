defmodule ExAthena.Tools.TodoWrite do
  @moduledoc """
  Writes the agent's todo list.

  Stored in `ctx.assigns[:todos]` by default; callers that want a different
  side channel (e.g. broadcasting to a LiveView) can override via
  `ctx.assigns[:todo_writer]` — a function `(list -> :ok)` that the tool
  will call instead of (or in addition to) mutating the assigns map.

  Arguments:

    * `todos` (required) — list of `%{content: String.t(), status: "pending"|"in_progress"|"completed"}`.

  The loop replays the new list back to the model so it has fresh state.
  """

  @behaviour ExAthena.Tool

  @valid_statuses ~w(pending in_progress completed)

  @impl true
  def name, do: "todo_write"

  @impl true
  def description,
    do: "Overwrite the agent's todo list. Each item has :content and :status."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        todos: %{
          type: "array",
          items: %{
            type: "object",
            properties: %{
              content: %{type: "string"},
              status: %{type: "string", enum: @valid_statuses},
              activeForm: %{type: "string"}
            },
            required: ["content", "status"]
          }
        }
      },
      required: ["todos"]
    }
  end

  @impl true
  def execute(%{"todos" => todos}, ctx) when is_list(todos) do
    with :ok <- validate_items(todos),
         :ok <- notify(ctx, todos) do
      {:ok, format(todos)}
    end
  end

  def execute(_, _), do: {:error, :missing_todos}

  defp validate_items(todos) do
    Enum.reduce_while(todos, :ok, fn item, :ok ->
      cond do
        not is_map(item) -> {:halt, {:error, :invalid_todo}}
        Map.get(item, "status") not in @valid_statuses -> {:halt, {:error, :invalid_status}}
        not is_binary(Map.get(item, "content")) -> {:halt, {:error, :invalid_content}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp notify(%{assigns: %{todo_writer: writer}}, todos) when is_function(writer, 1) do
    try do
      writer.(todos)
      :ok
    rescue
      e -> {:error, {:writer_crashed, Exception.message(e)}}
    end
  end

  defp notify(_ctx, _todos), do: :ok

  defp format(todos) do
    Enum.map_join(todos, "\n", fn %{"content" => c, "status" => s} ->
      marker =
        case s do
          "completed" -> "[x]"
          "in_progress" -> "[~]"
          _ -> "[ ]"
        end

      "#{marker} #{c}"
    end)
  end
end
