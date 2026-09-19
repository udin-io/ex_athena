defmodule ExAthena.Loop.NarratedStop do
  @moduledoc """
  Telling a worker that stopped mid-task from one that finished.

  `ExAthena.Modes.ReAct` treats a turn with no tool calls as terminal. For a
  worker that is usually right — the text is the report — but it also ends the
  run when the model spends the turn saying what it will do NEXT. Web session
  `cfcf79154cb1`, worker `subagent_J8xXdYDq`: 15 iterations, 38 tool calls,
  608,954 input tokens and 19 minutes, then

      … Writing the brief now.

  `finish_reason: :stop`, `ok: true`, no brief. Nothing was killed and no
  budget fired.

  ## What counts as narrated

  Only the CLOSING sentence is read, and only for a first-person commitment to
  an action the worker has not taken: `I'll …`, `I will …`, `I'm going to …`,
  `I'm about to …`, `Next I'll …`, `Let me <verb> …`, or the subject-less
  present participle the live failure used (`Writing the brief now.`).

  The closing sentence is the whole test because that is where the two cases
  differ. A worker that finished closes on its result — findings, a path, a
  count, a past-tense account of what it did. A worker that stopped mid-task
  closes on a promise. A report may well mention future work in its body ("the
  settings form will need a second pass"); reading the body would fire on
  every such report, and `ExAthena.Agents.Summariser` is what turns a report
  into the parent's digest, so the body is not a place to guess from.

  Three exclusions carry the same weight as the patterns:

  * `Let me know …` — the commonest polite closer there is, and never a
    commitment to do anything.
  * `I will not …` / `I'll not …` — a negation is a report of work NOT done,
    which is exactly the honest handback the nudge asks for.
  * A sentence ending in `?` — a worker asking its parent a question has
    finished its turn deliberately.

  ## Why the rule is deliberately narrow

  An `explore` or `research` worker's deliverable IS its final text, so it has
  to stop cleanly on its first `:stop`. Firing on every text-ending worker
  would spend one extra model turn on every research spawn in the tree, which
  is worse than the bug it fixes: the bug costs one worker's run, occasionally,
  and the over-broad rule costs every worker a turn, always.

  The asymmetry runs the other way too, which is why the rule fires on a
  match alone and does not also demand that the run produced no file. A worker
  that wrote three files and then closes with "Now I'll run the tests" is in
  the same failure — its run ends with the tests unrun — and an artifact on
  disk says nothing about whether the sentence was kept.
  """

  @doc """
  Does this end-of-turn text close by announcing an action not yet taken?
  """
  @spec narrated?(String.t() | nil) :: boolean()
  def narrated?(text) when is_binary(text) do
    case closing_sentence(text) do
      nil -> false
      sentence -> commitment?(sentence)
    end
  end

  def narrated?(_text), do: false

  # First-person commitment to a next action …
  @commitment ~r/
      \b i (?: ['\x{2019}] ll | \s+ will ) \s+ (?! not \b)
    | \b i (?: ['\x{2019}] m | \s+ am ) \s+ (?: now \s+)? (?: going | about ) \s+ to \b
    | \b let \s+ (?: me | us ) \s+ (?! know \b)
    | \b let ['\x{2019}] s \s+ (?! know \b)
  /xiu

  # … or the subject-less participle a small model uses for the same thing:
  # "Writing the brief now." The verb list is explicit because a bare `\w+ing`
  # also matches "Nothing", "Everything" and "During".
  @imminent ~r/
    ^ \s* (?: (?: now | next ) \s* ,? \s* )? (?:
      writing | creating | drafting | building | generating | producing |
      preparing | running | adding | updating | implementing | fixing |
      starting | proceeding | continuing | finishing | doing | making |
      putting
    ) \b
  /xiu

  defp commitment?(sentence) do
    cond do
      String.ends_with?(sentence, "?") -> false
      Regex.match?(@commitment, sentence) -> true
      Regex.match?(@imminent, sentence) and sentence =~ ~r/\bnow\b/i -> true
      true -> false
    end
  end

  # The last sentence, with Markdown decoration stripped. A trailing list item
  # or heading counts as a sentence: a narrating model writes prose, but it
  # does not always punctuate it.
  defp closing_sentence(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+|\n+/u, trim: true)
    |> Enum.map(&(&1 |> String.replace(~r/^[\s>*#\-\d.)\x{2022}]+/u, "") |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> List.last()
  end
end
