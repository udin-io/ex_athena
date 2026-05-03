defmodule ExAthena.ToolCalls.Native do
  @moduledoc """
  Parses native tool-call structures from provider responses.

  Handles the three common shapes:

    1. OpenAI / Ollama — `%{id:, type: "function", function: %{name:, arguments: "json"}}`.
       `arguments` is almost always a JSON-encoded string.

    2. Claude — `%{type: "tool_use", id:, name:, input: map()}`.

    3. Pre-parsed — already-parsed `%{id:, name:, arguments: map()}`. No-op.

  Tolerant of both atom and string keys, and tolerant of either a JSON string
  or a decoded map for `arguments`.
  """

  alias ExAthena.Messages.ToolCall

  @spec parse(list()) :: {:ok, [ToolCall.t()]} | {:error, term()}
  def parse(calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
      case parse_one(call) do
        {:ok, tc} -> {:cont, {:ok, acc ++ [tc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_one(%ToolCall{} = tc), do: {:ok, tc}

  defp parse_one(%{"type" => "function", "id" => id, "function" => fun}) do
    build(id, fetch(fun, "name"), fetch(fun, "arguments"))
  end

  defp parse_one(%{type: "function", id: id, function: fun}) do
    build(
      id,
      fetch(fun, :name) || fetch(fun, "name"),
      fetch(fun, :arguments) || fetch(fun, "arguments")
    )
  end

  defp parse_one(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    build(id, name, input)
  end

  defp parse_one(%{type: "tool_use", id: id, name: name, input: input}) do
    build(id, name, input)
  end

  defp parse_one(%{"id" => id, "name" => name} = map) do
    build(id, name, Map.get(map, "arguments") || Map.get(map, "input") || %{})
  end

  defp parse_one(%{id: id, name: name} = map) do
    build(id, name, Map.get(map, :arguments) || Map.get(map, :input) || %{})
  end

  defp parse_one(other), do: {:error, {:unrecognised_tool_call, other}}

  defp build(_id, nil, _args), do: {:error, :missing_tool_name}

  defp build(id, name, args) do
    with {:ok, arguments} <- normalise_arguments(args) do
      {:ok,
       %ToolCall{
         id: id || generate_id(),
         name: to_string(name),
         arguments: arguments
       }}
    end
  end

  defp normalise_arguments(nil), do: {:ok, %{}}
  defp normalise_arguments(map) when is_map(map), do: {:ok, map}

  defp normalise_arguments(str) when is_binary(str) do
    trimmed = String.trim(str)

    cond do
      trimmed == "" -> {:ok, %{}}
      true -> Jason.decode(trimmed)
    end
  end

  defp normalise_arguments(other), do: {:error, {:invalid_arguments, other}}

  defp fetch(map, key) when is_map(map), do: Map.get(map, key)
  defp fetch(_, _), do: nil

  defp generate_id do
    "call_" <>
      (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
  end
end
