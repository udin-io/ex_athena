defmodule ExAthena.Loop.AssistantTurnTest do
  @moduledoc """
  One `{:assistant_turn, …}` per conversational turn, carrying that turn's
  full text.

  Issue 251 needs a worker's prose on disk while the worker is still alive,
  because compaction destroys it in memory before the run ends. The obvious
  source, `{:content, _}`, cannot carry it: it is either N streamed deltas OR
  one end-of-turn emission, never both (`ReAct.handle_turn/5` suppresses the
  second when `:counters` saw the first). A transcript writer keyed on it
  would do one open/write/close per TOKEN.

  `Loop.Inference.call/3` is the single path every conversational turn takes
  and holds the whole response, so the event is emitted there — once, in full,
  whether or not the provider streamed.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Response}
  alias ExAthena.Messages.ToolCall
  alias ExAthena.Streaming.Event

  setup do
    dir = Path.join(System.tmp_dir!(), "assistant_turn_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # Loop.run/2 is synchronous and every event is emitted before it returns,
  # so the mailbox is complete at drain time. No sleeps, no timeouts needed.
  defp collector do
    test_pid = self()
    ref = make_ref()
    {ref, fn event -> send(test_pid, {ref, event}) end}
  end

  defp drain(ref, acc \\ []) do
    receive do
      {^ref, event} -> drain(ref, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assistant_turns(ref) do
    for {:assistant_turn, payload} <- drain(ref), do: payload
  end

  defp two_turn_responder(first_text, final_text) do
    fn request ->
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        %Response{text: final_text, finish_reason: :stop, provider: :mock}
      else
        %Response{
          text: first_text,
          tool_calls: [
            %ToolCall{
              id: "t1",
              name: "write",
              arguments: %{"path" => "note.md", "content" => "x"}
            }
          ],
          finish_reason: :tool_calls,
          provider: :mock
        }
      end
    end
  end

  test "every turn emits exactly one event carrying that turn's full text", %{dir: dir} do
    {ref, on_event} = collector()
    long = String.duplicate("the map. ", 500)

    assert {:ok, _} =
             Loop.run("map the codebase",
               provider: :mock,
               mock: [responder: two_turn_responder(long, "see above")],
               cwd: dir,
               tools: ["write"],
               memory: false,
               on_event: on_event,
               max_iterations: 5
             )

    assert [first, second] = assistant_turns(ref)

    # The whole turn, not a prefix — this is the text the report is built from.
    assert first.text == long
    assert second.text == "see above"

    # Iteration numbers let the transcript reader order and address turns.
    assert first.i == 0
    assert second.i == 1
  end

  test "a streamed turn emits one event with the full text, not one per delta",
       %{dir: dir} do
    {ref, on_event} = collector()

    assert {:ok, _} =
             Loop.run("hi",
               provider: :mock,
               mock: [text: "hello world"],
               mock_events: [
                 %Event{type: :text_delta, data: "hel"},
                 %Event{type: :text_delta, data: "lo "},
                 %Event{type: :text_delta, data: "world"}
               ],
               cwd: dir,
               tools: [],
               memory: false,
               on_event: on_event
             )

    events = drain(ref)

    # The streaming path really ran: three visible deltas reached the host.
    assert Enum.count(events, &match?({:content, _}, &1)) == 3

    # And still exactly one transcript-bearing event, holding the whole turn.
    assert [%{text: "hello world"}] = for({:assistant_turn, p} <- events, do: p)
  end

  # The runtime makes its own micro-calls through the same Inference path
  # (conclusion distillation, compaction summaries, critiques). Those are the
  # runtime talking to itself, not the worker's prose, and a transcript that
  # mixed them in would report the runtime's words as the worker's.
  test "only conversational turns are tagged, and they say so", %{dir: dir} do
    {ref, on_event} = collector()

    assert {:ok, _} =
             Loop.run("hi",
               provider: :mock,
               mock: [responder: two_turn_responder("working", "done")],
               cwd: dir,
               tools: ["write"],
               memory: false,
               on_event: on_event,
               max_iterations: 5
             )

    turns = assistant_turns(ref)

    assert length(turns) == 2
    assert Enum.all?(turns, &(&1.purpose == :turn))
  end

  # A tool-call-only turn has no prose. Emitting a blank event would put an
  # empty line in every transcript for every such turn.
  test "a turn with no text emits nothing", %{dir: dir} do
    {ref, on_event} = collector()

    assert {:ok, _} =
             Loop.run("go",
               provider: :mock,
               mock: [responder: two_turn_responder("", "done")],
               cwd: dir,
               tools: ["write"],
               memory: false,
               on_event: on_event,
               max_iterations: 5
             )

    assert [%{text: "done"}] = assistant_turns(ref)
  end
end
