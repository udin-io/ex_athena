defmodule ExAthena.Modes.StreamingTest do
  @moduledoc """
  Verifies that the ReAct mode dispatches to `provider_mod.stream/3` when
  the caller registered an `on_event` callback, so per-token `:text_delta`
  deltas reach the caller in real time.
  """
  use ExUnit.Case, async: true

  alias ExAthena.{Loop, Result}
  alias ExAthena.Streaming.Event

  setup do
    dir = Path.join(System.tmp_dir!(), "stream_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "forwards provider text_delta events to on_event in order", %{dir: dir} do
    test_pid = self()

    on_event = fn event ->
      send(test_pid, {:event, event})
    end

    assert {:ok, %Result{finish_reason: :stop}} =
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
               on_event: on_event
             )

    # Per-token deltas should arrive before the final :content event.
    assert_receive {:event, %Event{type: :text_delta, data: "hel"}}
    assert_receive {:event, %Event{type: :text_delta, data: "lo "}}
    assert_receive {:event, %Event{type: :text_delta, data: "world"}}
    assert_receive {:event, {:content, "hello world"}}
  end

  test "falls back to query/2 when on_event is nil", %{dir: dir} do
    assert {:ok, %Result{finish_reason: :stop, text: "no stream needed"}} =
             Loop.run("hi",
               provider: :mock,
               mock: [text: "no stream needed"],
               cwd: dir,
               tools: []
             )
  end
end
