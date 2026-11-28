defmodule ExAthena.Chats.Codec do
  @moduledoc """
  Turns any term a chat holds into JSON values and back, exactly.

  Plain JSON loses atoms, atom keys, tuples, structs and raw bytes, so a
  message read back from a saved chat would differ from the one written
  (issue 146: the pin, the tool panel and argument key types were lost; issue
  150: a picture's bytes crashed the encoder). This codec tags each of those
  with a one-key object whose key starts with `$`:

    * atom → `{"$a": "name"}`
    * map with atom keys only → `{"$k": {...}}`; a struct adds `"$s": module`
    * any other map whose keys are not all plain strings → `{"$m": [[k, v], ...]}`
    * tuple → `{"$t": [...]}`
    * bytes that are not UTF-8 → `{"$b": base64}`

  A map of plain string keys, none starting with `$`, stays a plain object.

  Decoding never creates an atom: a name the running system does not know
  stays a string, and a struct whose module is not loaded reads back as a
  plain map. A hand-edited file can therefore not exhaust the atom table.
  Pids, references and functions cannot be saved; they come back as their
  `inspect/1` text.
  """

  @spec encode(term()) :: term()
  def encode(term) when is_nil(term) or is_boolean(term) or is_number(term), do: term

  def encode(term) when is_atom(term), do: %{"$a" => Atom.to_string(term)}

  def encode(term) when is_binary(term) do
    if String.valid?(term), do: term, else: %{"$b" => Base.encode64(term)}
  end

  def encode(term) when is_list(term), do: Enum.map(term, &encode/1)

  def encode(term) when is_tuple(term), do: %{"$t" => term |> Tuple.to_list() |> encode()}

  def encode(%module{} = struct) do
    %{"$s" => Atom.to_string(module), "$k" => struct |> Map.from_struct() |> encode_atom_keys()}
  end

  def encode(term) when is_map(term) do
    keys = Map.keys(term)

    cond do
      keys != [] and Enum.all?(keys, &is_atom/1) ->
        %{"$k" => encode_atom_keys(term)}

      Enum.all?(keys, &plain_key?/1) ->
        Map.new(term, fn {k, v} -> {k, encode(v)} end)

      true ->
        %{"$m" => Enum.map(term, fn {k, v} -> [encode(k), encode(v)] end)}
    end
  end

  def encode(term), do: inspect(term)

  defp encode_atom_keys(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), encode(v)} end)

  defp plain_key?(key),
    do: is_binary(key) and String.valid?(key) and not String.starts_with?(key, "$")

  @spec decode(term()) :: term()
  def decode(%{"$a" => name}) when is_binary(name), do: to_atom(name)
  def decode(%{"$b" => data}) when is_binary(data), do: Base.decode64!(data)

  def decode(%{"$t" => items}) when is_list(items),
    do: items |> Enum.map(&decode/1) |> List.to_tuple()

  def decode(%{"$s" => module, "$k" => fields}) when is_binary(module) and is_map(fields) do
    map = decode_atom_keys(fields)

    case to_atom(module) do
      mod when is_atom(mod) ->
        # struct/2 fills a field an older file lacks with its default.
        if Code.ensure_loaded?(mod) and function_exported?(mod, :__struct__, 0),
          do: struct(mod, map),
          else: map

      _ ->
        map
    end
  end

  def decode(%{"$k" => fields}) when is_map(fields), do: decode_atom_keys(fields)

  def decode(%{"$m" => pairs}) when is_list(pairs) do
    Map.new(pairs, fn [k, v] -> {decode(k), decode(v)} end)
  end

  def decode(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, decode(v)} end)
  def decode(list) when is_list(list), do: Enum.map(list, &decode/1)
  def decode(term), do: term

  defp decode_atom_keys(map), do: Map.new(map, fn {k, v} -> {to_atom(k), decode(v)} end)

  defp to_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end
end
