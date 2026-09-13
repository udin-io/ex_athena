defmodule ExAthena.Budget do
  @moduledoc """
  Usage + cost accounting and budget checks for agent runs.

  Aggregates `Usage` (input/output/total tokens) across loop iterations and
  computes cost in USD from provider metadata. A run can be capped by
  `:max_budget_usd`; the loop tests `Budget.exceeded?/2` before each
  iteration and trips `:error_max_budget_usd` when the cap is hit.

  ## Shape

      %Budget{
        usage: %{input_tokens: _, output_tokens: _, total_tokens: _},
        cost_usd: float | nil,
        started_at: integer,       # monotonic ms
      }
  """

  defstruct usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
            cost_usd: nil,
            started_at: nil

  @type usage_map :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer(),
          optional(:reasoning_tokens) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          usage: usage_map(),
          cost_usd: float() | nil,
          started_at: integer() | nil
        }

  @doc "New budget accumulator."
  @spec new() :: t()
  def new do
    %__MODULE__{
      usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      cost_usd: nil,
      started_at: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Merge a single turn's usage + optional cost into the accumulator.

  Missing keys on the incoming usage are treated as 0. Cost additions that
  start from `nil` become a float.
  """
  @spec add(t(), usage_map() | nil, float() | nil) :: t()
  def add(%__MODULE__{} = budget, nil, _), do: budget

  def add(%__MODULE__{} = budget, incoming_usage, cost_usd)
      when is_map(incoming_usage) do
    new_usage = merge_usage(budget.usage, incoming_usage)
    new_cost = add_cost(budget.cost_usd, cost_usd)
    %{budget | usage: new_usage, cost_usd: new_cost}
  end

  @doc """
  Test whether the budget has exceeded an optional cap.

  When `max_budget_usd` is `nil`, budget is never exceeded. When non-nil,
  returns `true` as soon as `cost_usd` meets or exceeds it.
  """
  @spec exceeded?(t(), float() | nil) :: boolean()
  def exceeded?(_budget, nil), do: false

  def exceeded?(%__MODULE__{cost_usd: nil}, _cap), do: false

  def exceeded?(%__MODULE__{cost_usd: cost}, cap)
      when is_number(cap) and is_number(cost) and cost >= cap,
      do: true

  def exceeded?(_budget, _cap), do: false

  @doc """
  Whether cumulative INPUT tokens have reached `cap`. `nil` cap never trips.

  The cost cap above is inert on a local provider, where every call is free —
  so wall clock was the only rail a worker had, and 30 minutes holds a great
  deal of context. Live, one implementer spent 1,992,051 input tokens over 38
  iterations and completed none of its eight sub-steps; its replacement spent
  another 920,357 and hit the same wall. Across 41 workers that finished, the
  most any of them ever used was 701,896 — a worker far past that is not
  close to done, it is lost.

  Input rather than total: input is what grows with the context and what runs
  away (1.99M in against 20.8k out on the worker above).
  """
  @spec input_exceeded?(t(), pos_integer() | nil) :: boolean()
  def input_exceeded?(_budget, nil), do: false

  def input_exceeded?(%__MODULE__{usage: usage}, cap)
      when is_integer(cap) and cap > 0 do
    Map.get(usage, :input_tokens, 0) >= cap
  end

  def input_exceeded?(_budget, _cap), do: false

  @doc "Wall-clock milliseconds since budget was opened."
  @spec duration_ms(t()) :: non_neg_integer()
  def duration_ms(%__MODULE__{started_at: nil}), do: 0

  def duration_ms(%__MODULE__{started_at: t0}) do
    System.monotonic_time(:millisecond) - t0
  end

  # ── Private ────────────────────────────────────────────────────────

  defp merge_usage(a, b) do
    merged = %{
      input_tokens: fetch_int(a, :input_tokens) + fetch_int(b, :input_tokens),
      output_tokens: fetch_int(a, :output_tokens) + fetch_int(b, :output_tokens),
      total_tokens: fetch_int(a, :total_tokens) + fetch_int(b, :total_tokens)
    }

    # Reasoning tokens are preserved (not dropped) so `Result.usage` can
    # support starvation diagnostics (#194) — but the key only appears once
    # a provider actually reported it, keeping non-reasoning providers'
    # usage maps unchanged.
    if has_int?(a, :reasoning_tokens) or has_int?(b, :reasoning_tokens) do
      Map.put(
        merged,
        :reasoning_tokens,
        fetch_int(a, :reasoning_tokens) + fetch_int(b, :reasoning_tokens)
      )
    else
      merged
    end
  end

  defp has_int?(map, key) when is_map(map) do
    is_integer(Map.get(map, key) || Map.get(map, to_string(key)))
  end

  defp fetch_int(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp add_cost(nil, nil), do: nil
  defp add_cost(a, nil), do: a
  defp add_cost(nil, b), do: b * 1.0
  defp add_cost(a, b), do: a + b * 1.0
end
