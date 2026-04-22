defmodule ExAthena.ToolCalls.TextTagged do
  @moduledoc """
  Parses `~~~tool_call` fenced blocks out of assistant text.

  The contract with the model (enforced by the system-prompt preamble added by
  `ExAthena.ToolCalls.augment_system_prompt/2`):

      ~~~tool_call
      {"name": "read_file", "arguments": {"path": "/foo/bar"}}
      ~~~

  Rules:

    * One block per call. Multiple blocks in one response are allowed.
    * Both fences must be on their own lines.
    * `id` is optional in the payload; missing ids are generated server-side.
    * Malformed JSON in a block is returned as an error on that block; other
      well-formed blocks in the same text are still parsed (best-effort).

  A valid `~~~tool_call` block carries the model's intent to call a tool even
  if the model also emitted a prose preamble around the block — this parser
  returns tool calls only; the prose is left alone and should not be replayed
  as a response to the user until the tools have actually run.
  """

  alias ExAthena.Messages.ToolCall

  @fence_regex ~r/~~~tool_call\s*\n(.*?)\n~~~/s

  @doc "Extract tool calls from assistant text. Always returns a list."
  @spec parse(String.t()) :: {:ok, [ToolCall.t()]} | {:error, term()}
  def parse(text) when is_binary(text) do
    case Regex.scan(@fence_regex, text, capture: :all_but_first) do
      [] ->
        {:ok, []}

      matches ->
        matches
        |> Enum.map(fn [json] -> parse_block(json) end)
        |> Enum.reduce_while({:ok, []}, fn
          {:ok, tc}, {:ok, acc} -> {:cont, {:ok, acc ++ [tc]}}
          {:error, _} = err, _ -> {:halt, err}
        end)
    end
  end

  defp parse_block(json) do
    with {:ok, decoded} <- Jason.decode(json),
         {:ok, name} <- fetch_name(decoded),
         {:ok, args} <- fetch_arguments(decoded) do
      {:ok,
       %ToolCall{
         id: Map.get(decoded, "id") || generate_id(),
         name: name,
         arguments: args
       }}
    end
  end

  defp fetch_name(%{"name" => name}) when is_binary(name) and name != "", do: {:ok, name}
  defp fetch_name(_), do: {:error, :missing_tool_name}

  defp fetch_arguments(%{"arguments" => args}) when is_map(args), do: {:ok, args}
  defp fetch_arguments(%{"arguments" => nil}), do: {:ok, %{}}

  defp fetch_arguments(%{"arguments" => args}) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_arguments}
    end
  end

  defp fetch_arguments(map) when is_map(map), do: {:ok, %{}}

  defp generate_id do
    "call_" <>
      (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
  end
end
