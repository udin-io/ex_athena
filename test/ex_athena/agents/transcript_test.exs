defmodule ExAthena.Agents.TranscriptTest do
  @moduledoc """
  What a worker SAID, on disk, while it was still saying it.

  The journal already records what a worker DID and refuses prose by design.
  Nothing recorded the prose, and `Result.messages` cannot: `Compactors.Summary`
  replaces the middle of history and `EpisodicArchive` keeps the sliced text in
  `state.meta`, in memory, so a report written at turn 19 is gone at turn 20.

  Same writer discipline as the journal — stateless, one open/write/close per
  line, no buffering — so a brutal-killed worker keeps every line up to its
  last.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Agents.Transcript
  alias ExAthena.Messages.{ToolCall, ToolResult}

  setup do
    dir = Path.join(System.tmp_dir!(), "transcript_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, path: Path.join(dir, "subagent_x.ndjson")}
  end

  defp turn(i, text), do: {:assistant_turn, %{i: i, text: text, purpose: :turn}}

  describe "what it keeps" do
    test "one line per turn, in the order the worker said them", %{path: path} do
      Transcript.write(path, turn(0, "first I read the router"))
      Transcript.write(path, turn(1, "then I found the bug"))

      assert ["first I read the router", "then I found the bug"] =
               path |> Transcript.read() |> Enum.map(& &1["text"])
    end

    test "the iteration number rides along, so a turn can be addressed", %{path: path} do
      Transcript.write(path, turn(7, "at turn seven"))

      assert [%{"i" => 7}] = Transcript.read(path)
    end

    # The decision this file exists to hold: prose, and nothing else. The
    # journal already digests tool calls and results, and a second copy of
    # them would be most of the bytes for none of the value.
    test "tool calls, tool results and streamed deltas are refused", %{path: path} do
      Transcript.write(path, {:tool_call, %ToolCall{id: "a", name: "read", arguments: %{}}})
      Transcript.write(path, {:tool_result, %ToolResult{tool_call_id: "a", content: "big"}})
      Transcript.write(path, {:content, "a streamed fragment"})
      Transcript.write(path, {:iteration, 3})

      assert Transcript.read(path) == []
    end

    test "a blank turn is not a line", %{path: path} do
      Transcript.write(path, turn(0, "   \n "))

      assert Transcript.read(path) == []
    end
  end

  describe "caps" do
    test "one oversized turn is cut, and the line says it was", %{path: path} do
      Transcript.write(path, turn(0, String.duplicate("x", 500)), line_chars: 50)

      assert [%{"text" => text, "cut" => 500}] = Transcript.read(path)
      assert String.length(text) == 50
    end

    test "at the size cap it stops writing and records that it stopped", %{path: path} do
      for i <- 0..40,
          do: Transcript.write(path, turn(i, String.duplicate("y", 200)), max_bytes: 900)

      records = Transcript.read(path)

      assert List.last(records)["ev"] == "transcript_truncated"
      # Everything before the marker is intact prose, not a partial write.
      assert Enum.all?(Enum.drop(records, -1), &(&1["text"] == String.duplicate("y", 200)))
    end

    test "a zero cap switches the transcript off entirely", %{path: path} do
      Transcript.write(path, turn(0, "nothing should land"), max_bytes: 0)

      refute File.exists?(path)
    end
  end

  describe "reading it back" do
    # The normal end of a transcript whose writer was killed mid-line. The
    # intact lines before it must still be readable — that is the entire
    # reason this is NDJSON and not one JSON document.
    test "a torn final line does not hide the intact ones", %{path: path} do
      Transcript.write(path, turn(0, "complete"))
      File.write!(path, ~s({"ev":"turn","i":1,"text":"tor), [:append])

      assert [%{"text" => "complete"}] = Transcript.read(path)
    end

    test "a transcript that was never written reads as empty", %{dir: dir} do
      assert Transcript.read(Path.join(dir, "absent.ndjson")) == []
    end

    test "to_text/1 renders addressable turns for a reader", %{path: path} do
      Transcript.write(path, turn(0, "read the router"))
      Transcript.write(path, turn(1, "found the bug"))

      text = path |> Transcript.read() |> Transcript.to_text()

      assert text =~ "read the router"
      assert text =~ "found the bug"
      # Turn boundaries survive, so a chunker can split on them and a reader
      # can say which turn a line came from.
      assert text =~ "turn 0"
      assert text =~ "turn 1"
    end
  end

  describe "compose/3" do
    test "records the event and still passes every event to the inner callback",
         %{path: path} do
      test_pid = self()
      on_event = Transcript.compose(fn e -> send(test_pid, {:inner, e}) end, path)

      on_event.(turn(0, "spoken"))
      on_event.({:iteration, 1})

      assert_receive {:inner, {:assistant_turn, _}}, 1_000
      assert_receive {:inner, {:iteration, 1}}, 1_000
      assert [%{"text" => "spoken"}] = Transcript.read(path)
    end

    test "works with no inner callback at all", %{path: path} do
      on_event = Transcript.compose(nil, path)
      on_event.(turn(0, "spoken"))

      assert [%{"text" => "spoken"}] = Transcript.read(path)
    end
  end

  describe "where it lives" do
    # Beside the journal, under the PARENT's session directory. A
    # `:worktree` worker's own cwd is deleted moments after it finishes.
    test "path/3 sits beside the journal, not inside it", %{dir: dir} do
      path = Transcript.path(dir, "sess", "subagent_abc")

      assert path =~ Path.join([".exathena", "sessions", "sess"])
      assert Path.basename(path) == "subagent_abc.ndjson"
      assert Path.basename(Path.dirname(path)) == "transcript"
    end
  end
end
