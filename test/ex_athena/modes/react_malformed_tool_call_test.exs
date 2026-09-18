defmodule ExAthena.Modes.ReActMalformedToolCallTest do
  @moduledoc """
  Issue 246: web session `66f4204cd532`, events 37-40. A text-protocol parser
  scoped a fence badly and the parsed tool-call *name* came out as the
  two-line string:

      skill: architecture-brief-and-mocks
      </parameter

  Nothing between the parser and `unknown_tool_error/2` checked that the name
  was a plausible tool name, so the whole fragment (newline included) became
  the name, `toolset_hint/2` had nothing useful to suggest, and the loop
  charged it as a mistake — twice in a row, one short of
  `error_consecutive_mistakes` on that run's cap of 3.

  This file covers the three cases the fix must tell apart:

    * a malformed name (unparseable syntax, not a tool choice) — reported as
      malformed, shown the correct shape, and NOT charged as a mistake;
    * a well-formed but unknown name — unchanged: today's message, with the
      near-match suggestion;
    * a well-formed name that IS a real builtin, just outside this phase's
      toolset — unchanged: the delegate-via-spawn_agent redirect.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    dir =
      Path.join(System.tmp_dir!(), "react_malformed_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # The exact live payload: a parser mis-scoped a fence and swallowed a
  # trailing `</parameter` plus a newline into the tool name.
  @malformed_name "skill: architecture-brief-and-mocks\n</parameter"

  defp tool_error_contents(result) do
    result.messages
    |> Enum.filter(&match?(%{role: :tool}, &1))
    |> Enum.flat_map(& &1.tool_results)
    |> Enum.map(& &1.content)
  end

  test "a malformed tool name from the text-tagged protocol is reported as malformed, not unknown, and shows the fence shape",
       %{dir: dir} do
    # The live failure came through a non-native (TextTagged/RawJson) run —
    # the reply must name THAT protocol, the `~~~tool_call` fence, not a
    # native function-calling shape the provider never spoke.
    response = %Response{
      text: "",
      tool_calls: [%ToolCall{id: "c1", name: @malformed_name, arguments: %{}}],
      finish_reason: :tool_calls,
      provider: :mock
    }

    assert {:ok, result} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: fn _ -> response end],
               cwd: dir,
               tools: [ExAthena.Tools.Read],
               capabilities: %{native_tool_calls: false},
               max_consecutive_mistakes: 2,
               max_iterations: 3
             )

    [content | _] = tool_error_contents(result)

    refute content =~ "unknown tool"
    assert content =~ "malformed"
    # Shows a correct example, in the protocol this run speaks, so the
    # repair takes one turn.
    assert content =~ "~~~tool_call"
    assert content =~ ~s({"name")
  end

  test "a malformed tool name from a native-tool-call provider names that shape instead", %{
    dir: dir
  } do
    response = %Response{
      text: "",
      tool_calls: [%ToolCall{id: "c1", name: @malformed_name, arguments: %{}}],
      finish_reason: :tool_calls,
      provider: :mock
    }

    assert {:ok, result} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: fn _ -> response end],
               cwd: dir,
               tools: [ExAthena.Tools.Read],
               capabilities: %{native_tool_calls: true},
               max_consecutive_mistakes: 2,
               max_iterations: 3
             )

    [content | _] = tool_error_contents(result)

    refute content =~ "unknown tool"
    assert content =~ "malformed"
    refute content =~ "~~~tool_call"
    assert content =~ "exact name only"
  end

  test "a repeated malformed tool name never trips the mistake counter", %{dir: dir} do
    # Same malformed shape every turn — the live failure was two IN A ROW
    # against a cap of 3. It must survive well past that cap because a
    # malformed call is uncounted, not merely cheap.
    response = %Response{
      text: "",
      tool_calls: [%ToolCall{id: "c1", name: @malformed_name, arguments: %{}}],
      finish_reason: :tool_calls,
      provider: :mock
    }

    assert {:ok, result} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: fn _ -> response end],
               cwd: dir,
               tools: [ExAthena.Tools.Read],
               max_consecutive_mistakes: 2,
               max_iterations: 6,
               # Disable the no-progress guard: this test is about the
               # mistake counter specifically, not the (separately-owned)
               # repeated-identical-call guard.
               max_unproductive_iterations: 0
             )

    refute result.finish_reason == :error_consecutive_mistakes
    assert result.finish_reason == :error_max_turns
  end

  test "a well-formed unknown tool name still gets today's message and near-match suggestion",
       %{dir: dir} do
    responses = [
      %Response{
        text: "",
        tool_calls: [%ToolCall{id: "c1", name: "read_file", arguments: %{"path" => "f.txt"}}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    counter = :counters.new(1, [:atomics])

    responder = fn _req ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      Enum.at(responses, n - 1) || List.last(responses)
    end

    assert {:ok, result} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [ExAthena.Tools.Read]
             )

    [content | _] = tool_error_contents(result)

    assert content =~ "unknown tool: read_file"
    assert content =~ "Available tools:"
    assert content =~ ~s(Did you mean "read"?)
    refute content =~ "malformed"
  end

  test "a real builtin outside this phase's toolset still gets the delegate-instead redirect",
       %{dir: dir} do
    # "read" is a genuine ExAthena.Tools builtin, well-formed, just not part
    # of this loop's toolset — with spawn_agent present, the loop must
    # redirect to delegation rather than call it unknown or malformed.
    responses = [
      %Response{
        text: "",
        tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "f.txt"}}],
        finish_reason: :tool_calls,
        provider: :mock
      },
      %Response{text: "ok", tool_calls: [], finish_reason: :stop, provider: :mock}
    ]

    counter = :counters.new(1, [:atomics])

    responder = fn _req ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      Enum.at(responses, n - 1) || List.last(responses)
    end

    assert {:ok, result} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: responder],
               cwd: dir,
               tools: [ExAthena.Tools.SpawnAgent]
             )

    [content | _] = tool_error_contents(result)

    assert content =~ "not available to you"
    assert content =~ "delegate this step to a worker"
    assert content =~ "spawn_agent"
    refute content =~ "malformed"
    refute content =~ "unknown tool"
  end
end
