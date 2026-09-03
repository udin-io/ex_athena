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

  def execute(_, _) do
    {:error,
     "missing `todos`: pass a list of objects, each with `content` (string) " <>
       "and `status` (one of #{valid_statuses()})."}
  end

  # A rejection the model can act on. Bare atoms (`:invalid_status`) named
  # neither the offending item nor the accepted values, and a small model
  # reading one just repeats the identical call — live, two runs each lost an
  # iteration to exactly that.
  defp validate_items(todos) do
    todos
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {item, n}, :ok ->
      case problem(item) do
        nil -> {:cont, :ok}
        message -> {:halt, {:error, "todo #{n}#{label(item)}: #{message}"}}
      end
    end)
  end

  defp problem(item) when not is_map(item),
    do: "must be an object with `content` and `status`, got #{inspect(item)}"

  defp problem(item) do
    status = Map.get(item, "status")

    cond do
      is_nil(status) ->
        "missing `status` — must be one of #{valid_statuses()}"

      status not in @valid_statuses ->
        "unrecognised status #{inspect(status)} — must be one of #{valid_statuses()}"

      not is_binary(Map.get(item, "content")) ->
        "`content` must be a string, got #{inspect(Map.get(item, "content"))}"

      true ->
        nil
    end
  end

  # Quote the content when there is one, so the model can see WHICH todo it
  # has to fix rather than counting list positions.
  defp label(item) when is_map(item) do
    case Map.get(item, "content") do
      content when is_binary(content) -> " (#{inspect(content)})"
      _ -> ""
    end
  end

  defp label(_item), do: ""

  defp valid_statuses, do: Enum.map_join(@valid_statuses, ", ", &inspect/1)

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
