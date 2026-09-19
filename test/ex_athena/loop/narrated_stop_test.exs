defmodule ExAthena.Loop.NarratedStopTest do
  @moduledoc """
  Issue 258. The shapes the closing-sentence rule has to get right, kept apart
  from the loop test so a change to the wording of one pattern shows up as one
  failing line rather than as a worker that stopped.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Loop.NarratedStop

  describe "narrated?/1 is true for a closing commitment to a next action" do
    for text <- [
          "I have everything I need. Writing the brief now.",
          "The scan is done. I'll write the brief to docs/design/258.html.",
          "Three call sites found. I will update each one.",
          "That settles the schema. I'm going to run the migration.",
          "I am about to open the router file.",
          "Next, I'll check the settings form.",
          "The conventions are clear. Let me draft the mock.",
          "- Now updating lib/web/theme.ex"
        ] do
      test text do
        assert NarratedStop.narrated?(unquote(text))
      end
    end
  end

  describe "narrated?/1 is false when the text is the deliverable" do
    for text <- [
          "The theme resolves at compile time; the settings form re-reads per render.",
          "Wrote the brief to docs/design/258.html and verified it opens.",
          "I found nothing in the router. Let me know if you want the call graph.",
          "The migration is unverified. I will not be running it from here.",
          "Two options fit. Which one do you want me to build?",
          "Nothing is failing now.",
          "Running the suite gave 2,258 tests and 0 failures.",
          "",
          nil
        ] do
      test inspect(text) do
        refute NarratedStop.narrated?(unquote(text))
      end
    end
  end

  # A report that mentions future work in its BODY is still a report — reading
  # the whole text instead of the closing sentence would fire on most of them.
  test "future work named mid-report does not count" do
    text = """
    The settings form will need a second pass once the tokens move to runtime.
    I checked all three call sites. The layout and the sidebar are unaffected.
    """

    refute NarratedStop.narrated?(text)
  end
end
