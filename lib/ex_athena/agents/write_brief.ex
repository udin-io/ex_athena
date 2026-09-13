defmodule ExAthena.Agents.WriteBrief do
  @moduledoc """
  Does this brief order a file into existence, and can the worker obey?

  Session `5906635b743d` handed `agent: "explore"` a brief beginning *"WRITE
  THE RESULT TO A FILE"*. `priv/agents/explore.md` declares no `write` and no
  `bash`, so the worker spent 24.6 minutes and 540K input tokens producing a
  report it could not save, and two further workers were spawned purely to
  probe whether writing was possible at all. Two prompt-level rails already
  say not to do this — `Modes.Orchestrate`'s protocol tells the orchestrator,
  and `explore.md` tells the worker — and the model ignored the first. This
  is the code rail behind them (issue 217).

  ## Why the answer is a judgement call

  Every other rail in `ExAthena.Tools.SpawnAgent` reads a number: a depth, a
  count, a deadline. This one reads English written by a model, so it can be
  wrong in two directions with very different prices:

    * a **missed** write brief costs exactly what it costs today — the rail
      simply does not fire, and `explore.md`'s prompt guard is still there to
      catch it one turn later;
    * a **false** refusal blocks a spawn that would have succeeded, and the
      model has no way to argue back.

  The detector is therefore built to under-fire. It demands an imperative
  verb in an instruction position governing a *file* — never a bare "write",
  which real briefs use for prose ("write up your findings", "write a short
  paragraph"). `ExAthena.Agents.WriteBriefTest` carries the full table of
  positives and negatives; the negatives are drawn from briefs that actually
  occur in this repo rather than invented ones.

  ## Capability is read off the toolset, never the agent's name

  `plan` is not a read-only agent — it declares `write`, scoped by the host
  to `.exathena/plans/`. An `explore` a caller has granted `write` to is not
  read-only either, and a custom read-only agent nobody here has heard of
  must get the same rail as `explore`. So the question asked is only ever
  "does this toolset contain a tool that can put bytes in a file".
  """

  alias ExAthena.Tool.Spec

  # Builtins that can create or modify a file. `todo_write` is deliberately
  # absent: every worker is granted it (see `SpawnAgent.resolve_tools/3`), so
  # counting it would make the rail unreachable, and it writes no file the
  # parent could read.
  @file_writing_tools ~w(write edit apply_patch bash)

  # Fields the brief is assembled from — the same three `SpawnAgent`'s
  # `@prompt_sources` and brief protocol treat as the instruction. `todo` is
  # covered because `resolve_prompt/1` promotes it to `prompt` when nothing
  # better exists. `boundaries` and `tool_guidance` are excluded on purpose:
  # a boundary that says "do not write any files" is the opposite of an order
  # to write one.
  @brief_fields ~w(prompt objective expected_output)

  # An instruction position: the start of the text, a sentence or list
  # boundary (with any markdown bullet/number noise skipped), a connective
  # that introduces an order, or the "X is to …" construction. Everything
  # else is prose ABOUT writing — "how to write a file", "the write tool",
  # "where the loop writes the session file" — and must not fire.
  @anchor "(?:\\A|[\\n.!?:;])[\\s*_>#•\\-\\d.)\\]\\[]*" <>
            "|\\b(?:then|also|finally|next|first|and|must|should|shall|please|now)\\s+" <>
            "|\\b(?:is|are|need|needs|want|wants|have|has)\\s+to\\s+"

  # Verbs that can order a file into existence. `document`, `describe`,
  # `note`, `list`, `summarise`, `report` and `produce` are out: they name a
  # deliverable, not a file. "write up" is excluded explicitly — it is the
  # single most common false positive in a real brief.
  @verb "(?:write|save|create|append|output|store|persist|dump)\\b(?![-\\s]+up\\b)"

  # A path-shaped token: something with a file extension a brief would
  # plausibly ask for.
  @path "[\\w.~/-]*[\\w-]\\.(?:md|markdown|txt|json|csv|tsv|ya?ml|html?|xml|log|exs?|sql|py|js|ts|toml|ini|rst|org|pdf|tex)\\b"

  # Between the verb and its object: a short run with no sentence end in it,
  # so the match cannot straddle two sentences.
  @filler "[^.!?\\n]{0,40}?"

  # Verb governing a file through a preposition — "write the result TO A
  # FILE", "save the extraction TO `docs/guides.md`". The determiner is
  # required so that "defined in file foo.ex" cannot match.
  @prepositional "\\b(?:to|into|in|at|under|as)\\s+" <>
                   "(?:(?:a|an|the|this|your|its|one)\\s+(?:\\w+[\\s-]+){0,2}(?:file|path)\\b" <>
                   "|[`'\"(\\[]{0,2}" <> @path <> ")"

  # Verb taking a file as its direct object — "create a file", "write the
  # file". No filler is allowed here: "write a summary of the config file"
  # is prose, and one word of slack would swallow it.
  @direct "\\s+(?:out\\s+)?(?:a|an|the|this|your)\\s+(?:new\\s+)?file\\b"

  @intent Regex.compile!(
            "(?:" <>
              @anchor <>
              ")" <>
              @verb <>
              "(?:" <> @filler <> @prepositional <> "|" <> @direct <> ")",
            "iu"
          )

  # How much of the offending sentence the refusal quotes back. Long enough
  # for the model to see which phrase tripped the rail and reword it.
  @quote_chars 90

  @doc """
  Assemble the text the rail reads from a `spawn_agent` argument map.

  Joins `prompt`, `objective` and `expected_output` — the fields that carry
  the instruction. Ignores every other key, `boundaries` included.
  """
  @spec brief(map()) :: String.t()
  def brief(args) when is_map(args) do
    @brief_fields
    |> Enum.map(&Map.get(args, &1))
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  @doc """
  Does the brief instruct the worker to produce a file?

  True only for an imperative write verb in an instruction position
  governing a file object or a path-shaped token. Deliberately conservative
  — see the moduledoc.
  """
  @spec asks_for_a_file?(String.t() | nil) :: boolean()
  def asks_for_a_file?(text) when is_binary(text), do: Regex.match?(@intent, text)
  def asks_for_a_file?(_), do: false

  @doc """
  Can any tool in this toolset put bytes in a file?

  `tools` is the resolved list of tool NAMES the worker will run with, as
  `SpawnAgent.resolve_tools/3` computes it.
  """
  @spec write_capable?([String.t()] | nil) :: boolean()
  def write_capable?(tools) when is_list(tools),
    do: Enum.any?(tools, &(&1 in @file_writing_tools))

  # No resolved toolset means the worker inherits the full builtin set.
  def write_capable?(_), do: true

  @doc """
  The refusal for this spawn, or `nil` when it should proceed.

  Refuses only when BOTH hold: the toolset has no file-writing tool (and the
  host has registered no mutating tool the worker could reach instead), and
  the brief plainly orders a file. `agent_name` is `nil` for a plain spawn
  narrowed by the caller's own `tools` argument.
  """
  @spec refusal(String.t() | nil, [String.t()] | nil, String.t() | nil) :: String.t() | nil
  def refusal(brief, tools, agent_name) do
    if write_capable?(tools) or host_mutating_tool?() or not asks_for_a_file?(brief) do
      nil
    else
      message(brief, tools, agent_name)
    end
  end

  defp message(brief, tools, agent_name) do
    "not started: " <>
      subject(agent_name) <>
      " has tools #{Enum.join(tools, ", ")} — none of which can write a file, " <>
      "and your brief asks for one (#{inspect(offending_phrase(brief))}). " <>
      "Delegate this step to \"implementer\" (or another write-capable agent), " <>
      "or drop the file requirement and ask for the content in the reply."
  end

  defp subject(nil), do: "this spawn's toolset"
  defp subject(name), do: "agent #{inspect(name)}"

  defp offending_phrase(brief) do
    case Regex.run(@intent, brief) do
      [match | _] -> match |> String.trim() |> String.slice(0, @quote_chars)
      _ -> String.slice(brief, 0, @quote_chars)
    end
  end

  # A host can register tools of its own (MCP servers, custom modules), and
  # `Tools.resolve/1` appends MCP specs to whatever toolset the worker was
  # given — so a worker with no write builtin may still have a mutating tool
  # in reach. Rather than guess which, stand down entirely when one exists.
  # Returns false when no MCP supervisor is running, which is the common case
  # and the one the tests exercise.
  defp host_mutating_tool? do
    case Process.whereis(ExAthena.Mcp.Supervisor) do
      nil -> false
      _ -> Enum.any?(ExAthena.Mcp.tool_specs(:all), fn %Spec{} = s -> not s.read_only? end)
    end
  end
end
