defmodule ExAthena.Web.TraceTest do
  @moduledoc """
  Issue 352: the Trace tab's data, built from a session's activity log and its
  helpers' journals. Every fixture here is written by hand.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Web.Trace

  @created ~U[2026-11-28 10:00:00.000Z]

  # Entries are given oldest first, as they happened; a session stores them
  # newest first.
  defp session(entries, extra \\ %{}) do
    stream =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {e, i} -> Map.put_new(e, :id, "d#{i}") end)
      |> Enum.reverse()

    Map.merge(%{id: "sess1", cwd: nil, created_at: @created, details_stream: stream}, extra)
  end

  defp e(type, payload, at), do: %{type: type, message_id: "m1", payload: payload, at: at}
  defp untimed(type, payload), do: %{type: type, message_id: "m1", payload: payload}

  defp iteration(n, at), do: e(:iteration, %{n: n}, at)

  defp call(id, name, at, args \\ %{}),
    do: e(:tool_call, %{tool_call_id: id, name: name, arguments: args}, at)

  defp result(id, content, at),
    do: e(:tool_result, %{tool_call_id: id, content: content, is_error: false}, at)

  defp bash_ui(id, outcome, at),
    do: e(:tool_ui, %{tool_call_id: id, ui: %{kind: :process}, test: outcome}, at)

  defp chat_lane(trace), do: Enum.find(trace.lanes, &(&1.id == "chat"))

  test "a session with two helpers draws three lanes" do
    trace =
      session([
        e(:user_text, %{text: "do it"}, 0),
        iteration(1, 10),
        call("c1", "spawn_agent", 20),
        e(:subagent_spawn, %{id: "sub_a", prompt: "explore"}, 30),
        e(:subagent_spawn, %{id: "sub_b", prompt: "test"}, 40),
        e(:subagent_result, %{id: "sub_a", len: 10}, 500),
        e(:subagent_result, %{id: "sub_b", len: 10}, 900),
        iteration(2, 1000)
      ])
      |> Trace.build()

    assert Enum.map(trace.lanes, & &1.label) == ["chat", "helper 1", "helper 2"]

    [_chat, a, b] = trace.lanes
    assert {a0, a1} = a.span
    assert {b0, b1} = b.span
    assert a0 < a1 and b0 < b1
    assert a1 < b1
  end

  test "a failed test shows as failed, a passing one as passed" do
    trace =
      session([
        iteration(1, 0),
        call("b1", "bash", 10, %{"command" => "mix test"}),
        bash_ui("b1", :failed, 20),
        result("b1", "exit 2\n3 tests, 1 failure", 21),
        iteration(2, 100),
        call("b2", "bash", 110, %{"command" => "mix test"}),
        bash_ui("b2", :passed, 120)
      ])
      |> Trace.build()

    assert Enum.map(chat_lane(trace).marks, & &1.kind) == [:test_failed, :test_passed]
    assert [%{result: "exit 2\n3 tests, 1 failure", test: :failed}] = trace.turns["t1"].calls
  end

  test "a turn is the most telling thing it did" do
    trace =
      session([
        iteration(1, 0),
        call("r1", "read", 1),
        iteration(2, 10),
        call("r2", "read", 11),
        call("w1", "edit", 12),
        iteration(3, 20),
        call("u1", "usage_rules", 21),
        iteration(4, 30),
        e(:assistant_text, %{text: "done"}, 31)
      ])
      |> Trace.build()

    assert Enum.map(chat_lane(trace).marks, & &1.kind) == [:read, :edit, :lookup, :answer]
  end

  test "a recorded wrap-up note shows its marker at its turn" do
    trace =
      session([
        iteration(1, 0),
        call("r1", "read", 10),
        iteration(2, 1000),
        e(:steer, %{kind: :wrap_up, text: "[runtime] You are 2 turns in"}, 1000),
        call("r2", "read", 1010),
        iteration(3, 2000)
      ])
      |> Trace.build()

    assert [%{letter: "W", turn: "t2", x: x, text: "[runtime] You are 2 turns in"}] = trace.notes
    assert %{x: ^x} = Enum.find(chat_lane(trace).marks, &(&1.id == "t2"))
    assert [%{kind: :wrap_up}] = trace.turns["t2"].steers
  end

  test "a finish check goes with the turn whose request carried it" do
    check = %{kind: :finish_check, check: "test", text: "[chat runtime: test check] x"}

    trace =
      session([
        iteration(1, 0),
        call("w1", "edit", 10),
        e(:steer, check, 20),
        iteration(2, 100),
        call("b1", "bash", 110)
      ])
      |> Trace.build()

    assert trace.turns["t1"].steers == []
    assert [%{kind: :finish_check, turn: "t2"}] = trace.turns["t2"].steers
    assert [%{letter: "T", turn: "t2"}] = trace.notes
  end

  test "a check left waiting when the log ends goes with the last turn" do
    trace =
      session([
        iteration(1, 0),
        e(:steer, %{kind: :open_steps, text: "[chat runtime: open steps] x"}, 5)
      ])
      |> Trace.build()

    assert [%{kind: :open_steps, turn: "t1"}] = trace.turns["t1"].steers
  end

  test "a compaction goes with the turn it shrank the history for, and opens none" do
    trace =
      session([
        e(:user_text, %{text: "go"}, 0),
        e(:compaction, %{before: 10, after: 2, reason: :proactive}, 5),
        e(:model_call, %{purpose: :compaction, duration_ms: 3, ok?: true}, 6),
        e(:usage, %{usage: %{input_tokens: 70, cached_tokens: 0}}, 7),
        iteration(1, 10),
        call("r1", "read", 11)
      ])
      |> Trace.build()

    assert trace.turn_count == 1
    assert [%{kind: :read}] = chat_lane(trace).marks
    assert [%{letter: "Z", turn: "t1"}] = trace.notes
    assert trace.tokens_in == 70
    assert [%{input: 70}] = trace.tokens
  end

  test "an untimed check note sits on the turn that carried it" do
    check = %{kind: :finish_check, check: "test", text: "[chat runtime: test check] x"}

    trace =
      session([
        untimed(:iteration, %{n: 1}),
        untimed(:steer, check),
        untimed(:iteration, %{n: 2}),
        untimed(:iteration, %{n: 3})
      ])
      |> Trace.build()

    [_t1, t2, _t3] = chat_lane(trace).marks
    assert [%{turn: "t2", x: x}] = trace.notes
    assert x == t2.x
  end

  test "an entry of an odd shape is read as data, never a crash" do
    trace =
      session([
        iteration(1, 0),
        %{type: :usage, message_id: "m1", payload: nil, at: 1},
        %{type: :tool_ui, message_id: "m1", payload: "x", at: 2},
        %{type: :subagent_spawn, message_id: "m1", payload: nil, at: 3},
        e(:error, %{reason: {:timeout, 5}}, 4),
        e(:tool_call, %{tool_call_id: "c", name: nil, arguments: nil}, 5),
        %{type: :thinking, message_id: "m1", at: "soon"}
      ])
      |> Trace.build()

    assert [%{kind: :error}] = chat_lane(trace).marks
    assert trace.turns["t1"].errors == ["{:timeout, 5}"]
    assert Trace.helper_records(session([%{type: :subagent_spawn, payload: nil}])) == %{}
  end

  test "an untimed axis ends on the last turn" do
    trace =
      session(for n <- 1..12, do: untimed(:iteration, %{n: n}))
      |> Trace.build()

    labels = Enum.map(trace.ticks, & &1.label)
    assert List.first(labels) == "turn 1"
    refute "turn 13" in labels
  end

  test "the header total counts the helpers' tokens too" do
    t0 = DateTime.to_unix(@created, :millisecond)

    records = [
      %{"ev" => "iteration", "i" => 0, "t" => t0 + 10},
      %{"ev" => "usage", "in" => 500, "out" => 5, "t" => t0 + 20},
      %{"ev" => "iteration", "i" => 1, "t" => t0 + 30},
      %{"ev" => "turn", "i" => 0, "text" => "I looked at the upload handler."},
      %{"ev" => "turn", "i" => 1, "text" => "Done."}
    ]

    trace =
      session([
        iteration(1, 0),
        e(:usage, %{usage: %{input_tokens: 1000, cached_tokens: 0}}, 1),
        e(:subagent_spawn, %{id: "sub_a", prompt: "x"}, 2)
      ])
      |> Trace.build(%{"sub_a" => records})

    assert trace.tokens_in == 1500
    assert trace.turns["h1-1"].text == "I looked at the upload handler."
    assert trace.turns["h1-2"].text == "Done."
  end

  test "a finish check marker names its check" do
    trace =
      session([
        iteration(1, 0),
        e(:steer, %{kind: :finish_check, check: "test", text: "[chat runtime: test check] x"}, 5)
      ])
      |> Trace.build()

    assert [%{letter: "T"}] = trace.notes
  end

  test "a session saved without times draws its turns evenly spaced and says so" do
    trace =
      session([
        untimed(:user_text, %{text: "hi"}),
        untimed(:iteration, %{n: 1}),
        untimed(:tool_call, %{tool_call_id: "c1", name: "read", arguments: %{}}),
        untimed(:iteration, %{n: 2}),
        untimed(:iteration, %{n: 3}),
        untimed(:iteration, %{n: 4})
      ])
      |> Trace.build()

    refute trace.timed?
    assert trace.duration_ms == nil
    assert Enum.map(chat_lane(trace).marks, & &1.x) == [0.0, 25.0, 50.0, 75.0]
  end

  test "a timed session spans its first entry to its last" do
    trace =
      session([iteration(1, 60_000), call("r1", "read", 61_000), iteration(2, 120_000)])
      |> Trace.build()

    assert trace.timed?
    assert trace.duration_ms == 60_000
    assert Enum.map(chat_lane(trace).marks, & &1.x) == [0.0, 100.0]
  end

  test "token points carry each call's input and cached share" do
    usage = fn i, c, at ->
      e(:usage, %{usage: %{input_tokens: i, cached_tokens: c}}, at)
    end

    trace =
      session([iteration(1, 0), usage.(1000, 0, 10), iteration(2, 100), usage.(2000, 1500, 110)])
      |> Trace.build()

    assert trace.tokens_in == 3000
    assert Enum.map(trace.tokens, &{&1.h_in, &1.h_cached}) == [{50.0, 0.0}, {100.0, 75.0}]
  end

  test "many narrow turns of one kind fold into one mark that lists them all" do
    entries =
      Enum.flat_map(1..1_000, fn n ->
        [iteration(n, n * 10), call("r#{n}", "read", n * 10 + 1)]
      end)

    trace = entries |> session() |> Trace.build()
    marks = chat_lane(trace).marks

    assert length(marks) < 200
    assert marks |> Enum.flat_map(& &1.turns) |> length() == 1_000
  end

  test "a helper's turns come from its journal" do
    t0 = DateTime.to_unix(@created, :millisecond)

    records = [
      %{"ev" => "iteration", "i" => 1, "t" => t0 + 100},
      %{"ev" => "tool_call", "id" => "h1", "name" => "bash", "t" => t0 + 110},
      %{
        "ev" => "tool_result",
        "id" => "h1",
        "ok" => true,
        "cmd" => "mix test",
        "outcome" => "failed",
        "t" => t0 + 120
      },
      %{"ev" => "iteration", "i" => 2, "t" => t0 + 300},
      %{"ev" => "tool_call", "id" => "h2", "name" => "edit", "t" => t0 + 310}
    ]

    trace =
      session([
        iteration(1, 0),
        e(:subagent_spawn, %{id: "sub_a", prompt: "fix it"}, 50),
        e(:subagent_result, %{id: "sub_a", len: 3}, 400)
      ])
      |> Trace.build(%{"sub_a" => records})

    helper = Enum.find(trace.lanes, &(&1.id == "sub_a"))
    assert Enum.map(helper.marks, & &1.kind) == [:test_failed, :edit]
    assert trace.turn_count == 3
  end

  describe "helper_records/1" do
    @describetag :tmp_dir

    test "reads each helper's journal under the session's folder", %{tmp_dir: dir} do
      journal = Path.join([dir, ".exathena", "sessions", "run1", "journal", "sub_a.ndjson"])
      File.mkdir_p!(Path.dirname(journal))
      File.write!(journal, ~s({"ev":"iteration","i":1,"t":5}\n))

      s = session([e(:subagent_spawn, %{id: "sub_a", prompt: "x"}, 1)], %{cwd: dir})

      assert %{"sub_a" => [%{"ev" => "iteration"}]} = Trace.helper_records(s)
    end

    test "a project folder whose name looks like a pattern still finds its journals",
         %{tmp_dir: dir} do
      cwd = Path.join(dir, "p[1]*")
      journal = Path.join([cwd, ".exathena", "sessions", "run1", "journal", "sub_a.ndjson"])
      File.mkdir_p!(Path.dirname(journal))
      File.write!(journal, ~s({"ev":"iteration","i":1,"t":5}\n))

      transcript = Path.join([cwd, ".exathena", "sessions", "run1", "transcript", "sub_a.ndjson"])
      File.mkdir_p!(Path.dirname(transcript))
      File.write!(transcript, ~s({"ev":"turn","i":1,"text":"hello"}\n))

      s = session([e(:subagent_spawn, %{id: "sub_a", prompt: "x"}, 1)], %{cwd: cwd})

      assert %{"sub_a" => [%{"ev" => "iteration"}, %{"ev" => "turn"}]} = Trace.helper_records(s)
    end

    test "a helper's journal is found in whichever run folder holds it", %{tmp_dir: dir} do
      for run <- ~w(run1 run2),
          do: File.mkdir_p!(Path.join([dir, ".exathena", "sessions", run, "journal"]))

      journal = Path.join([dir, ".exathena", "sessions", "run2", "journal", "sub_b.ndjson"])
      File.write!(journal, ~s({"ev":"iteration","i":0,"t":5}\n))

      s = session([e(:subagent_spawn, %{id: "sub_b", prompt: "x"}, 1)], %{cwd: dir})

      assert %{"sub_b" => [%{"ev" => "iteration", "i" => 0}]} = Trace.helper_records(s)
    end

    test "an id that could name another folder is never looked up", %{tmp_dir: dir} do
      outside = Path.join(dir, "secret.ndjson")
      File.write!(outside, ~s({"ev":"iteration","i":1,"t":5}\n))
      nested = Path.join([dir, ".exathena", "sessions", "run1", "journal"])
      File.mkdir_p!(nested)

      s =
        session([e(:subagent_spawn, %{id: "../../../../secret", prompt: "x"}, 1)], %{cwd: dir})

      assert Trace.helper_records(s) == %{}
    end
  end
end
