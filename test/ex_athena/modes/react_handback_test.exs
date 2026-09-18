defmodule ExAthena.Modes.ReActHandbackTest do
  @moduledoc """
  Issue 237. A worker used to be brutal-killed the moment its wall-clock budget
  ran out, so its `Result` — and every finding in it — died with the process.
  In session 4ee9e00f1ebf that cost about an hour of a three-hour run:
  `subagent_n2amLrIE` wrote all four of its files at minute 25 and was killed at
  minute 29 without a word of report.

  So the end of the budget is now reserved. Past `loop.handback_at_percent` the
  loop sends ONE more turn with no tools at all and asks for the report, and
  that turn's text is the run's own account of itself.

  The clock is injected through the deadline assigns rather than waited on: the
  budget is expressed as a window around the current monotonic reading, so a
  test can sit at 90% of it without sleeping.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall

  setup do
    dir = Path.join(System.tmp_dir!(), "handback_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "f.txt"), "contents")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # A worker `spent`/1000 of the way through its budget, right now. The
  # counter is the worker's own wait counter, empty: nothing was queued.
  defp deadline_assigns(spent) when spent >= 0 and spent <= 1000 do
    now = System.monotonic_time(:millisecond)

    %{
      agent_deadline_from: now - spent,
      agent_deadline_at: now + (1000 - spent),
      agent_wait_counters: [ExAthena.Agents.Deadline.new_counter()]
    }
  end

  # Always calls a tool, so nothing but the handback stage can end the run
  # with text. Each request is forwarded to the test.
  defp busy_responder(test_pid) do
    counter = :counters.new(1, [:atomics])

    fn request ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(test_pid, {:req, n, request})

      %Response{
        text: "reading f.txt to check the header",
        tool_calls: [
          %ToolCall{id: "c#{n}", name: "read", arguments: %{"path" => "f.txt", "offset" => n}}
        ],
        finish_reason: :tool_calls,
        provider: :mock
      }
    end
  end

  defp run(dir, responder, assigns, opts \\ []) do
    Loop.run(
      "build the console screen",
      [
        provider: :mock,
        mock: [responder: responder],
        cwd: dir,
        assigns: assigns,
        max_iterations: 8,
        max_unproductive_iterations: 10_000,
        tools: [ExAthena.Tools.Read]
      ] ++ opts
    )
  end

  defp tail_text(%{messages: messages}) do
    messages
    |> Enum.filter(&(is_binary(&1.content) and &1.content != ""))
    |> Enum.map_join("\n", & &1.content)
  end

  describe "the handback turn" do
    test "past the threshold the run ends on :budget_handback with the model's own words",
         %{dir: dir} do
      test_pid = self()

      responder = fn request ->
        send(test_pid, {:req, request})

        if request.tools in [nil, []] do
          %Response{
            text: "PRODUCED: lib/console.ex. UNVERIFIED: never compiled. REMAINS: the tests.",
            tool_calls: [],
            finish_reason: :stop,
            provider: :mock
          }
        else
          %Response{
            text: "still mapping the conventions",
            tool_calls: [%ToolCall{id: "c1", name: "read", arguments: %{"path" => "f.txt"}}],
            finish_reason: :tool_calls,
            provider: :mock
          }
        end
      end

      assert {:ok, result} = run(dir, responder, deadline_assigns(900))

      assert result.finish_reason == :budget_handback
      assert result.text =~ "PRODUCED: lib/console.ex"
      assert result.text =~ "REMAINS: the tests"
    end

    test "that turn is sent with no tool schemas", %{dir: dir} do
      assert {:ok, _} = run(dir, busy_responder(self()), deadline_assigns(900))

      assert_receive {:req, 1, request}, 1_000
      assert request.tools in [nil, []]
    end

    # A provider without native tool calls is told how to call tools in the
    # SYSTEM PROMPT, so dropping the schemas alone would leave the protocol —
    # and a worker with a protocol and no tools emits fences nothing runs.
    test "a text-protocol provider is not told the protocol either", %{dir: dir} do
      caps = [capabilities: %{native_tool_calls: false}]

      assert {:ok, _} = run(dir, busy_responder(self()), deadline_assigns(400), caps)
      assert_receive {:req, 1, working}, 1_000
      assert to_string(working.system_prompt) =~ "~~~tool_call"

      assert {:ok, _} = run(dir, busy_responder(self()), deadline_assigns(900), caps)
      assert_receive {:req, 1, handback}, 1_000
      refute to_string(handback.system_prompt) =~ "~~~tool_call"
    end

    test "the tail asks for produced, unverified and remaining", %{dir: dir} do
      assert {:ok, _} = run(dir, busy_responder(self()), deadline_assigns(900))

      assert_receive {:req, 1, request}, 1_000
      tail = tail_text(request)

      assert tail =~ ~r/final turn/i
      assert tail =~ "PRODUCED"
      assert tail =~ "UNVERIFIED"
      assert tail =~ "REMAINS"
    end

    # The research note tells the model to call web_search, which it no longer
    # has, and the wrap-up note offers it a choice between two states when
    # there is no next turn to choose in.
    test "the wrap-up nudge and the research note are dropped from that tail", %{dir: dir} do
      assert {:ok, _} = run(dir, busy_responder(self()), deadline_assigns(900))

      assert_receive {:req, 1, request}, 1_000
      tail = tail_text(request)

      refute tail =~ "reduce scope"
      refute tail =~ "web_search"
    end

    # A small model writes a vague report from memory. Its own ledger in front
    # of it is what makes the report name files and commands.
    #
    # Two working turns first, and the clock is crossed by RELEASING the queue
    # pause rather than by waiting: the budget is already 90% spent, but it is
    # paused while the subtree is queued, so the stage cannot fire until the
    # last wait closes.
    test "the worker's conclusions ledger rides along", %{dir: dir} do
      assigns = deadline_assigns(900)
      ExAthena.Agents.Deadline.begin_wait(assigns)
      ExAthena.Agents.Deadline.begin_wait(assigns)

      counter = :counters.new(1, [:atomics])
      test_pid = self()

      responder = fn request ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        send(test_pid, {:req, n, request})
        ExAthena.Agents.Deadline.end_wait(assigns, 0)

        if request.tools in [nil, []] do
          %Response{text: "report", tool_calls: [], finish_reason: :stop, provider: :mock}
        else
          %Response{
            text: "Found the console conventions in lib/web/console.ex (turn #{n})",
            tool_calls: [
              %ToolCall{id: "c#{n}", name: "read", arguments: %{"path" => "f.txt", "offset" => n}}
            ],
            finish_reason: :tool_calls,
            provider: :mock
          }
        end
      end

      assert {:ok, result} = run(dir, responder, assigns)

      assert result.finish_reason == :budget_handback
      assert_receive {:req, 3, request}, 1_000
      assert request.tools in [nil, []]

      tail = tail_text(request)
      assert tail =~ "progress ledger"
      assert tail =~ "console conventions"
    end

    # The model is told there are no tools, but a small model told anything may
    # do otherwise. There is no next turn to run them in either way.
    test "tool calls on the handback turn are ignored and the text still wins", %{dir: dir} do
      responder = fn _request ->
        %Response{
          text: "PRODUCED: nothing yet.",
          tool_calls: [%ToolCall{id: "x", name: "read", arguments: %{"path" => "f.txt"}}],
          finish_reason: :tool_calls,
          provider: :mock
        }
      end

      assert {:ok, result} = run(dir, responder, deadline_assigns(900))

      assert result.finish_reason == :budget_handback
      assert result.text == "PRODUCED: nothing yet."
      assert result.tool_calls_made == 0
    end
  end

  describe "when the stage must not fire" do
    test "a worker with room left keeps its tools", %{dir: dir} do
      assert {:ok, result} = run(dir, busy_responder(self()), deadline_assigns(400))

      assert_receive {:req, 1, request}, 1_000
      assert request.tools != nil and request.tools != []
      assert result.finish_reason == :error_max_turns
    end

    # The orchestrator's own budget is out of scope. A top-level run carries no
    # deadline assigns at all, so the stage cannot reach it.
    test "a run with no deadline never hands back", %{dir: dir} do
      assert {:ok, result} = run(dir, busy_responder(self()), %{})

      assert_receive {:req, 1, request}, 1_000
      assert request.tools != nil and request.tools != []
      assert result.finish_reason == :error_max_turns
    end

    # The budget pauses while the subtree waits for a provider slot, so a
    # worker that has done nothing but queue is not forced to report.
    test "a worker parked in the provider queue is not forced to report", %{dir: dir} do
      assigns = deadline_assigns(900)
      ExAthena.Agents.Deadline.begin_wait(assigns)

      assert {:ok, result} = run(dir, busy_responder(self()), assigns)

      assert_receive {:req, 1, request}, 1_000
      assert request.tools != nil and request.tools != []
      assert result.finish_reason == :error_max_turns
    end
  end
end
