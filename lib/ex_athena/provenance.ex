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
    * `{:failed_command, cmd}` — one that ran and exited non-zero. Bash
      returns `{:ok, …}` whatever the exit code, so without this a worker
      could watch the suite go red and still satisfy a rail asking whether
      the change was exercised.

  Order is preserved because it carries information a set cannot: "wrote a
  test, ran it, then edited source" and "edited source, then added a test"
  have the same files and commands but very different meanings — see
  `test_first?/1`.
  """

  alias ExAthena.Messages.{Message, ToolCall, ToolResult}

  # Builtin tools that mutate the workspace. `bash` is classified separately —
  # it runs commands, which is the evidence side rather than the change side.
  @write_tools ~w(write edit)
  @patch_tools ~w(apply_patch)
  @command_tools ~w(bash)

  # Footers ride in the orchestrator's context on every spawn, so they are
  # capped: a worker touching 40 files must not cost 40 lines of prompt.
  @max_listed 15
  @max_command_chars 120

  @type event ::
          {:write, String.t()}
          | {:command, String.t()}
          | {:failed_command, String.t()}

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

  @doc "Distinct files the run mutated, in first-seen order."
  @spec changed_files([event()]) :: [String.t()]
  def changed_files(events), do: for({:write, p} <- events, do: p) |> Enum.uniq()

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
  A one-line factual summary to append to a worker's report, or `nil` when the
  worker neither changed nor ran anything (a pure read-only explorer).

  The literal `none` matters: it is what makes an unverified change visible
  instead of something a summary can paper over.
  """
  @spec footer([event()]) :: String.t() | nil
  def footer([]), do: nil

  def footer(events) do
    failed = MapSet.new(failed_commands(events))

    rendered_commands =
      Enum.map(commands(events), fn cmd ->
        if MapSet.member?(failed, cmd),
          do: truncate(cmd) <> " (failed)",
          else: truncate(cmd)
      end)

    facts =
      "[worker provenance] files changed: #{render(changed_files(events))}" <>
        " | commands run: #{render(rendered_commands)}"

    # Advisory, on its own line so it never disturbs `scan/1` of the facts.
    if test_first?(events),
      do: facts,
      else: facts <> "\n[worker provenance] source was edited before any test was written."
  end

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
    |> Enum.map(&(&1 |> String.replace(~r/\s*\(\+\d+ more\)$/, "") |> String.trim()))
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
        if failed_exit?(result), do: [{:failed_command, cmd}], else: [{:command, cmd}]

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
  defp failed_exit?(%ToolResult{ui_payload: %{payload: %{exit_code: code}}})
       when is_integer(code),
       do: code != 0

  defp failed_exit?(_), do: false

  defp command_event(rendered) do
    case String.replace_suffix(rendered, " (failed)", "") do
      ^rendered -> {:command, rendered}
      stripped -> {:failed_command, stripped}
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

  defp render([]), do: "none"

  defp render(items) do
    case Enum.split(items, @max_listed) do
      {shown, []} -> Enum.join(shown, ", ")
      {shown, rest} -> Enum.join(shown, ", ") <> " (+#{length(rest)} more)"
    end
  end

  defp truncate(text) when byte_size(text) > @max_command_chars do
    String.slice(text, 0, @max_command_chars) <> "…"
  end

  defp truncate(text), do: text
end
