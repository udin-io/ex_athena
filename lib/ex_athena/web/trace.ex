defmodule ExAthena.Web.Trace do
  @moduledoc """
  A session drawn as lanes of turns over time (issue 352): the data behind the
  web chat's Trace tab, and behind the file `mix athena.trace` saves.

  `build/2` is pure: it reads a saved or live session map (the shape
  `ExAthena.Web.Live.ChatLive.session_payload/1` writes) and the helpers'
  journal records, and returns lanes, marks, notes and token points with each
  position already worked out as a share of the drawing's width.
  `helper_records/1` does the one bit of IO, reading each helper's journal.

  A turn is one model call: the chat's turns start at each `:iteration` entry
  of its activity log, a helper's at each `iteration` line of its journal. A
  turn's kind is what it did, the most telling thing first: an error, a test
  that failed, a test that passed, an edit, a command, a helper sent, a
  question, a library lookup, a read or search, and otherwise an answer.

  Times come from each entry's `at` (ms since the session began, issue 351).
  A session saved without them is drawn with its turns evenly spaced, and
  `timed?` says so.
  """

  alias ExAthena.Agents.{Journal, Transcript}

  # Marks narrower than this share of the width, next to one of the same
  # kind, fold into one group mark, so a 1,000-turn run stays legible.
  @min_mark_pct 0.6

  @read_tools ~w(read read_summary glob grep lsp read_worker_report)
  @lookup_tools ~w(usage_rules web_search web_fetch skill)
  @edit_tools ~w(write edit apply_patch)
  @command_tools ~w(bash gh)

  @helper_id ~r/\A[A-Za-z0-9_-]{1,128}\z/

  @kinds [
    :error,
    :test_failed,
    :test_passed,
    :edit,
    :command,
    :helper,
    :question,
    :lookup,
    :read,
    :answer
  ]

  @doc "Turn kinds, most telling first. Also the legend's order."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Build the trace of `session`. `helpers` maps a helper's id to its journal
  records, as `helper_records/1` returns them.
  """
  @spec build(map(), %{optional(String.t()) => [map()]}) :: map()
  def build(session, helpers \\ %{}) when is_map(session) do
    entries =
      session
      |> Map.get(:details_stream)
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&normalise/1)
      |> Enum.reverse()

    origin = origin_ms(session)
    timed? = entries != [] and Enum.all?(entries, &is_integer(Map.get(&1, :at)))

    {requests, chat_turns, steers, tokens, spawns} = walk(entries)
    helper_lanes = helper_lanes(spawns, helpers, origin)

    clock = clock(timed?, chat_turns, Enum.flat_map(helper_lanes, & &1.turns), entries)

    chat = %{
      id: "chat",
      label: "chat",
      kind: :chat,
      span: nil,
      title: nil,
      marks: marks(chat_turns, clock)
    }

    lanes = [chat | Enum.map(helper_lanes, &place_helper(&1, clock))]

    turns = chat_turns ++ Enum.flat_map(helper_lanes, & &1.turns)

    %{
      id: Map.get(session, :id),
      title: Map.get(session, :title),
      timed?: timed?,
      x0: clock.x0,
      duration_ms: if(timed?, do: clock.x1 - clock.x0),
      turn_count: length(turns),
      # Every call the chat made (a compaction's summary included) and every
      # helper's.
      tokens_in:
        Enum.sum(Enum.map(tokens, & &1.input)) +
          Enum.sum(
            Enum.map(helper_lanes, fn l -> l.turns |> Enum.map(& &1.input) |> Enum.sum() end)
          ),
      requests: Enum.map(requests, &place_point(&1, clock)),
      lanes: lanes,
      notes: Enum.map(steers, &place_note(&1, clock)),
      tokens: place_tokens(tokens, clock),
      ticks: ticks(clock),
      turns: Map.new(turns, &{&1.id, &1})
    }
  end

  @doc """
  Each helper's journal records, keyed by its id, read from
  `<cwd>/.exathena/sessions/*/journal/<id>.ndjson`.

  Only ids made of letters, digits, `_` and `-` are looked up, so an id read
  from a session file can never name a path outside that folder.
  """
  @spec helper_records(map()) :: %{optional(String.t()) => [map()]}
  def helper_records(session) when is_map(session) do
    cwd = Map.get(session, :cwd)

    ids =
      for %{type: :subagent_spawn, payload: %{} = payload} <-
            List.wrap(Map.get(session, :details_stream)),
          id = payload |> Map.get(:id) |> to_string(),
          Regex.match?(@helper_id, id),
          uniq: true,
          do: id

    if is_binary(cwd) and ids != [] do
      journals = journals_by_run(cwd)
      Map.new(ids, &{&1, helper_files(cwd, journals, &1)})
    else
      %{}
    end
  end

  # Listed, never globbed: a project folder named `p[1]` or `a*` is a path,
  # not a pattern.
  defp run_ids(cwd) do
    case File.ls(Path.join([cwd, ".exathena", "sessions"])) do
      {:ok, names} -> Enum.sort(names)
      {:error, _} -> []
    end
  end

  # Each run folder with the journal files it holds: one listing per run, so
  # only a helper's own files are ever read.
  defp journals_by_run(cwd) do
    for run <- run_ids(cwd),
        {:ok, names} <- [File.ls(Path.join([cwd, ".exathena", "sessions", run, "journal"]))],
        do: {run, MapSet.new(names)}
  end

  # A helper's journal, then its transcript's turns, which carry what it said.
  # Helper ids are random, so the first run that holds one is its run.
  defp helper_files(cwd, journals, id) do
    case Enum.find(journals, fn {_run, names} -> MapSet.member?(names, id <> ".ndjson") end) do
      {run, _} ->
        Journal.read(Journal.path(cwd, run, id)) ++
          (cwd
           |> Transcript.path(run, id)
           |> Journal.read()
           |> Enum.filter(&(&1["ev"] == "turn")))

      nil ->
        []
    end
  end

  # ── Reading the chat's activity log ───────────────────────────────

  # A saved file is read as data: a payload that is not a map reads as empty,
  # and a time that is not a whole number reads as missing.
  defp normalise(entry) do
    payload = if is_map(Map.get(entry, :payload)), do: entry.payload, else: %{}
    entry = Map.put(entry, :payload, payload)
    if is_integer(Map.get(entry, :at)), do: entry, else: Map.delete(entry, :at)
  end

  defp text(value) when is_binary(value), do: value
  defp text(nil), do: ""
  defp text(value), do: inspect(value)

  defp walk(entries) do
    acc = %{
      requests: [],
      turns: [],
      current: nil,
      steers: [],
      waiting: [],
      tokens: [],
      spawns: [],
      pos: 0
    }

    acc =
      entries
      |> Enum.reduce(acc, fn entry, acc -> entry |> step(acc) |> touch(entry) end)
      |> close_turn()
      |> settle_waiting()

    turns = acc.turns |> Enum.reverse() |> Enum.map(&finish_steers/1)
    steers = Enum.flat_map(turns, & &1.steers) ++ Enum.reverse(acc.steers)

    {Enum.reverse(acc.requests), turns, Enum.sort_by(steers, &{&1.pos, &1.at || 0}),
     Enum.reverse(acc.tokens), Enum.reverse(acc.spawns)}
  end

  defp step(%{type: :user_text} = e, acc) do
    acc = close_turn(acc)
    request = %{at: e[:at], pos: acc.pos, text: text_of(e)}
    %{acc | requests: [request | acc.requests]}
  end

  defp step(%{type: :iteration} = e, acc) do
    acc |> close_turn() |> open_turn(e)
  end

  # A compaction runs before the turn it shrank the history for.
  defp step(%{type: :compaction} = e, acc) do
    note = %{at: e[:at], pos: acc.pos, kind: :compaction, check: nil, text: "history compacted"}
    %{acc | waiting: [Map.put(note, :turn, nil) | acc.waiting]}
  end

  # A call outside any turn (a compaction's summary) opens none; its tokens
  # still count.
  defp step(%{type: :model_call}, %{current: nil} = acc), do: acc

  defp step(%{type: :usage, payload: p} = e, %{current: nil} = acc),
    do: Map.update!(acc, :tokens, &[token_point(p, e, acc) | &1])

  defp step(e, %{current: nil} = acc), do: step(e, open_turn(acc, e))

  defp step(%{type: :tool_call, payload: p}, acc) do
    call = %{
      id: p[:tool_call_id],
      name: text(p[:name]),
      args: p[:arguments],
      result: nil,
      is_error: false,
      test: nil
    }

    update_current(acc, &%{&1 | calls: [call | &1.calls]})
  end

  defp step(%{type: :tool_result, payload: p}, acc) do
    update_call(
      acc,
      p[:tool_call_id],
      &%{&1 | result: p[:content], is_error: p[:is_error] == true}
    )
  end

  defp step(%{type: :tool_ui, payload: p}, acc) do
    case Map.get(p, :test) do
      nil -> acc
      outcome -> update_call(acc, p[:tool_call_id], &%{&1 | test: outcome})
    end
  end

  defp step(%{type: :thinking} = e, acc),
    do: update_current(acc, &%{&1 | thinking: &1.thinking <> text_of(e)})

  defp step(%{type: :assistant_text} = e, acc),
    do: update_current(acc, &%{&1 | text: &1.text <> text_of(e)})

  # A finish check or an open-steps note is decided after a turn's call and
  # rides the NEXT request, so it waits for the next turn. The other notes are
  # built into the request of the turn they arrive in.
  defp step(%{type: :steer, payload: %{kind: kind} = p} = e, acc)
       when kind in [:finish_check, :open_steps] do
    %{acc | waiting: [steer(p, e, acc) | acc.waiting]}
  end

  defp step(%{type: :steer, payload: p} = e, acc),
    do: update_current(acc, &%{&1 | steers: [steer(p, e, acc) | &1.steers]})

  defp step(%{type: :usage, payload: p} = e, acc) do
    point = token_point(p, e, acc)

    acc
    |> update_current(&%{&1 | input: &1.input + point.input, cached: &1.cached + point.cached})
    |> Map.update!(:tokens, &[point | &1])
  end

  defp step(%{type: :model_call, payload: p}, acc),
    do: update_current(acc, &%{&1 | model_ms: &1.model_ms + int(p[:duration_ms])})

  defp step(%{type: :error, payload: p}, acc),
    do: update_current(acc, &%{&1 | errors: [text(p[:reason]) | &1.errors]})

  defp step(%{type: :subagent_spawn, payload: p} = e, acc) do
    spawn = %{
      id: to_string(Map.get(p, :id)),
      prompt: to_string(Map.get(p, :prompt) || ""),
      at: e[:at],
      pos: acc.pos,
      end_at: nil,
      end_pos: nil
    }

    %{acc | spawns: [spawn | acc.spawns]}
  end

  defp step(%{type: :subagent_result, payload: p} = e, acc) do
    id = to_string(Map.get(p, :id))

    spawns =
      Enum.map(acc.spawns, fn
        %{id: ^id, end_pos: nil} = s -> %{s | end_at: e[:at], end_pos: acc.pos}
        s -> s
      end)

    %{acc | spawns: spawns}
  end

  defp step(_entry, acc), do: acc

  defp token_point(p, e, acc) do
    usage = if is_map(p[:usage]), do: p[:usage], else: %{}

    %{
      at: e[:at],
      pos: acc.pos,
      input: int(usage[:input_tokens]),
      cached: int(usage[:cached_tokens])
    }
  end

  defp steer(p, e, acc) do
    %{at: e[:at], pos: acc.pos, kind: p[:kind], check: p[:check], text: text(p[:text]), turn: nil}
  end

  # Notes still waiting when the log ends go with the last turn.
  defp settle_waiting(%{waiting: []} = acc), do: acc

  defp settle_waiting(%{turns: [last | rest]} = acc),
    do: %{
      acc
      | turns: [
          %{
            last
            | steers: last.steers ++ Enum.map(Enum.reverse(acc.waiting), &%{&1 | pos: last.pos})
          }
          | rest
        ],
        waiting: []
    }

  defp settle_waiting(acc), do: %{acc | waiting: []}

  # A waiting note sits where its turn sits.
  defp take_waiting(turn, waiting),
    do: %{turn | steers: Enum.map(waiting, &%{&1 | pos: turn.pos}) ++ turn.steers}

  defp finish_steers(turn), do: %{turn | steers: Enum.map(turn.steers, &%{&1 | turn: turn.id})}

  defp open_turn(acc, entry) do
    n = length(acc.turns) + 1

    turn =
      new_turn("chat", "t#{n}", n)
      |> Map.merge(%{at: entry[:at], end_at: entry[:at], pos: acc.pos})
      |> take_waiting(acc.waiting)

    %{acc | current: turn, waiting: []}
  end

  defp close_turn(%{current: nil} = acc), do: acc

  defp close_turn(%{current: turn} = acc) do
    turn = finish_turn(turn)
    %{acc | turns: [turn | acc.turns], current: nil, pos: acc.pos + 1}
  end

  defp new_turn(lane, id, n) do
    %{
      id: id,
      lane: lane,
      n: n,
      at: nil,
      end_at: nil,
      pos: 0,
      calls: [],
      thinking: "",
      text: "",
      steers: [],
      input: 0,
      cached: 0,
      model_ms: 0,
      errors: [],
      kind: :answer
    }
  end

  defp finish_turn(turn) do
    turn = %{turn | calls: Enum.reverse(turn.calls), steers: Enum.reverse(turn.steers)}
    %{turn | kind: kind(turn)}
  end

  defp update_current(acc, fun), do: %{acc | current: fun.(acc.current)}

  defp update_call(%{current: nil} = acc, _id, _fun), do: acc

  defp update_call(acc, id, fun) do
    update_current(acc, fn turn ->
      calls =
        Enum.map(turn.calls, fn
          %{id: ^id} = call -> fun.(call)
          call -> call
        end)

      %{turn | calls: calls}
    end)
  end

  # Every later entry of a turn moves its end, so the mark spans what the turn
  # did and not only the moment it started.
  defp touch(%{current: %{} = turn} = acc, %{at: at}) when is_integer(at),
    do: %{acc | current: %{turn | end_at: at}}

  defp touch(acc, _entry), do: acc

  defp text_of(%{payload: %{text: text}}) when is_binary(text), do: text
  defp text_of(_entry), do: ""

  defp int(n) when is_integer(n), do: n
  defp int(_), do: 0

  # The most telling thing a turn did, in the order of `@kinds`.
  defp kind(turn) do
    names = Enum.map(turn.calls, & &1.name)
    tests = Enum.map(turn.calls, & &1.test)

    cond do
      turn.errors != [] -> :error
      :failed in tests -> :test_failed
      :passed in tests -> :test_passed
      Enum.any?(names, &(&1 in @edit_tools)) -> :edit
      Enum.any?(names, &(&1 in @command_tools)) -> :command
      "spawn_agent" in names -> :helper
      "ask_user" in names -> :question
      Enum.any?(names, &(&1 in @lookup_tools)) -> :lookup
      Enum.any?(names, &(&1 in @read_tools)) -> :read
      true -> :answer
    end
  end

  # ── Helpers' lanes, from their journals ───────────────────────────

  defp helper_lanes(spawns, helpers, origin) do
    spawns
    |> Enum.with_index(1)
    |> Enum.map(fn {spawn, i} ->
      records = Map.get(helpers, spawn.id, [])
      turns = helper_turns(spawn.id, i, records, origin)

      %{
        id: spawn.id,
        label: "helper #{i}",
        kind: :helper,
        title: excerpt(spawn.prompt, 200),
        spawn: spawn,
        turns: turns
      }
    end)
  end

  defp helper_turns(id, lane_n, records, origin) do
    {turns, current} =
      Enum.reduce(records, {[], nil}, fn record, {done, cur} ->
        at = journal_at(record, origin)

        case record do
          %{"ev" => "iteration"} = r ->
            n = length(done) + if(cur, do: 2, else: 1)

            next =
              new_turn(id, "h#{lane_n}-#{n}", n)
              |> Map.merge(%{at: at, end_at: at, iteration: r["i"]})

            {push(done, cur), next}

          %{"ev" => "tool_call"} = r ->
            cur = cur || new_turn(id, "h#{lane_n}-1", 1) |> Map.merge(%{at: at, end_at: at})

            call = %{
              id: r["id"],
              name: to_string(r["name"]),
              args: r["args"],
              result: nil,
              is_error: false,
              test: nil
            }

            {done, %{cur | calls: [call | cur.calls], end_at: at}}

          %{"ev" => "tool_result"} = r when cur != nil ->
            test = journal_test(r)
            rid = r["id"]

            calls =
              Enum.map(cur.calls, fn
                %{id: ^rid} = c -> %{c | is_error: r["ok"] == false, test: test}
                c -> c
              end)

            {done, %{cur | calls: calls, end_at: at}}

          %{"ev" => "usage"} = r when cur != nil ->
            {done, %{cur | input: cur.input + int(r["in"]), end_at: at}}

          _ ->
            {done, cur}
        end
      end)

    said = for %{"ev" => "turn", "i" => i, "text" => t} <- records, is_binary(t), do: {i, t}

    turns
    |> push(current)
    |> Enum.reverse()
    |> Enum.map(&finish_turn/1)
    |> Enum.map(fn turn ->
      # The transcript numbers a turn as the loop does, from 0: join on the
      # journal's own number, never on the position.
      i = Map.get(turn, :iteration)
      %{turn | text: Enum.join(for({j, t} <- said, i != nil and j == i, do: t), "\n")}
    end)
  end

  defp push(done, nil), do: done
  defp push(done, turn), do: [turn | done]

  # A test command's journal line is judged where its output was in hand.
  defp journal_test(%{"cmd" => cmd, "outcome" => outcome}) when is_binary(cmd) do
    if ExAthena.Provenance.test_command?(cmd), do: test_outcome(outcome)
  end

  defp journal_test(_record), do: nil

  defp test_outcome("failed"), do: :failed
  defp test_outcome("passed"), do: :passed
  defp test_outcome("unconfirmed"), do: :unconfirmed
  defp test_outcome(_), do: nil

  defp journal_at(%{"t" => t}, origin) when is_integer(t) and is_integer(origin), do: t - origin
  defp journal_at(_record, _origin), do: nil

  defp origin_ms(session) do
    case Map.get(session, :created_at) do
      %DateTime{} = dt -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  # ── Placing things on the width ───────────────────────────────────

  # A timed trace runs from its first entry to its last, in ms. An untimed one
  # runs over turn positions: each chat turn is one step, and the request and
  # note marks sit at the step they arrived in.
  defp clock(true, chat_turns, helper_turns, entries) do
    helper_ats = for t <- helper_turns, a <- [t.at, t.end_at], is_integer(a), do: a
    ats = Enum.map(entries, & &1.at) ++ helper_ats ++ Enum.map(chat_turns, & &1.at)
    x0 = Enum.min(ats)
    x1 = Enum.max(ats)
    %{timed?: true, x0: x0, x1: max(x1, x0 + 1)}
  end

  defp clock(false, chat_turns, _helper_turns, _entries),
    do: %{timed?: false, x0: 0, x1: max(length(chat_turns), 1)}

  defp pct(%{x0: x0, x1: x1}, x) when is_number(x),
    do: Float.round((x - x0) / (x1 - x0) * 100, 3) |> max(0.0) |> min(100.0)

  defp pct(_clock, _x), do: 0.0

  defp coord(%{timed?: true}, item), do: item.at
  defp coord(%{timed?: false}, item), do: item.pos

  defp place_point(item, clock), do: Map.put(item, :x, pct(clock, coord(clock, item)))

  defp place_note(steer, clock) do
    steer |> place_point(clock) |> Map.put(:letter, note_letter(steer))
  end

  defp place_tokens(points, clock) do
    placed = Enum.map(points, &place_point(&1, clock))
    max = placed |> Enum.map(& &1.input) |> Enum.max(fn -> 0 end)

    Enum.map(placed, fn p ->
      p
      |> Map.put(:h_in, share(p.input, max))
      |> Map.put(:h_cached, share(min(p.cached, p.input), max))
    end)
  end

  defp share(_n, 0), do: 0.0
  defp share(n, max), do: Float.round(n / max * 100, 2)

  # A turn spans from its start to the next turn's start (its last entry for
  # the last one); untimed, each turn is one step wide.
  defp marks(turns, clock) do
    starts = Enum.map(turns, &coord(clock, &1))
    nexts = Enum.drop(starts, 1) ++ [last_end(turns, clock)]

    turns
    |> Enum.zip(nexts)
    |> Enum.map(fn {turn, next} ->
      x = pct(clock, coord(clock, turn))
      %{id: turn.id, kind: turn.kind, x: x, w: max(pct(clock, next) - x, 0.0), turns: [turn.id]}
    end)
    |> group()
  end

  defp last_end([], _clock), do: 0
  defp last_end(turns, %{timed?: true} = clock), do: List.last(turns).end_at || clock.x1
  defp last_end(turns, %{timed?: false}), do: List.last(turns).pos + 1

  defp place_helper(lane, clock) do
    spawn = lane.spawn
    x0 = pct(clock, coord(clock, spawn))

    x1 =
      case {clock.timed?, spawn.end_at, spawn.end_pos} do
        {true, at, _} when is_integer(at) -> pct(clock, at)
        {false, _, pos} when is_integer(pos) -> pct(clock, pos + 1)
        _ -> 100.0
      end

    marks =
      if clock.timed? and Enum.all?(lane.turns, &is_integer(&1.at)) do
        marks(lane.turns, clock)
      else
        spread(lane.turns, x0, x1)
      end

    lane
    |> Map.drop([:spawn, :turns])
    |> Map.merge(%{span: {x0, max(x1, x0)}, marks: marks})
  end

  # Untimed helper turns share their span evenly.
  defp spread([], _x0, _x1), do: []

  defp spread(turns, x0, x1) do
    w = max(x1 - x0, 0.0) / length(turns)

    turns
    |> Enum.with_index()
    |> Enum.map(fn {turn, i} ->
      %{id: turn.id, kind: turn.kind, x: Float.round(x0 + i * w, 3), w: w, turns: [turn.id]}
    end)
    |> group()
  end

  # Consecutive narrow marks of one kind fold into one, which lists them all.
  defp group(marks) do
    marks
    |> Enum.reduce([], fn
      mark, [prev | rest]
      when prev.kind == mark.kind and mark.w < @min_mark_pct and prev.w < @min_mark_pct * 4 ->
        [%{prev | w: mark.x + mark.w - prev.x, turns: prev.turns ++ mark.turns} | rest]

      mark, acc ->
        [mark | acc]
    end)
    |> Enum.reverse()
  end

  defp note_letter(%{kind: :compaction}), do: "Z"
  defp note_letter(%{kind: :research}), do: "R"
  defp note_letter(%{kind: :wrap_up}), do: "W"
  defp note_letter(%{kind: :handback}), do: "H"
  defp note_letter(%{kind: :ledger_repeat}), do: "L"
  defp note_letter(%{kind: :open_steps}), do: "O"
  defp note_letter(%{kind: :finish_check, check: "test"}), do: "T"
  defp note_letter(%{kind: :finish_check, check: "verification"}), do: "V"
  defp note_letter(%{kind: :finish_check, check: "coverage"}), do: "C"
  defp note_letter(%{kind: :finish_check, check: "audit"}), do: "A"
  defp note_letter(_steer), do: "N"

  # ── The time axis ─────────────────────────────────────────────────

  @tick_steps [
    1_000,
    5_000,
    15_000,
    30_000,
    60_000,
    300_000,
    600_000,
    900_000,
    1_800_000,
    3_600_000,
    7_200_000,
    21_600_000,
    86_400_000
  ]

  # Five or six labels at a round step.
  defp ticks(%{timed?: true, x0: x0, x1: x1} = clock) do
    span = x1 - x0
    step = Enum.find(@tick_steps, List.last(@tick_steps), &(span / &1 <= 6))

    for t <- 0..div(span, step), do: %{x: pct(clock, x0 + t * step), label: duration(t * step)}
  end

  defp ticks(%{timed?: false, x1: x1} = clock) do
    step = max(div(x1, 6), 1)
    for t <- 0..div(x1 - 1, step), do: %{x: pct(clock, t * step), label: "turn #{t * step + 1}"}
  end

  @doc "A duration in ms as the axis and the header show it: `45s`, `12m`, `2h 5m`."
  @spec duration(non_neg_integer() | nil) :: String.t()
  def duration(nil), do: "—"
  def duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  def duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"

  def duration(ms) do
    h = div(ms, 3_600_000)
    m = div(rem(ms, 3_600_000), 60_000)
    if m == 0, do: "#{h}h", else: "#{h}h #{m}m"
  end

  @doc "A duration with seconds to one decimal under a minute: `2.4s`, `3m`."
  @spec duration_precise(non_neg_integer()) :: String.t()
  def duration_precise(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  def duration_precise(ms), do: duration(ms)

  @doc "A count as `950`, `12.3k` or `1.8M`."
  @spec compact(integer()) :: String.t()
  def compact(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def compact(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  def compact(n), do: to_string(n)

  @doc false
  def excerpt(text, max) when is_binary(text) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  def excerpt(_text, _max), do: ""
end
