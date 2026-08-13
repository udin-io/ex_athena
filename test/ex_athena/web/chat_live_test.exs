defmodule ExAthena.Web.Live.ChatLiveTest do
  use ExUnit.Case, async: true

  alias ExAthena.Orchestrator.AgentInfo
  alias ExAthena.Result
  alias ExAthena.Web.Live.ChatLive

  describe "maybe_surface_deliverable/4 — showing the finish answer in chat" do
    test "prepends the deliverable as an assistant-text item when not streamed" do
      result = %Result{finish_reason: :submitted, deliverable: "the final answer"}

      assert [entry | []] = ChatLive.maybe_surface_deliverable([], "m1", "", result)
      assert entry.type == :assistant_text
      assert entry.message_id == "m1"
      assert entry.payload == %{text: "the final answer"}
    end

    test "appears as the newest entry (rendered last, after tool rows)" do
      existing = [%{type: :tool_call, message_id: "m1", payload: %{}}]
      result = %Result{finish_reason: :submitted, deliverable: "answer"}

      assert [newest | rest] = ChatLive.maybe_surface_deliverable(existing, "m1", "", result)
      assert newest.type == :assistant_text
      assert rest == existing
    end

    test "is a no-op when the deliverable was already streamed as prose" do
      result = %Result{finish_reason: :submitted, deliverable: "answer"}
      assert ChatLive.maybe_surface_deliverable([], "m1", "here is the answer", result) == []
    end

    test "is a no-op when an assistant-text entry already contains it" do
      stream = [%{type: :assistant_text, message_id: "m1", payload: %{text: "the answer here"}}]
      result = %Result{finish_reason: :submitted, deliverable: "answer"}
      assert ChatLive.maybe_surface_deliverable(stream, "m1", "", result) == stream
    end

    test "is a no-op for non-submitted runs or a blank deliverable" do
      assert ChatLive.maybe_surface_deliverable([], "m1", "", %Result{finish_reason: :stop}) == []

      assert ChatLive.maybe_surface_deliverable(
               [],
               "m1",
               "",
               %Result{finish_reason: :submitted, deliverable: nil}
             ) == []
    end
  end

  describe "orphan_agents/1 — top-level workers not linked to a todo" do
    test "treats an agent with a nil linked_todo as an orphan (no crash)" do
      orchestrator = %{
        main: %{todos: [%{content: "task A"}]},
        agents: [%AgentInfo{id: "a1", parent_id: :main, linked_todo: nil}]
      }

      assert [%AgentInfo{id: "a1"}] = ChatLive.orphan_agents(orchestrator)
    end

    test "excludes agents whose linked_todo matches an existing todo" do
      orchestrator = %{
        main: %{todos: [%{content: "task A"}]},
        agents: [
          %AgentInfo{id: "linked", parent_id: :main, linked_todo: "task A"},
          %AgentInfo{id: "stale", parent_id: :main, linked_todo: "gone"}
        ]
      }

      assert [%AgentInfo{id: "stale"}] = ChatLive.orphan_agents(orchestrator)
    end

    test "excludes nested agents (parent_id is not :main)" do
      orchestrator = %{
        main: %{todos: []},
        agents: [%AgentInfo{id: "child", parent_id: "a1", linked_todo: nil}]
      }

      assert ChatLive.orphan_agents(orchestrator) == []
    end
  end

  describe "model picker selection (handle_event)" do
    defp picker_socket(overrides) do
      assigns =
        Map.merge(
          %{__changed__: %{}, model: "bge-m3:latest", model_query: "", model_open: true},
          Map.new(overrides)
        )

      %Phoenix.LiveView.Socket{assigns: assigns}
    end

    test "closing the dropdown commits a free-typed model name" do
      socket = picker_socket(model_query: "glm-5.2-cloud")

      assert {:noreply, socket} = ChatLive.handle_event("close_models", %{}, socket)
      assert socket.assigns.model == "glm-5.2-cloud"
      assert socket.assigns.model_query == ""
      assert socket.assigns.model_open == false
    end

    test "closing with a blank query keeps the current model" do
      socket = picker_socket(model_query: "   ")

      assert {:noreply, socket} = ChatLive.handle_event("close_models", %{}, socket)
      assert socket.assigns.model == "bge-m3:latest"
      assert socket.assigns.model_open == false
    end

    test "Enter/submit commits the typed value" do
      socket = picker_socket(model_query: "gpt-oss:120b-cloud")

      assert {:noreply, socket} =
               ChatLive.handle_event("set_model", %{"value" => "gpt-oss:120b-cloud"}, socket)

      assert socket.assigns.model == "gpt-oss:120b-cloud"
      assert socket.assigns.model_open == false
    end

    test "clicking an option commits that model" do
      socket = picker_socket(model_query: "gl")

      assert {:noreply, socket} =
               ChatLive.handle_event("set_model", %{"model" => "glm-5.2-cloud"}, socket)

      assert socket.assigns.model == "glm-5.2-cloud"
    end

    test "set_model ignores a blank value (never wipes the current model)" do
      socket = picker_socket(model: "llama3.1")

      assert {:noreply, socket} = ChatLive.handle_event("set_model", %{"value" => "  "}, socket)
      assert socket.assigns.model == "llama3.1"
    end
  end

  describe "filter_models/2 — model search box" do
    @models [
      "mlx-community/Qwen3.5-9B-4bit",
      "mlx-community/Qwen3.6-27B-4bit",
      "mlx-community/gemma-4-e4b-it-4bit",
      "anthropic/claude-3.5-sonnet"
    ]

    test "case-insensitive substring match (anywhere in the id)" do
      assert ChatLive.filter_models(@models, "qwen3.5") == ["mlx-community/Qwen3.5-9B-4bit"]
      # matches the part after the slash, which datalist prefix-matching misses
      assert ChatLive.filter_models(@models, "sonnet") == ["anthropic/claude-3.5-sonnet"]
      assert "mlx-community/gemma-4-e4b-it-4bit" in ChatLive.filter_models(@models, "GEMMA")
    end

    test "blank query returns all (capped); no match returns []" do
      assert ChatLive.filter_models(@models, "") == @models
      assert ChatLive.filter_models(@models, "   ") == @models
      assert ChatLive.filter_models(@models, "nope") == []
    end

    test "caps the result count" do
      many = for i <- 1..200, do: "openrouter/model-#{i}"
      assert length(ChatLive.filter_models(many, "model")) == 60
    end
  end

  # Events were rendered only by `handle_info`, so a LiveView that reconnected
  # mid-run could never rebuild the window it missed. Replay needs the SAME
  # transformation as live delivery, or the two paths drift and a replayed
  # transcript stops matching a live one.
  describe "apply_event/2 — one path for live and replayed events" do
    defp socket(overrides \\ %{}) do
      assigns =
        Map.merge(
          %{
            __changed__: %{},
            details_stream: [],
            stream_events: [],
            stream_tool_ui: %{},
            stream_text: "",
            current_action: nil,
            error: nil,
            cwd: "/tmp",
            pending_assistant_msg_id: "m1"
          },
          overrides
        )

      %Phoenix.LiveView.Socket{assigns: assigns}
    end

    defp types(socket), do: Enum.map(socket.assigns.details_stream, & &1.type)

    test "folds a run's events into the same stream live delivery would build" do
      events = [
        {:iteration, 1},
        {:subagent_spawn, %{id: "sub_a", prompt: "explore"}},
        {:subagent_result, %{id: "sub_a", text: "found it"}},
        {:iteration, 2}
      ]

      result = Enum.reduce(events, socket(), &ChatLive.apply_event(&2, &1))

      # details_stream is newest-first, so the fold reverses wire order.
      assert types(result) == [:iteration, :subagent_result, :subagent_spawn, :iteration]
    end

    test "replaying an event sequence equals having received it live" do
      events = [
        {:iteration, 1},
        {:tool_call, %{id: "c1", name: "read", arguments: %{}}},
        {:usage, %{input_tokens: 5}}
      ]

      replayed = Enum.reduce(events, socket(), &ChatLive.apply_event(&2, &1))

      live =
        Enum.reduce(events, socket(), fn ev, s ->
          {:noreply, s} = ChatLive.handle_info({:athena, ev}, s)
          s
        end)

      # Each detail carries a freshly generated id, so compare what renders.
      strip = &Enum.map(&1, fn d -> Map.drop(d, [:id]) end)

      assert strip.(replayed.assigns.details_stream) == strip.(live.assigns.details_stream)
      assert replayed.assigns.stream_events == live.assigns.stream_events
    end

    test "an unknown event is ignored rather than crashing the view" do
      result = ChatLive.apply_event(socket(), {:something_new, %{}})
      assert result.assigns.details_stream == []
    end
  end

  # The sidebar list was only ever built by `open_cwd` (picking a directory)
  # and `toggle_sessions` (clicking to expand). Opening a session by URL — or
  # reloading the page on one — took neither path, so `sessions` stayed at its
  # mount default of `[]` and the sidebar rendered empty. A run started in
  # another tab could never appear either.
  describe "assign_session_list/2 — populating the sidebar" do
    defp bare_socket do
      %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, sessions: [], show_sessions: false}
      }
    end

    test "builds the list for the loaded session's cwd" do
      result =
        ChatLive.assign_session_list(bare_socket(), fn _cwd -> [%{id: "a"}, %{id: "b"}] end)

      assert Enum.map(result.assigns.sessions, & &1.id) == ["a", "b"]
      assert result.assigns.show_sessions
    end

    test "stays hidden when the directory has no sessions" do
      result = ChatLive.assign_session_list(bare_socket(), fn _cwd -> [] end)

      assert result.assigns.sessions == []
      refute result.assigns.show_sessions
    end

    # Refreshing must not collapse a list the user has open, nor force one
    # open that they deliberately closed.
    test "a refresh keeps the panel's current visibility" do
      closed = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, sessions: [%{id: "a"}], show_sessions: false}
      }

      result = ChatLive.assign_session_list(closed, fn _ -> [%{id: "a"}, %{id: "b"}] end, :keep)

      assert length(result.assigns.sessions) == 2
      refute result.assigns.show_sessions
    end
  end

  # The assistant message was only appended when a run COMPLETED, but its
  # details are stamped with that message's id from the first event onward.
  # A run that was killed, crashed, or is still in flight therefore left its
  # details parented to a message that did not exist — `message_items/2`
  # matches on message_id, so 118 saved entries rendered as a blank screen.
  describe "restore_open_turn/1 — a run that never finished" do
    defp saved(messages, details) do
      %{
        display_messages: messages,
        details_stream: details,
        tool_uis: %{}
      }
    end

    defp user_msg(id), do: %{id: id, role: :user, text: "do the thing", tool_events: []}

    defp orphan(msg_id, type),
      do: %{id: "d-#{type}", type: type, message_id: msg_id, payload: %{}}

    test "reopens the turn so its details have a parent to render under" do
      data =
        saved([user_msg("u1")], [
          orphan("a1", :subagent_result),
          orphan("a1", :subagent_spawn),
          %{id: "d0", type: :user_text, message_id: "u1", payload: %{}}
        ])

      restored = ChatLive.restore_open_turn(data)

      assert [%{id: "u1"}, %{id: "a1", role: :assistant}] = restored.display_messages
    end

    test "carries the streamed text so the partial answer is not lost" do
      data =
        saved([user_msg("u1")], [
          %{id: "d2", type: :assistant_text, message_id: "a1", payload: %{text: " so far"}},
          %{id: "d1", type: :assistant_text, message_id: "a1", payload: %{text: "the answer"}}
        ])

      restored = ChatLive.restore_open_turn(data)

      assert %{id: "a1", text: text} = List.last(restored.display_messages)
      assert text =~ "the answer"
      assert text =~ "so far"
    end

    test "a completed run is left exactly as saved" do
      msgs = [user_msg("u1"), %{id: "a1", role: :assistant, text: "done", tool_events: []}]
      data = saved(msgs, [orphan("a1", :iteration)])

      assert ChatLive.restore_open_turn(data).display_messages == msgs
    end

    test "a session with no orphaned details is untouched" do
      data =
        saved([user_msg("u1")], [%{id: "d0", type: :user_text, message_id: "u1", payload: %{}}])

      assert ChatLive.restore_open_turn(data).display_messages == [user_msg("u1")]
    end

    test "reopens only the newest interrupted turn, not every historical one" do
      msgs = [user_msg("u1"), %{id: "a1", role: :assistant, text: "done", tool_events: []}]

      data =
        saved(msgs, [
          orphan("a2", :iteration),
          orphan("a1", :iteration)
        ])

      restored = ChatLive.restore_open_turn(data)

      assert Enum.map(restored.display_messages, & &1.id) == ["u1", "a1", "a2"]
    end
  end

  # Reopening an interrupted turn puts a placeholder assistant message in the
  # list. If the run then COMPLETES (reloaded mid-run, not killed), appending
  # the real message would leave two entries sharing an id — a duplicate DOM
  # id, which LiveView raises on.
  describe "upsert_message/2" do
    test "replaces a placeholder in place rather than appending a duplicate" do
      existing = [
        %{id: "u1", role: :user, text: "ask"},
        %{id: "a1", role: :assistant, text: "partial"}
      ]

      result = ChatLive.upsert_message(existing, %{id: "a1", role: :assistant, text: "final"})

      assert Enum.map(result, & &1.id) == ["u1", "a1"]
      assert List.last(result).text == "final"
    end

    test "appends when the message is new" do
      existing = [%{id: "u1", role: :user, text: "ask"}]

      result = ChatLive.upsert_message(existing, %{id: "a1", role: :assistant, text: "answer"})

      assert Enum.map(result, & &1.id) == ["u1", "a1"]
    end
  end

  # The Overview tab is fed by the Coordinator, which lives only in memory,
  # and the LiveView only re-subscribes to it while a run is still attachable.
  # Once the run ended — or the server restarted — reloading the page showed a
  # blank Overview, even though the session had the whole run on disk.
  # Per-agent tokens are tracked on AgentInfo and rendered per row, but
  # nothing aggregated them — answering "how much did the orchestrator use vs
  # the workers?" meant adding up rows by hand.
  # While a worker runs — often for many minutes — the main view said only
  # "running spawn_agent…". What the worker was actually doing existed on
  # AgentInfo, but only the Overview tab showed it, so following a run meant
  # switching tabs or reading the log.
  describe "active_worker_action/1" do
    defp worker(id, opts) do
      %AgentInfo{
        id: id,
        name: opts[:name],
        status: opts[:status] || :running,
        depth: opts[:depth] || 1,
        current_action: opts[:action],
        iteration: opts[:iteration] || 0
      }
    end

    test "names the running worker and what it is doing" do
      snapshot = %{
        main: %AgentInfo{id: :main},
        agents: [worker("a1", name: "implementer", action: "running edit…", iteration: 3)]
      }

      assert ChatLive.active_worker_action(snapshot) == "implementer · running edit… (iter 3)"
    end

    # A nested subagent is the thing actually working; its parent is just
    # waiting on it, so the deepest running agent is the informative one.
    test "prefers the deepest running agent" do
      snapshot = %{
        main: %AgentInfo{id: :main},
        agents: [
          worker("a1", name: "implementer", action: "running spawn_agent…", depth: 1),
          worker("a2", name: "explore", action: "running grep…", depth: 2)
        ]
      }

      assert ChatLive.active_worker_action(snapshot) =~ "explore · running grep…"
    end

    test "ignores agents that have finished" do
      snapshot = %{
        main: %AgentInfo{id: :main},
        agents: [worker("a1", name: "implementer", action: "running edit…", status: :done)]
      }

      assert ChatLive.active_worker_action(snapshot) == nil
    end

    test "falls back to the worker's name when it has no action yet" do
      snapshot = %{main: %AgentInfo{id: :main}, agents: [worker("a1", name: "explore")]}

      assert ChatLive.active_worker_action(snapshot) == "explore · starting… (iter 0)"
    end

    test "returns nil with no snapshot or no workers" do
      assert ChatLive.active_worker_action(nil) == nil
      assert ChatLive.active_worker_action(%{main: %AgentInfo{id: :main}, agents: []}) == nil
    end
  end

  describe "token_summary/1" do
    defp agent(id, input, output) do
      %AgentInfo{id: id, usage: %{input_tokens: input, output_tokens: output}}
    end

    test "splits the orchestrator's own usage from its workers'" do
      snapshot = %{
        main: agent(:main, 30_000, 4_000),
        agents: [agent("a1", 100_000, 8_000), agent("a2", 50_000, 2_000)]
      }

      assert %{
               orchestrator: %{input_tokens: 30_000, output_tokens: 4_000},
               workers: %{input_tokens: 150_000, output_tokens: 10_000},
               agent_count: 2
             } = ChatLive.token_summary(snapshot)
    end

    test "counts nested subagents alongside top-level workers" do
      snapshot = %{
        main: agent(:main, 10, 1),
        agents: [
          %AgentInfo{id: "a1", parent_id: :main, usage: %{input_tokens: 5, output_tokens: 1}},
          %AgentInfo{id: "a2", parent_id: "a1", usage: %{input_tokens: 7, output_tokens: 2}}
        ]
      }

      assert %{workers: %{input_tokens: 12, output_tokens: 3}, agent_count: 2} =
               ChatLive.token_summary(snapshot)
    end

    test "handles a run with no workers yet" do
      assert %{workers: %{input_tokens: 0, output_tokens: 0}, agent_count: 0} =
               ChatLive.token_summary(%{main: agent(:main, 5, 1), agents: []})
    end

    # Sessions saved before the snapshot was persisted have none.
    test "returns nil when there is no snapshot" do
      assert ChatLive.token_summary(nil) == nil
    end

    test "renders large counts compactly" do
      assert ChatLive.fmt_tokens(%{input_tokens: 1_500_000, output_tokens: 32_000}) ==
               "1.5M/32.0k tok"

      assert ChatLive.fmt_tokens(%{input_tokens: 950, output_tokens: 0}) == "950/0 tok"
    end
  end

  describe "orchestrator snapshot persistence" do
    defp payload_assigns(overrides \\ %{}) do
      Map.merge(
        %{
          session_id: "s1",
          session_title: "t",
          cwd: "/tmp",
          provider: "ollama",
          model: "m",
          mode: "orchestrate",
          session_created_at: ~U[2026-08-11 10:00:00Z],
          messages: [],
          ex_messages: [],
          provider_session_id: nil,
          tool_uis: %{},
          details_stream: [],
          orchestrator: nil
        },
        overrides
      )
    end

    test "the saved payload carries the orchestrator snapshot" do
      snapshot = %{main: %{todos: [%{content: "a", status: :completed}]}, agents: []}

      payload = ChatLive.session_payload(payload_assigns(%{orchestrator: snapshot}))

      assert payload.orchestrator == snapshot
    end

    test "still carries everything it carried before" do
      payload = ChatLive.session_payload(payload_assigns())

      for key <- [
            :id,
            :title,
            :cwd,
            :provider,
            :model,
            :mode,
            :created_at,
            :updated_at,
            :display_messages,
            :ex_messages,
            :provider_session_id,
            :tool_uis,
            :details_stream
          ] do
        assert Map.has_key?(payload, key), "payload lost #{key}"
      end
    end

    test "survives a real save/load round-trip" do
      snapshot = %{main: %{todos: [%{content: "a", status: :completed}]}, agents: []}
      id = "roundtrip-#{System.unique_integer([:positive])}"

      payload =
        ChatLive.session_payload(payload_assigns(%{session_id: id, orchestrator: snapshot}))

      :ok = ExAthena.Web.Sessions.save(payload)
      on_exit(fn -> ExAthena.Web.Sessions.delete(id) end)

      assert {:ok, loaded} = ExAthena.Web.Sessions.load(id)
      assert loaded.orchestrator == snapshot
    end

    # A session saved before this field existed must still load.
    test "a session with no stored snapshot loads as nil" do
      assert ChatLive.stored_orchestrator(%{display_messages: []}) == nil
      assert ChatLive.stored_orchestrator(%{orchestrator: nil}) == nil
    end

    test "a stored snapshot is what gets restored" do
      snapshot = %{main: %{todos: []}, agents: []}
      assert ChatLive.stored_orchestrator(%{orchestrator: snapshot}) == snapshot
    end
  end

  describe "replay_run_events/2 — rebuilding a run after reconnect" do
    defp detail(type, msg_id), do: %{id: "d#{type}", type: type, message_id: msg_id, payload: %{}}

    defp reattach(stream, events, msg_id) do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          details_stream: stream,
          stream_events: [],
          stream_tool_ui: %{},
          stream_text: "",
          current_action: nil,
          error: nil,
          cwd: "/tmp",
          pending_assistant_msg_id: msg_id
        }
      }

      ChatLive.replay_run_events(socket, %{events: events, pending_assistant_msg_id: msg_id})
    end

    test "fills the gap left by a disconnect" do
      partial = [detail(:iteration, "m1")]
      events = [{:iteration, 1}, {:subagent_spawn, %{id: "a"}}, {:subagent_result, %{id: "a"}}]

      result = reattach(partial, events, "m1")

      assert Enum.map(result.assigns.details_stream, & &1.type) ==
               [:subagent_result, :subagent_spawn, :iteration]
    end

    # A flapping connection reattaches repeatedly; each must converge on the
    # same view rather than stacking duplicate rows.
    test "is idempotent across repeated reattaches" do
      events = [{:iteration, 1}, {:subagent_spawn, %{id: "a"}}]

      once = reattach([], events, "m1")
      twice = reattach(once.assigns.details_stream, events, "m1")

      assert Enum.map(once.assigns.details_stream, & &1.type) ==
               Enum.map(twice.assigns.details_stream, & &1.type)
    end

    test "leaves earlier turns untouched" do
      earlier = [detail(:tool_call, "m0"), detail(:iteration, "m0")]

      result = reattach(earlier, [{:iteration, 1}], "m1")

      assert Enum.filter(result.assigns.details_stream, &(&1.message_id == "m0")) == earlier
    end

    # The interleaving IS the content: "it thought THIS, then ran THAT". An
    # earlier version kept the restored text entries and prepended rebuilt
    # structural ones, which bunched every thinking blob at one end and every
    # tool row at the other — a transcript that never happened.
    test "rebuilds thinking and tool rows interleaved, not bunched" do
      restored = [detail(:thinking, "m1")]

      events = [
        {:thinking, "let me look"},
        {:tool_call, %{id: "c1", name: "read", arguments: %{}}},
        {:thinking, "now I see"},
        {:tool_call, %{id: "c2", name: "edit", arguments: %{}}}
      ]

      result = reattach(restored, events, "m1")

      # newest-first, so reverse to read in the order it happened
      assert result.assigns.details_stream
             |> Enum.reverse()
             |> Enum.map(& &1.type) == [:thinking, :tool_call, :thinking, :tool_call]
    end

    test "rebuilds the streamed answer rather than doubling it" do
      restored = [
        %{id: "d1", type: :assistant_text, message_id: "m1", payload: %{text: "the answer"}}
      ]

      result = reattach(restored, [{:content, "the answer"}], "m1")

      texts =
        result.assigns.details_stream
        |> Enum.filter(&(&1.type == :assistant_text))
        |> Enum.map(& &1.payload.text)

      assert texts == ["the answer"]
      assert result.assigns.stream_text == "the answer"
    end

    test "an empty history leaves the restored stream alone" do
      restored = [detail(:tool_call, "m1")]
      assert reattach(restored, [], "m1").assigns.details_stream == restored
    end
  end

  # A session used to be written exactly twice — at run start and at run
  # completion — so a run in flight showed nothing on disk for its whole
  # duration. The autosave tick fixes that, and this signature is what keeps
  # an idle tick from rewriting an unchanged (up to 750 KB) session file.
  describe "session_signature/1 — autosave change detection" do
    defp assigns(overrides \\ %{}) do
      Map.merge(
        %{messages: [], details_stream: [], tool_uis: %{}, session_title: nil},
        overrides
      )
    end

    test "is stable when nothing persisted has changed" do
      a = assigns(%{details_stream: [%{type: :tool_call, payload: %{name: "read"}}]})
      assert ChatLive.session_signature(a) == ChatLive.session_signature(a)
    end

    test "changes when a tool call is appended to the details stream" do
      before = assigns()
      after_call = assigns(%{details_stream: [%{type: :tool_call, payload: %{name: "grep"}}]})

      refute ChatLive.session_signature(before) == ChatLive.session_signature(after_call)
    end

    # Content/thinking deltas EXTEND an existing entry rather than prepending a
    # new one, so a length-based check would miss a streaming answer entirely.
    test "changes when a text delta extends an existing details entry" do
      before = assigns(%{details_stream: [%{type: :assistant_text, payload: %{text: "Look"}}]})

      after_delta =
        assigns(%{details_stream: [%{type: :assistant_text, payload: %{text: "Looking at"}}]})

      refute ChatLive.session_signature(before) == ChatLive.session_signature(after_delta)
    end

    test "changes when a message is appended" do
      before = assigns()
      after_msg = assigns(%{messages: [%{id: "m1", role: :assistant, text: "hi"}]})

      refute ChatLive.session_signature(before) == ChatLive.session_signature(after_msg)
    end

    # The Overview is persisted now, so a turn whose only visible change is
    # orchestrator state (a todo flipping to completed, a worker finishing)
    # must still trigger the autosave write.
    test "changes when the orchestrator snapshot advances" do
      before = assigns(%{orchestrator: %{main: %{todos: [%{content: "a", status: :pending}]}}})
      after_ = assigns(%{orchestrator: %{main: %{todos: [%{content: "a", status: :completed}]}}})

      refute ChatLive.session_signature(before) == ChatLive.session_signature(after_)
    end

    test "changes when the title or a tool UI lands" do
      refute ChatLive.session_signature(assigns()) ==
               ChatLive.session_signature(assigns(%{session_title: "Add a doctor filter"}))

      refute ChatLive.session_signature(assigns()) ==
               ChatLive.session_signature(assigns(%{tool_uis: %{"c1" => %{kind: :diff}}}))
    end
  end
end
