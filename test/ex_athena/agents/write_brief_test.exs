defmodule ExAthena.Agents.WriteBriefTest do
  @moduledoc """
  The detector behind the spawn-time write rail (#217).

  This is the only rail in the codebase whose correctness is a judgement
  call, so the table below IS the specification. A false negative costs what
  it costs today — session `5906635b743d` burned 24.6 minutes and 540K input
  tokens on a report nobody could save. A false positive refuses work that
  would have succeeded, and the model has no way to argue back. The table is
  therefore biased: every negative drawn from a brief shape that really
  occurs in this repo (`priv/agents/*.md`, the spawn prompts in `test/`),
  and a positive only where the brief plainly orders a file into existence.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Agents.WriteBrief

  describe "asks_for_a_file?/1 — positives" do
    # The literal opening of the brief that cost session 5906635b743d its run.
    @positives [
      "WRITE THE RESULT TO A FILE: `plan/uat_testing/guides-39-76-extract.md`",
      "Write your findings to plan/analysis.md",
      "Extract sections 39-76 and save the extraction to `docs/guides.md`",
      "Create a file at docs/report.md summarising every guide section.",
      "Read the guides. Then write them to a file.",
      "- Save the output to report.md",
      "You must write the results into a file.",
      "Your task is to write the full extraction to a file.",
      "1. Write the table to docs/table.md",
      "Then append your notes to the file `notes.md`.",
      "Store the inventory in a file under docs/.",
      "**Deliverable:** write the summary to `out/summary.md`"
    ]

    for {brief, i} <- Enum.with_index(@positives) do
      test "#{i}: #{String.slice(brief, 0, 60)}" do
        assert WriteBrief.asks_for_a_file?(unquote(brief))
      end
    end
  end

  describe "asks_for_a_file?/1 — negatives" do
    # Every one of these is a shape a read-only worker is legitimately given.
    @negatives [
      # The acceptance criterion from #217.
      "read the config file and write up what you find",
      # Real spawn prompts already in this repo's test suite.
      "explore the repo structure and report back",
      "read marker.txt",
      "examine the file",
      "extract the guides",
      "capture the compile error",
      # The runtime default for `expected_output` (@brief_defaults).
      "a self-contained summary (max 300 words) of findings, decisions, and files changed",
      # A path token next to the word "write" — but as a filename, not an order.
      "Read lib/ex_athena/tools/write.ex and summarise what it does",
      "Compare the write tool to lib/ex_athena/tools/edit.ex and report the differences",
      # Descriptive rather than imperative.
      "Explain how to write a file with the write tool",
      "Find where the loop writes the session file and explain when it happens",
      "List every module that can write to disk",
      "Document the public API of ExAthena.Loop in your reply",
      "Describe the file format used by .exathena/sessions/*.jsonl",
      # Prose "write", not a file.
      "Summarise the guides and write up your findings in the report",
      "Note the three call sites and write a short paragraph on each",
      # The brief telling the worker NOT to write.
      "Investigate only. Do not write any files.",
      "Do only this step; do not start or modify anything outside its scope."
    ]

    for {brief, i} <- Enum.with_index(@negatives) do
      test "#{i}: #{String.slice(brief, 0, 60)}" do
        refute WriteBrief.asks_for_a_file?(unquote(brief))
      end
    end

    test "nil and blank briefs ask for nothing" do
      refute WriteBrief.asks_for_a_file?(nil)
      refute WriteBrief.asks_for_a_file?("")
      refute WriteBrief.asks_for_a_file?("   \n ")
    end
  end

  describe "write_capable?/1" do
    test "a toolset carrying any file-mutating builtin is capable" do
      for tool <- ~w(write edit apply_patch bash) do
        assert WriteBrief.write_capable?(["read", "grep", tool])
      end
    end

    # `plan` declares `write`, scoped by the host to `.exathena/plans/`.
    # The rail keys on the toolset, never on the agent's name.
    test "the plan agent's toolset is write-capable" do
      assert WriteBrief.write_capable?(
               ~w(read glob grep lsp web_fetch web_search usage_rules write)
             )
    end

    # todo_write is granted to EVERY worker and writes no file; if it counted,
    # the rail would never fire.
    test "explore's toolset is not write-capable, todo_write included" do
      refute WriteBrief.write_capable?(
               ~w(read glob grep lsp web_fetch web_search usage_rules todo_write spawn_agent)
             )
    end
  end

  describe "refusal/3" do
    @readonly ~w(read glob grep lsp web_fetch web_search usage_rules)

    test "names the agent, its actual tools, the offending phrase and implementer" do
      message =
        WriteBrief.refusal(
          "WRITE THE RESULT TO A FILE: `plan/uat_testing/guides.md`",
          @readonly,
          "explore"
        )

      assert message =~ "explore"
      assert message =~ "implementer"
      assert message =~ "web_search"
      assert message =~ "WRITE THE RESULT TO A FILE"
    end

    test "a write-capable toolset is never refused, whatever the brief says" do
      assert WriteBrief.refusal(
               "WRITE THE RESULT TO A FILE: `out.md`",
               @readonly ++ ["write"],
               "explore"
             ) == nil
    end

    test "a read-only toolset with no file instruction is never refused" do
      assert WriteBrief.refusal(
               "read the config file and write up what you find",
               @readonly,
               "explore"
             ) == nil
    end

    test "an anonymous spawn narrowed to read-only tools still gets the rail" do
      message = WriteBrief.refusal("Write your findings to notes.md", @readonly, nil)

      assert message =~ "implementer"
      refute message =~ "agent \""
    end

    test "a brief is the prompt plus objective plus expected_output" do
      brief =
        WriteBrief.brief(%{
          "prompt" => "extract sections 39-76 of the guides",
          "objective" => "a complete extraction",
          "expected_output" => "write the extraction to `out/guides.md`",
          "boundaries" => "do not touch anything else"
        })

      assert WriteBrief.asks_for_a_file?(brief)
      refute brief =~ "do not touch anything else"
    end
  end
end
