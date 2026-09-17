defmodule ExAthena.Provenance do
  @moduledoc """
  Derive what a run **actually did** from its own tool calls.

  A worker's report is free text, so an orchestrator reading it cannot
  distinguish "the worker ran `mix compile`" from "the worker said it
  compiled". Live runs produced exactly that failure: a deliverable claiming
  "the app compiles cleanly with no new errors" for a run in which no build
  command was ever executed.

  These events are read off the message history rather than the prose, so the
  claim becomes checkable — both by the model (the footer rides back with the
  worker's report) and by deterministic rails (`changed_files/1`,
  `commands/1`).

  Three event kinds are recorded, in call order:

    * `{:write, path}` — a file the run mutated.
    * `{:command, cmd}` — a shell command that ran and exited zero.
    * `{:failed_command, cmd}` — one that ran and exited non-zero, or a test
      run whose output shows a failure summary. Bash returns `{:ok, …}`
      whatever the exit code, so without this a worker could watch the suite
      go red and still satisfy a rail asking whether the change was
      exercised.
    * `{:unconfirmed_command, cmd}` — a piped test run whose output shows no
      summary line, so nothing shows whether it passed. See
      `command_outcome/3`.
    * `{:bash_write, path}` — a path a shell command *appears* to have
      written. A candidate, never evidence: `changed_files/1` ignores it and
      `footer/1` never renders it until `verify/2` has found it on disk.

  ## Why bash writes are candidates and not facts

  Worker `T2cuzVsh` wrote a 113 KB file with a bash heredoc and its footer
  read `files changed: none`, because `bash` was only ever classified as a
  command. Closing that gap means guessing what a shell command touched, and
  the guess cannot be allowed to be wrong: the whole value of this module is
  that an orchestrator can check its claims, so a fabricated path is worse
  than a missing one.

  So the matcher recognises only unambiguous forms — `> path`, `>> path`,
  `tee path` — refuses any target carrying a shell metacharacter it would
  have to expand (`$`, `~`, `*`, a quote), and emits a distinct event kind
  that only becomes a `{:write, _}` once `verify/2` has stat'd it. Misses are
  expected and acceptable: `sed -i`, a Python heredoc opening its own file,
  and redirection into a variable are all invisible here by design.

  Order is preserved because it carries information a set cannot: "wrote a
  test, ran it, then edited source" and "edited source, then added a test"
  have the same files and commands but very different meanings — see
  `test_first?/1`.
  """

  alias ExAthena.Messages.{Message, ToolCall, ToolResult}
  alias ExAthena.Tuning

  # Builtin tools that mutate the workspace. `bash` is classified separately —
  # it runs commands, which is the evidence side rather than the change side.
  @write_tools ~w(write edit)
  @patch_tools ~w(apply_patch)
  @command_tools ~w(bash)

  # Footers ride in the orchestrator's context on every spawn, so they are
  # capped: a worker touching 40 files must not cost 40 lines of prompt.
  @max_listed 15
  @max_command_chars 120

  # `>` / `>>` that is not part of `2>`, `&>` or `>&`. The target runs to the
  # next shell separator; `@safe_target` then decides whether it is a path we
  # are willing to claim.
  @redirect_re ~r/(?<![0-9&>])>>?\s*([^\s;|&<>()]+)/
  @tee_re ~r/\btee\s+(?:-a\s+)?([^\s;|&<>()]+)/

  # Everything a POSIX shell would leave alone. Anything else — `$VAR`, `~`,
  # a glob, a quote — means the literal text is not the path that was written,
  # so the candidate is dropped rather than guessed at.
  @safe_target ~r|^[A-Za-z0-9._/+-]+$|

  # `scan/1` has to read a footer this module wrote, so the annotations
  # `annotate/2` adds are stripped back off. Deliberately an exact list rather
  # than "any trailing parenthesis": commands carry a ` (failed)` suffix
  # through the same splitter, and eating that would silently turn a red test
  # suite into a green one.
  @annotation_re ~r/\s*\((?:\d+ B(?:, not re-checked)?|missing|written, not re-checked)\)$/

  # A test run's summary line, per runner `test_command?/1` recognises. The
  # failure forms are checked first: output carrying both is a red run.
  @failure_summaries [
    # ExUnit, RSpec
    ~r/\b\d+ (?:tests?|examples?), [1-9]\d* failures?\b/,
    # Elixir compile errors, Rust compile errors
    ~r/^== Compilation error|\*\* \(CompileError\)|error: could not compile/m,
    # pytest
    ~r/^=+ .*\b[1-9]\d* (?:failed|errors?)\b/m,
    # Jest, Vitest
    ~r/^\s*Tests:?\s+[1-9]\d* failed/m,
    # go test
    ~r/^(?:--- )?FAIL\b/m,
    # cargo test
    ~r/test result: FAILED/,
    # PHPUnit
    ~r/^(?:FAILURES|ERRORS)!/m,
    # dotnet test
    ~r/^\s*Failed!/m,
    # Gradle, Maven
    ~r/BUILD FAIL(?:ED|URE)/
  ]

  @pass_summaries [
    ~r/\b\d+ (?:tests?|examples?), 0 failures\b/,
    ~r/^=+ .*\b\d+ passed|no tests ran/m,
    ~r/^\s*Tests:?\s+.*\b\d+ passed/m,
    ~r/^(?:ok\s|PASS$)/m,
    ~r/test result: ok/,
    ~r/^OK \(/m,
    ~r/^\s*Passed!/m,
    ~r/BUILD SUCCESS/
  ]

  # A single `|`, never the `||` of a fallback.
  @pipe_re ~r/(?<!\|)\|(?!\|)/

  @unconfirmed_suffix " (no test summary seen)"

  @type event ::
          {:write, String.t()}
          | {:command, String.t()}
          | {:failed_command, String.t()}
          | {:unconfirmed_command, String.t()}
          | {:bash_write, String.t()}

  @doc """
  Ordered events derived from a run's messages.

  Options:

    * `:mutating_tools` — extra tool names (custom/MCP) to treat as writes.
      Their path is read from a `path`/`file_path` argument when present.
  """
  @spec events([Message.t()], keyword()) :: [event()]
  def events(messages, opts \\ []) when is_list(messages) do
    extra = opts |> Keyword.get(:mutating_tools, []) |> List.wrap()
    results = results_by_id(messages)

    messages
    |> Enum.flat_map(fn
      %Message{role: :assistant, tool_calls: calls} when is_list(calls) -> calls
      _ -> []
    end)
    |> Enum.reject(&match?(%ToolResult{is_error: true}, results[&1.id]))
    |> Enum.flat_map(&classify(&1, extra, results[&1.id]))
  end

  @doc """
  Distinct files the run mutated, in first-seen order.

  Unverified `{:bash_write, _}` candidates are deliberately absent — a rail
  asking "what did this change?" must not be answered with a guess. Run the
  events through `verify/2` first to include the ones that are really there.
  """
  @spec changed_files([event()]) :: [String.t()]
  def changed_files(events), do: for({:write, p} <- events, do: p) |> Enum.uniq()

  @doc """
  Promote every `{:bash_write, _}` candidate that is on disk, and drop the rest.

  Resolution is against `cwd`, so this has to run while the worker's directory
  still exists. A `nil` cwd drops every candidate: with nothing to check
  against, a claim cannot be made checkable, and an unverifiable claim is
  exactly what this module refuses to emit.

  Everything that is already evidence — tool writes, commands — passes through
  untouched.
  """
  @spec verify([event()], String.t() | nil) :: [event()]
  def verify(events, cwd) do
    Enum.flat_map(events, fn
      {:bash_write, path} -> if on_disk?(path, cwd), do: [{:write, path}], else: []
      other -> [other]
    end)
  end

  @doc """
  Distinct commands the run executed, in first-seen order — including ones
  that exited non-zero, which still ran.
  """
  @spec commands([event()]) :: [String.t()]
  def commands(events) do
    events
    |> Enum.flat_map(fn
      {:command, c} -> [c]
      {:failed_command, c} -> [c]
      {:unconfirmed_command, c} -> [c]
      _ -> []
    end)
    |> Enum.uniq()
  end

  @doc """
  Distinct commands that exited non-zero.

  A rail asking "was this change exercised?" must not be satisfied by a suite
  that ran and went red.
  """
  @spec failed_commands([event()]) :: [String.t()]
  def failed_commands(events), do: for({:failed_command, c} <- events, do: c) |> Enum.uniq()

  @doc """
  Distinct piped test runs whose output showed no summary line.

  They ran, and they did not visibly fail, but they are not passing runs
  either: the exit code belongs to the last command in the pipe.
  """
  @spec unconfirmed_commands([event()]) :: [String.t()]
  def unconfirmed_commands(events),
    do: for({:unconfirmed_command, c} <- events, do: c) |> Enum.uniq()

  @doc """
  Judge one shell command from its exit code and its output.

  Returns `:passed`, `:failed` or `:unconfirmed`. A non-zero exit is always
  `:failed`. A command that is not a test run (`test_command?/1`) goes by its
  exit code alone. A test run also fails when its output carries a failure
  summary, because `mix test | tail -60` exits with `tail`'s status: session
  227f7f480afa recorded exactly that as a passing run over 4 failing tests. A
  piped test run whose output shows no summary line at all is `:unconfirmed`,
  since `| head -80` can cut the summary off. An unpiped one keeps its exit
  code, because then the code is the runner's own.
  """
  @spec command_outcome(String.t(), integer() | nil, String.t() | nil) ::
          :passed | :failed | :unconfirmed
  def command_outcome(_cmd, code, _output) when is_integer(code) and code != 0, do: :failed

  def command_outcome(cmd, _code, output) do
    output = if is_binary(output), do: output, else: ""

    cond do
      not test_command?(cmd) -> :passed
      Enum.any?(@failure_summaries, &Regex.match?(&1, output)) -> :failed
      Enum.any?(@pass_summaries, &Regex.match?(&1, output)) -> :passed
      Regex.match?(@pipe_re, cmd) -> :unconfirmed
      true -> :passed
    end
  end

  @doc """
  A one-line factual summary to append to a worker's report, or `nil` when the
  worker neither changed nor ran anything (a pure read-only explorer).

  The literal `none` matters: it is what makes an unverified change visible
  instead of something a summary can paper over.

  ## Options

    * `:cwd` — the directory the worker actually ran in. Given one, bash write
      candidates are verified against it (`verify/2`) and every changed file is
      `stat`ed so the footer carries a byte count. "Wrote an 85 KB file" is
      checkable; "the file is structurally complete" is a claim, and the size
      is what separates them.
    * `:sizes` — a `path => bytes` map measured earlier, used only where the
      `stat` fails. `ExAthena.Agents.Journal` supplies it for a worker whose
      directory has since been removed; the annotation then says the number was
      not re-checked, so a measurement taken elsewhere is never passed off as
      one taken here.

  A path that cannot be sized is never dropped, because an absent path reads as
  "the worker wrote nothing" — the exact failure this module exists to prevent.
  It is annotated instead, and the two reasons are distinguished because they
  mean different things: `(missing)` is a file that is not there in a directory
  that is, and `(written, not re-checked)` is a directory that has itself been
  removed. The second is the normal case for a `:worktree` worker, whose
  directory `SpawnAgent.finalize_isolation/1` deletes before the parent reaches
  this code.
  """
  @spec footer([event()], keyword()) :: String.t() | nil
  def footer(events, opts \\ [])

  def footer([], _opts), do: nil

  def footer(events, opts) do
    cwd = Keyword.get(opts, :cwd)
    events = verify(events, cwd)

    do_footer(events, cwd, Keyword.get(opts, :sizes, %{}))
  end

  defp do_footer([], _cwd, _sizes), do: nil

  defp do_footer(events, cwd, sizes) do
    failed = MapSet.new(failed_commands(events))
    unconfirmed = MapSet.new(unconfirmed_commands(events))

    rendered_commands =
      Enum.map(commands(events), fn cmd ->
        cond do
          MapSet.member?(failed, cmd) -> truncate(cmd) <> " (failed)"
          MapSet.member?(unconfirmed, cmd) -> truncate(cmd) <> @unconfirmed_suffix
          true -> truncate(cmd)
        end
      end)

    rendered_files = Enum.map(changed_files(events), &annotate(&1, cwd, sizes))

    facts =
      "[worker provenance] files changed: #{render(rendered_files)}" <>
        " | commands run: #{render(rendered_commands)}"

    # Advisory, on its own line so it never disturbs `scan/1` of the facts.
    if test_first?(events),
      do: facts,
      else: facts <> "\n[worker provenance] source was edited before any test was written."
  end

  @doc """
  Paths a shell command unambiguously names as write targets.

  Only the forms a reader can resolve without running a shell: `> path`,
  `>> path`, `tee path`. Targets carrying anything the shell would expand — a
  variable, a tilde, a glob, a quote — are refused rather than guessed at, and
  so are `/dev/*` sinks. Callers must still confirm the path exists before
  treating it as evidence (`verify/2` does this for events; the worker journal
  does it at write time, while the file is certain to be there).

  Returns `[]` for anything that is not a binary.
  """
  @spec write_targets(String.t()) :: [String.t()]
  def write_targets(cmd) when is_binary(cmd) do
    (Regex.scan(@redirect_re, cmd, capture: :all_but_first) ++
       Regex.scan(@tee_re, cmd, capture: :all_but_first))
    |> List.flatten()
    |> Enum.filter(&safe_target?/1)
    |> Enum.uniq()
  end

  def write_targets(_), do: []

  @doc """
  Whether a test file was written before the first source file.

  This is the one question a set of events cannot answer, and the reason
  `events/1` preserves order: "wrote a test, ran it red, then implemented" and
  "implemented, then bolted a test on" touch the same files and run the same
  commands. Vacuously true when no source was written.
  """
  @spec test_first?([event()]) :: boolean()
  def test_first?(events) do
    events
    |> Enum.flat_map(fn
      {:write, path} -> [if(test_file?(path), do: :test, else: :source)]
      _ -> []
    end)
    |> Enum.find(&(&1 in [:test, :source]))
    |> case do
      :source -> false
      _ -> true
    end
  end

  @doc """
  Whether a path looks like a test rather than production code.

  Either it lives under a test directory, or its basename carries a test
  affix. Deliberately ecosystem-spanning: the rails that use this run against
  whatever project the agent was pointed at, not just Elixir.
  """
  @spec test_file?(String.t()) :: boolean()
  def test_file?(path) when is_binary(path) do
    segments = path |> Path.split() |> Enum.map(&String.downcase/1)
    basename = List.last(segments) || ""

    # foo_test.exs, foo_test.go, foo_spec.rb, Button.test.tsx, Button.spec.ts
    # `test_*` is a pytest discovery convention, so it only means "test" for
    # Python — `test_helper_builder.ex` is ordinary production code.
    Enum.any?(Enum.drop(segments, -1), &(&1 in ~w(test tests spec specs __tests__))) or
      basename =~ ~r/[._-](test|spec)\.[a-z]+$/ or
      (String.ends_with?(basename, ".py") and basename =~ ~r/^test_/)
  end

  def test_file?(_), do: false

  @doc """
  Whether a command runs a test suite.

  A build is not a test: the failure this exists for compiled cleanly and
  raised on every page load, so "it compiles" must not satisfy a rail asking
  whether anything actually exercised the change.
  """
  @spec test_command?(String.t()) :: boolean()
  def test_command?(cmd) when is_binary(cmd) do
    cmd =~
      ~r/(^|[;&|]\s*|\s)(mix\s+test|(npm|yarn|pnpm)\s+(run\s+)?test|pytest|py\.test|go\s+test|cargo\s+test|rspec|jest|vitest|phpunit|dotnet\s+test|(gradle|mvn)\s+test)\b/
  end

  def test_command?(_), do: false

  @doc """
  Recover events from footers embedded in a transcript.

  A tool cannot write into loop state, so the footer is the only channel by
  which an orchestrator's rails learn what its workers did — the text is a
  parsing contract, not merely display. Prose around the footers is ignored,
  and an elided `(+N more)` remainder simply does not come back.
  """
  @spec scan(String.t()) :: [event()]
  def scan(text) when is_binary(text) do
    ~r/^\[worker provenance\] files changed: (.*) \| commands run: (.*)$/m
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.flat_map(fn [files, commands] ->
      Enum.map(split_list(files), &{:write, &1}) ++
        Enum.map(split_list(commands), &command_event/1)
    end)
  end

  def scan(_), do: []

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp split_list("none"), do: []

  # The cap suffix rides on the last rendered item ("lib/f15.ex (+25 more)"),
  # so it is stripped per item rather than dropped as an element.
  defp split_list(rendered) do
    rendered
    |> String.split(", ")
    |> Enum.map(fn item ->
      item
      |> String.replace(~r/\s*\(\+\d+ more\)$/, "")
      |> String.replace(@annotation_re, "")
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp results_by_id(messages) do
    for %Message{tool_results: results} <- messages,
        is_list(results),
        %ToolResult{tool_call_id: id} = result <- results,
        into: %{},
        do: {id, result}
  end

  defp classify(%ToolCall{name: name, arguments: args}, _extra, result)
       when name in @command_tools do
    case arg(args, "command") do
      cmd when is_binary(cmd) ->
        cmd = String.trim(cmd)

        # A command that exited non-zero proves nothing about what it wrote —
        # a failed heredoc leaves a truncated file or none at all — so only a
        # clean exit contributes candidates.
        case command_outcome(cmd, exit_code(result), output(result)) do
          :failed -> [{:failed_command, cmd}]
          :unconfirmed -> [{:unconfirmed_command, cmd} | write_candidates(cmd)]
          :passed -> [{:command, cmd} | write_candidates(cmd)]
        end

      _ ->
        []
    end
  end

  defp classify(%ToolCall{name: name, arguments: args}, _extra, _result)
       when name in @patch_tools do
    patch_paths(args)
  end

  defp classify(%ToolCall{name: name, arguments: args}, _extra, _result)
       when name in @write_tools do
    path_event(args)
  end

  defp classify(%ToolCall{name: name, arguments: args}, extra, _result) do
    if name in extra, do: path_event(args, name), else: []
  end

  # Bash reports a non-zero exit through the structured UI payload, not by
  # returning an error — so a red suite reaches here as an ordinary result.
  defp exit_code(%ToolResult{ui_payload: %{payload: %{exit_code: code}}})
       when is_integer(code),
       do: code

  defp exit_code(_), do: nil

  defp output(%ToolResult{content: content}) when is_binary(content), do: content
  defp output(_), do: nil

  defp command_event(rendered) do
    cond do
      String.ends_with?(rendered, " (failed)") ->
        {:failed_command, String.replace_suffix(rendered, " (failed)", "")}

      String.ends_with?(rendered, @unconfirmed_suffix) ->
        {:unconfirmed_command, String.replace_suffix(rendered, @unconfirmed_suffix, "")}

      true ->
        {:command, rendered}
    end
  end

  defp path_event(args, fallback \\ "(unknown)") do
    case arg(args, "path") || arg(args, "file_path") do
      p when is_binary(p) -> [{:write, p}]
      _ -> [{:write, fallback}]
    end
  end

  # Unified diff: the post-image header names the file the patch writes.
  defp patch_paths(args) do
    case arg(args, "patch") do
      patch when is_binary(patch) ->
        ~r/^\+\+\+ (?:b\/)?(\S+)/m
        |> Regex.scan(patch, capture: :all_but_first)
        |> List.flatten()
        |> Enum.reject(&(&1 == "/dev/null"))
        |> case do
          [] -> [{:write, "(patch)"}]
          paths -> Enum.map(paths, &{:write, &1})
        end

      _ ->
        []
    end
  end

  # Tool arguments arrive as decoded JSON (string keys), but hand-built calls
  # in tests and hosts may use atoms.
  defp arg(args, key) when is_map(args) do
    case Map.get(args, key) do
      nil -> Map.get(args, String.to_existing_atom(key))
      value -> value
    end
  rescue
    ArgumentError -> nil
  end

  defp arg(_args, _key), do: nil

  defp write_candidates(cmd), do: Enum.map(write_targets(cmd), &{:bash_write, &1})

  # /dev/null and friends are not deliverables, and reporting one as a changed
  # file is the same lie as reporting a path that was never written.
  defp safe_target?(target) do
    Regex.match?(@safe_target, target) and not String.starts_with?(target, "/dev/")
  end

  defp on_disk?(_path, nil), do: false

  defp on_disk?(path, cwd) when is_binary(cwd) do
    File.regular?(Path.expand(path, cwd))
  end

  defp on_disk?(_path, _cwd), do: false

  # A size, or the reason there isn't one. Never nothing: see footer/2.
  defp annotate(path, nil, _sizes), do: path

  defp annotate(path, cwd, sizes) do
    case File.stat(Path.expand(path, cwd)) do
      {:ok, %File.Stat{size: size}} -> "#{path} (#{size} B)"
      _ -> "#{path} (#{unverifiable_reason(cwd, Map.get(sizes, path))})"
    end
  end

  defp unverifiable_reason(_cwd, bytes) when is_integer(bytes), do: "#{bytes} B, not re-checked"

  defp unverifiable_reason(cwd, _bytes),
    do: if(File.dir?(cwd), do: "missing", else: "written, not re-checked")

  defp render([]), do: "none"

  defp render(items) do
    case Enum.split(items, Tuning.get(:agents, :provenance_max_listed, @max_listed)) do
      {shown, []} -> Enum.join(shown, ", ")
      {shown, rest} -> Enum.join(shown, ", ") <> " (+#{length(rest)} more)"
    end
  end

  defp truncate(text) do
    max = Tuning.get(:agents, :provenance_command_chars, @max_command_chars)

    if byte_size(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end
end
