defmodule ExAthena.ModelSize do
  @moduledoc """
  How large a model is, in billions of parameters, when we can tell.

  The one chat treats a small model differently (issue 321): it is told to
  keep a to-do list, and its helper tool starts switched off. The size comes
  from the model's name first (`qwen2.5-coder:7b`, `Qwen3-8B-Instruct`,
  `gemma4:e2b`, `gemma3:270m`), because that needs no server. Failing that, an
  Ollama server's own report of the size is asked once
  (`ExAthena.ContextWindow.params_b/1`).

  `nil` means unknown, and callers treat an unknown model as large. Most hosted
  models (`gpt-4o-mini`, `claude-3-5-haiku`) state no size, so they keep their
  helpers; a hosted name that does state one (`llama-3.1-8b-instant`) counts by
  that size, like any other.
  """

  # `7b`, `1.5b`, `e2b` (Gemma's "effective" size), `8B` and `270m` alike, as
  # a whole token: `qwen2.5` alone carries no size, and `a3b` (the active share
  # of a mixture model) is not the model's size. Millions take three digits or
  # more, because `[1m]` and `:1m` name a context length, not a size.
  @name_re ~r/(?:^|[^a-z0-9.])(?:e?(\d+(?:\.\d+)?)(b)|(\d{3,})(m))(?![a-z0-9])/i

  @doc """
  The size a model name states, or nil.

      iex> ExAthena.ModelSize.from_name("qwen2.5-coder:7b")
      7.0
      iex> ExAthena.ModelSize.from_name("Qwen3-8B-Instruct")
      8.0
      iex> ExAthena.ModelSize.from_name("gemma4:e2b")
      2.0
      iex> ExAthena.ModelSize.from_name("qwen3:30b-a3b")
      30.0
      iex> ExAthena.ModelSize.from_name("gemma3:270m")
      0.27
      iex> ExAthena.ModelSize.from_name("qwen2.5-coder:latest")
      nil
  """
  @spec from_name(String.t() | nil) :: float() | nil
  def from_name(name) when is_binary(name) do
    case Regex.run(@name_re, name) do
      [_, n, unit] -> scale(parse_number(n), unit)
      [_, "", "", n, unit] -> scale(parse_number(n), unit)
      _ -> nil
    end
  end

  def from_name(_), do: nil

  @doc """
  A size as Ollama writes it (`"14.8B"`, `"268.10M"`), in billions, or nil.

      iex> ExAthena.ModelSize.parse_size("14.8B")
      14.8
      iex> ExAthena.ModelSize.parse_size("268.10M")
      0.2681
      iex> ExAthena.ModelSize.parse_size("big")
      nil
  """
  @spec parse_size(term()) :: float() | nil
  def parse_size(text) when is_binary(text) do
    case Regex.run(~r/^\s*(\d+(?:\.\d+)?)\s*([bm])\s*$/i, text) do
      [_, n, unit] -> scale(parse_number(n), unit)
      _ -> nil
    end
  end

  def parse_size(_), do: nil

  @doc """
  The size of the model `opts` names: from its name, else from its Ollama
  server. Reads `:model`, and for the server the same options as
  `ExAthena.ContextWindow.lookup/1`.
  """
  @spec lookup(keyword()) :: float() | nil
  def lookup(opts) do
    from_name(Keyword.get(opts, :model)) || ExAthena.ContextWindow.params_b(opts)
  end

  defp scale(nil, _unit), do: nil
  defp scale(n, unit) when unit in ["m", "M"], do: Float.round(n / 1000, 4)
  defp scale(n, _b), do: n

  defp parse_number(text) do
    case Float.parse(text) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
