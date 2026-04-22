defmodule ExAthena.Modes.Reflexion do
  @moduledoc """
  Reflexion mode (PR 3).

  After each tool-use round, a self-critique pass reflects on the outcome
  before the next inference. Research caps this at ~3 iterations before
  degeneration-of-thought kicks in. Full implementation lands in PR 3.

  Falls back to `:not_implemented` errors today.
  """

  @behaviour ExAthena.Loop.Mode

  @impl true
  def init(_state), do: {:error, :reflexion_not_implemented_until_pr3}

  @impl true
  def iterate(_state), do: {:error, :reflexion_not_implemented_until_pr3}
end
