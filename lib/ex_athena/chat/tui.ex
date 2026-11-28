# The TUI requires the OPTIONAL `:ex_ratatui` dependency. Guard the whole
# module so ExAthena still compiles for consumers that don't pull ex_ratatui
# (declared `optional: true`). Without this, `use ExRatatui.App` raises
# `module ExRatatui.App is not loaded` at compile time for every such consumer.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule ExAthena.Chat.Tui do
    @moduledoc """
    Full-screen TUI App for `mix athena.chat`, built on `ExRatatui.App`.

    Layout (see `ExAthena.Chat.Tui.View`):

      * Header (1 row) — provider · model · permission · iter · tokens · cost.
      * Messages (flex) — scrollback rendered from `state.events`.
      * Input (3 rows) — multiline textarea bound to `state.input_ref`.
      * Footer (1 row) — keyboard hints.

    When the user types a `/model` or `/permissions` command with no arg, a modal
    `Popup` overlays the messages area with a navigable list. Streaming
    tokens accumulate in `state.stream_buffer` and flush into the most
    recent assistant row every ~60 ms (`@tick_interval_ms`) so a fast
    stream doesn't redraw the whole frame per token.

    The LLM run lives in an unsupervised `Task` owned by
    `ExAthena.Chat.Tui.Runner` — see that module for the bridging
    contract. The App receives `:athena_event`, `:athena_done`, and
    `:athena_error` messages via `handle_info/2`.
    """

    use ExRatatui.App

    alias ExAthena.Chat.{Commands, Permission, Session}
    alias ExAthena.Chats
    alias ExAthena.Chat.Tui.{Runner, State, View}
    alias ExAthena.Tools
    alias ExRatatui.Event
    alias ExRatatui.Frame

    @tick_interval_ms 60
    # Rows per PgUp/PgDn press. Roughly a half-page on a typical terminal —
    # comfortable for skimming without overshooting.
    @page_step 10
    # Rows per mouse-wheel click.
    @wheel_step 3

    @doc """
    Start the chat App and block until the user quits.

    Mirrors `ExAthena.Chat.Repl.start/1` so the Mix task signature is unchanged.
    """
    @spec start(keyword()) :: :ok
    def start(opts \\ []) do
      suspend_beam_stdin_reader()

      {:ok, pid} = start_link(opts)

      # ex_ratatui's NIF enables crossterm raw mode + alternate screen but
      # does NOT toggle mouse capture, so wheel/click events never reach us.
      # Enable X10 mouse reporting + SGR-extended mode (unlimited coords)
      # ourselves via ANSI. We bypass :standard_io and write to /dev/tty
      # directly because suspend_beam_stdin_reader/0 above tears down
      # BEAM's I/O subsystem — IO.write/2 to :standard_io would raise
      # :terminated.
      write_to_tty("\e[?1000h\e[?1006h")

      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          write_to_tty("\e[?1006l\e[?1000l")
          :ok
      end
    end

    defp write_to_tty(bytes) do
      case File.open("/dev/tty", [:write, :raw]) do
        {:ok, dev} ->
          try do
            IO.binwrite(dev, bytes)
          after
            File.close(dev)
          end

        _ ->
          :ok
      end
    end

    # BEAM's `:user_drv_reader` polls stdin in a tight loop. When the ex_ratatui
    # NIF tries to read raw keystrokes via crossterm, they race for fd 0 and
    # roughly half the bytes get consumed by BEAM and discarded. The canonical
    # fix is to launch with `-noinput`, but we can also stop the reader at
    # runtime from the Mix task path — equivalent effect, transparent to users.
    # See https://elixirforum.com/t/61856 for the original diagnosis.
    defp suspend_beam_stdin_reader do
      case Process.whereis(:user_drv_reader) do
        nil -> :ok
        pid -> Process.exit(pid, :kill)
      end
    end

    # ── App callbacks ────────────────────────────────────────────────────────

    @impl true
    def mount(opts) do
      prior_log_level = Logger.level()
      Logger.configure(level: :warning)

      state =
        opts
        |> build_state()
        |> Map.put(:input_ref, ExRatatui.textarea_new())
        |> Map.put(:prior_log_level, prior_log_level)
        |> maybe_kick_git_diff()

      schedule_tick()

      {:ok, state}
    end

    @doc """
    The App's first state for `opts`, without the input box. With `resume:
    id`, it opens that saved chat and shows its messages; a chat that cannot
    be opened starts a new one, with a line saying why.
    """
    @spec build_state(keyword()) :: State.t()
    def build_state(opts) do
      {resume, opts} = Keyword.pop(opts, :resume)

      case open_saved(resume, opts) do
        {:ok, session} ->
          session
          |> reconcile_initial_session()
          |> State.new()
          |> banner_events()
          |> replay_chat()

        {:error, reason} ->
          opts
          |> Session.new()
          |> reconcile_initial_session()
          |> State.new()
          |> banner_events()
          |> State.append_event(
            {:warning, "Could not open chat #{resume}: #{describe(reason)}. Started a new one."}
          )

        :new ->
          opts |> Session.new() |> reconcile_initial_session() |> State.new() |> banner_events()
      end
    end

    defp open_saved(nil, _opts), do: :new
    defp open_saved(id, opts), do: Session.open(id, opts)

    @impl true
    def render(%State{} = state, %Frame{} = frame), do: View.build_frame(state, frame)

    # ── Keyboard handling ────────────────────────────────────────────────────

    @impl true
    def handle_event(%Event.Key{kind: "press"} = key, %State{popup: nil} = state) do
      handle_key(key, state)
    end

    def handle_event(%Event.Key{kind: "press"} = key, %State{popup: _} = state) do
      handle_popup_key(key, state)
    end

    # Mouse wheel: scroll the pane under the cursor by @wheel_step rows.
    def handle_event(%ExRatatui.Event.Mouse{kind: "scroll_up", x: x, y: y}, state) do
      {:noreply, scroll_pane_at(state, x, y, -@wheel_step)}
    end

    def handle_event(%ExRatatui.Event.Mouse{kind: "scroll_down", x: x, y: y}, state) do
      {:noreply, scroll_pane_at(state, x, y, +@wheel_step)}
    end

    # Left-click on a details tab title → switch tabs.
    def handle_event(
          %ExRatatui.Event.Mouse{kind: "down", button: "left", x: x, y: y},
          state
        ) do
      {:noreply, maybe_click_tab(state, x, y)}
    end

    def handle_event(_event, state), do: {:noreply, state}

    # ── Mouse helpers ────────────────────────────────────────────────────

    defp scroll_pane_at(state, x, y, delta) do
      layout = Process.get(:tui_layout, %{})

      cond do
        in_rect?(layout[:messages], x, y) -> State.scroll_messages(state, delta)
        in_rect?(layout[:details], x, y) -> State.scroll_details(state, delta)
        true -> state
      end
    end

    defp maybe_click_tab(state, x, y) do
      layout = Process.get(:tui_layout, %{})

      if in_rect?(layout[:tabs], x, y) and is_list(layout[:tab_titles]) do
        tabs = State.details_tabs()
        # Approximate tab width: split available width evenly. ratatui's
        # Tabs widget aligns left and uses a divider; this is a "good
        # enough" hit-test that picks the closer tab.
        tabs_rect = layout[:tabs]
        offset = x - tabs_rect.x
        slot_width = max(div(tabs_rect.width, length(tabs)), 1)
        idx = min(div(offset, slot_width), length(tabs) - 1)
        target = Enum.at(tabs, max(idx, 0))

        State.set_details_tab(state, target)
      else
        state
      end
    end

    defp in_rect?(nil, _x, _y), do: false

    defp in_rect?(%{x: rx, y: ry, width: rw, height: rh}, x, y) do
      x >= rx and x < rx + rw and y >= ry and y < ry + rh
    end

    defp handle_key(%Event.Key{code: "c", modifiers: mods} = key, state) do
      if "ctrl" in mods do
        {:stop, state |> save_chat() |> restore_logger()}
      else
        forward_to_textarea(key, state)
      end
    end

    # ── Autocomplete navigation (only when the popup is open) ─────────────

    defp handle_key(%Event.Key{code: "up"}, %State{autocomplete: %{}} = state) do
      {:noreply, State.move_autocomplete(state, -1)}
    end

    defp handle_key(%Event.Key{code: "down"}, %State{autocomplete: %{}} = state) do
      {:noreply, State.move_autocomplete(state, +1)}
    end

    defp handle_key(%Event.Key{code: "esc"}, %State{autocomplete: %{}} = state) do
      {:noreply, State.close_autocomplete(state)}
    end

    # ── History navigation (Up/Down when no popup is open) ──────────────
    # First Up snapshots the current input as `history_draft`. Subsequent
    # Up steps further back; Down walks forward and ultimately restores
    # the draft. Typing anything resets the cursor (see forward_to_textarea).
    defp handle_key(%Event.Key{code: "up"}, state) do
      current = read_textarea(state)

      case State.history_prev(state, current) do
        {state, nil} -> {:noreply, state}
        {state, text} -> {:noreply, set_textarea(state, text)}
      end
    end

    defp handle_key(%Event.Key{code: "down"}, state) do
      case State.history_next(state) do
        {state, nil} -> {:noreply, state}
        {state, text} -> {:noreply, set_textarea(state, text)}
      end
    end

    # Tab or Enter accepts the highlighted suggestion: replace the textarea
    # contents with the selected verb (plus a trailing space so the user can
    # immediately type arguments) and close the popup. Picking from the menu
    # should complete the command text in the input box, not fire off the
    # half-typed prefix as a chat message.
    defp handle_key(%Event.Key{code: "tab"}, %State{autocomplete: %{}} = state) do
      {:noreply, accept_autocomplete(state)}
    end

    defp handle_key(%Event.Key{code: "tab"}, state), do: {:noreply, state}

    # ── Pane scrolling ────────────────────────────────────────────────────
    # PgUp/PgDn scroll the messages pane (left). Add Shift to target the
    # details pane (right). Home jumps to the very top; End returns to
    # auto-bottom so new content follows again.

    defp handle_key(%Event.Key{code: "pageup", modifiers: mods}, state) do
      if "shift" in mods,
        do: {:noreply, State.scroll_details(state, -@page_step)},
        else: {:noreply, State.scroll_messages(state, -@page_step)}
    end

    defp handle_key(%Event.Key{code: "pagedown", modifiers: mods}, state) do
      if "shift" in mods,
        do: {:noreply, State.scroll_details(state, +@page_step)},
        else: {:noreply, State.scroll_messages(state, +@page_step)}
    end

    defp handle_key(%Event.Key{code: "home", modifiers: mods}, state) do
      if "shift" in mods,
        do: {:noreply, State.scroll_details_top(state)},
        else: {:noreply, State.scroll_messages_top(state)}
    end

    defp handle_key(%Event.Key{code: "end"}, state) do
      {:noreply, State.reset_pane_scroll(state)}
    end

    defp handle_key(%Event.Key{code: "enter", modifiers: mods}, state) do
      cond do
        match?(%{}, state.autocomplete) and State.selected_autocomplete(state) != nil ->
          # Enter while the autocomplete popup is open with a selection:
          # accept the suggestion. User can press Enter again to submit.
          {:noreply, accept_autocomplete(state)}

        "shift" in mods ->
          # Shift+Enter inserts a newline into the textarea instead of submitting.
          if state.input_ref, do: ExRatatui.textarea_handle_key(state.input_ref, "enter", [])
          {:noreply, state}

        # While a turn runs, a message waits for the run's next turn
        # (issue 323); commands still wait for the run to end.
        state.loading? ->
          queue_message(state)

        true ->
          state |> State.close_autocomplete() |> submit_input()
      end
    end

    defp handle_key(%Event.Key{code: code} = key, state) when is_binary(code) do
      forward_to_textarea(key, state)
    end

    defp handle_key(_, state), do: {:noreply, state}

    defp accept_autocomplete(state) do
      case State.selected_autocomplete(state) do
        nil ->
          State.close_autocomplete(state)

        verb ->
          if state.input_ref do
            ExRatatui.textarea_set_value(state.input_ref, verb <> " ")
          end

          State.close_autocomplete(state)
      end
    end

    defp forward_to_textarea(%Event.Key{code: code, modifiers: mods}, state) do
      if state.input_ref do
        ExRatatui.textarea_handle_key(state.input_ref, code, mods)
      end

      # After the textarea processes the key, re-read its value and refresh
      # the autocomplete popup — opens it on `/`, filters it as the user
      # types more, closes it once whitespace appears. Also cancels any
      # in-progress history navigation (typing a fresh char means the user
      # is composing, not browsing prior messages).
      state =
        case state.input_ref do
          nil ->
            state

          ref ->
            state
            |> State.update_autocomplete(ExRatatui.textarea_get_value(ref))
            |> State.reset_history_nav()
        end

      {:noreply, state}
    end

    defp read_textarea(%State{input_ref: nil}), do: ""
    defp read_textarea(%State{input_ref: ref}), do: ExRatatui.textarea_get_value(ref) || ""

    defp set_textarea(%State{input_ref: nil} = state, _text), do: state

    defp set_textarea(%State{input_ref: ref} = state, text) do
      ExRatatui.textarea_set_value(ref, text || "")
      state
    end

    defp handle_popup_key(%Event.Key{code: code}, state) when code in ["up", "k"] do
      {:noreply, State.move_popup_selection(state, -1)}
    end

    defp handle_popup_key(%Event.Key{code: code}, state) when code in ["down", "j"] do
      {:noreply, State.move_popup_selection(state, +1)}
    end

    # Esc on a question answers it, or the run would wait forever: the chat
    # stays open, so nothing else would ever answer.
    defp handle_popup_key(%Event.Key{code: "esc"}, %State{popup: {{:question, q}, _, _}} = state) do
      if is_pid(q.reply_to), do: send(q.reply_to, {:athena_user_answer, q.tool_call_id, "Deny"})

      state
      |> State.close_popup()
      |> State.append_event({:info, "You answered: Deny"})
      |> State.next_question()
      |> noreply()
    end

    defp handle_popup_key(%Event.Key{code: "esc"}, state) do
      {:noreply, State.close_popup(state)}
    end

    defp handle_popup_key(%Event.Key{code: "enter"}, %State{popup: {:model, _, _}} = state) do
      case State.current_popup_selection(state) do
        nil ->
          {:noreply, State.close_popup(state)}

        model when is_binary(model) ->
          state
          |> State.set_model(model)
          |> State.close_popup()
          |> State.append_event({:info, "Model → " <> model})
          |> noreply()
      end
    end

    defp handle_popup_key(%Event.Key{code: "enter"}, %State{popup: {:permissions, _, _}} = state) do
      case State.current_popup_selection(state) do
        nil ->
          {:noreply, State.close_popup(state)}

        level when is_atom(level) ->
          state
          |> State.set_permission(level)
          |> State.close_popup()
          |> State.append_event({:info, "The chat may now: " <> Permission.label(level)})
          |> noreply()
      end
    end

    # A question from the run (ask_user, an approval): the answer goes to the
    # process that asked, and an approved plan moves the chat's level.
    defp handle_popup_key(
           %Event.Key{code: "enter"},
           %State{popup: {{:question, q}, _, _}} = state
         ) do
      answer = State.current_popup_selection(state)
      if is_pid(q.reply_to), do: send(q.reply_to, {:athena_user_answer, q.tool_call_id, answer})

      state
      |> State.close_popup()
      |> State.append_event({:info, "You answered: " <> to_string(answer)})
      |> follow_plan_approval(q, answer)
      |> State.next_question()
      |> noreply()
    end

    defp handle_popup_key(%Event.Key{code: "enter"}, %State{popup: {:resume, _, _}} = state) do
      case State.current_popup_selection(state) do
        nil -> {:noreply, State.close_popup(state)}
        id -> state |> State.close_popup() |> open_chat(id) |> noreply()
      end
    end

    defp handle_popup_key(%Event.Key{code: "enter"}, %State{popup: {:provider, _, _}} = state) do
      case State.current_popup_selection(state) do
        nil ->
          {:noreply, State.close_popup(state)}

        name when is_binary(name) ->
          provider_atom = provider_name_to_atom(name)

          state
          |> State.set_provider(provider_atom)
          |> State.close_popup()
          |> State.append_event({:info, "Provider → " <> name})
          |> append_provider_details(name)
          |> noreply()
      end
    end

    defp handle_popup_key(_, state), do: {:noreply, state}

    # ── Process messages ─────────────────────────────────────────────────────

    @impl true
    def handle_info(:tick, %State{} = state) do
      schedule_tick()
      {:noreply, State.flush_stream(state)}
    end

    def handle_info({:athena_event, event}, %State{} = state) do
      state = State.append_loop_event(state, event)

      # Kick off a fresh `git diff` whenever a tool result lands — that's
      # the point where the working tree may have changed. Bounded async,
      # never blocks the UI.
      state =
        case event do
          {:tool_result, _} -> maybe_kick_git_diff(state)
          _ -> state
        end

      {:noreply, state}
    end

    def handle_info({:athena_done, result}, %State{} = state) do
      new_state =
        state
        |> State.flush_stream()
        |> State.apply_result(result)
        |> State.set_loading(false)
        |> Map.put(:run_task, nil)
        |> hand_back_unsent()
        |> save_chat()
        |> append_status_row()
        |> maybe_kick_git_diff()

      {:noreply, new_state}
    end

    def handle_info({:git_diff, lines}, %State{} = state) when is_list(lines) do
      {:noreply, State.set_git_diff(state, lines)}
    end

    def handle_info({:athena_error, reason}, %State{} = state) do
      new_state =
        state
        |> State.flush_stream()
        |> State.set_loading(false)
        |> Map.put(:run_task, nil)
        |> hand_back_unsent()
        |> State.append_event({:error, "run error: " <> inspect(reason)})
        |> save_chat()

      {:noreply, new_state}
    end

    def handle_info({:athena_ask_user, %{question: question} = q}, %State{} = state) do
      options =
        case Map.get(q, :options, []) do
          [_ | _] = opts -> opts
          _ -> ["Yes", "No"]
        end

      state
      |> State.append_event({:info, "ExAthena is asking: " <> question})
      |> State.ask({Map.put_new(q, :reply_to, nil), options})
      |> noreply()
    end

    def handle_info(_msg, state), do: {:noreply, state}

    # Only a plan approval the runtime asked moves the level: a question the
    # model wrote can offer the same words.
    defp follow_plan_approval(state, %{kind: :plan_approval}, answer) do
      case Permission.level_after_approval(answer) do
        nil -> state
        level -> State.set_permission(state, level)
      end
    end

    defp follow_plan_approval(state, _question, _answer), do: state

    # ── Submission + commands ────────────────────────────────────────────────

    defp submit_input(%State{api_key_pending: true} = state) do
      raw = read_textarea(state) |> String.trim()
      if state.input_ref, do: ExRatatui.textarea_set_value(state.input_ref, "")

      cond do
        raw == "" ->
          append_and_noreply(
            state,
            {:warning, "API key cannot be empty. Enter it below (or /cancel to abort):"}
          )

        raw in ["/exit", "/quit"] ->
          {:stop, restore_logger(state)}

        raw == "/cancel" ->
          state
          |> Map.put(:api_key_pending, false)
          |> Map.put(:pending_message, nil)
          |> State.append_event({:info, "API key prompt cancelled."})
          |> noreply()

        true ->
          pending = state.pending_message

          state =
            state
            |> State.set_api_key(raw)
            |> Map.put(:pending_message, nil)
            |> State.append_event({:info, "API key saved for this session."})

          if pending, do: do_dispatch_message(pending, state), else: noreply(state)
      end
    end

    defp submit_input(%State{input_ref: nil} = state), do: {:noreply, state}

    defp submit_input(%State{input_ref: ref} = state) do
      raw = ExRatatui.textarea_get_value(ref)
      ExRatatui.textarea_set_value(ref, "")

      case Commands.parse(raw) do
        :noop ->
          {:noreply, state}

        :exit ->
          {:stop, restore_logger(state)}

        {:message, text} ->
          dispatch_message(text, state)

        {:command, verb, args} ->
          dispatch_command(verb, args, state)

        {:unknown, verb} ->
          append_and_noreply(state, {:warning, "Unknown command: /#{verb}. Try /help."})
      end
    end

    defp dispatch_message(text, %State{api_key_pending: false} = state) do
      case check_api_key_needed(state) do
        {:needs_key, provider_name, api_key_env} ->
          state
          |> State.append_event({:info, "Provider '#{provider_name}' requires an API key."})
          |> State.append_event({:info, "Env: #{api_key_env} (not set). Enter key below:"})
          |> Map.put(:api_key_pending, true)
          |> Map.put(:pending_message, text)
          |> noreply()

        :ok ->
          do_dispatch_message(text, state)
      end
    end

    # The App holds the chat for the turn, so a turn in the web UI (or another
    # terminal) on the same chat waits, and rewind and fork wait for this one.
    defp do_dispatch_message(text, state) do
      case Chats.hold(state.session.chat_id) do
        :ok ->
          state |> current_chat() |> then(&start_turn(text, &1))

        {:error, :busy} ->
          append_and_noreply(
            state,
            {:warning,
             "Another window is running a reply in this chat. Wait for it, then send again."}
          )

        {:error, reason} ->
          append_and_noreply(state, {:warning, "Could not start: " <> describe(reason)})
      end
    end

    # Holds the chat the turn will run in: a copy another window went on with
    # moves to a new chat first, and the hold moves with it.
    defp current_chat(state) do
      old = state.session.chat_id

      case Session.fork_if_moved(state.session) do
        {:moved, session} ->
          Chats.release(old)
          _ = Chats.hold(session.chat_id)

          State.append_event(
            %{state | session: session},
            {:warning,
             "This chat moved on in another window, so it goes on here as a new chat (#{session.chat_id})."}
          )

        _ ->
          state
      end
    end

    defp start_turn(text, state) do
      state =
        state
        |> State.append_event({:user, text})
        |> State.set_loading(true)
        |> State.reset_stream_state()
        |> State.reset_pane_scroll()
        |> State.reset_history_nav()
        |> update_in_session(&Session.append_user(&1, text))

      {:ok, inbox} = Agent.start_link(fn -> [] end)
      drain = fn -> Agent.get_and_update(inbox, &{&1, []}) end

      extra_opts =
        [inbox: drain] ++ if(state.api_key, do: [api_key: state.api_key], else: [])

      task_pid = Runner.start(state.session, self(), extra_opts)
      {:noreply, %{state | run_task: task_pid, inbox: inbox}}
    end

    defp queue_message(%State{input_ref: ref, inbox: inbox} = state) when is_pid(inbox) do
      text = ref |> ExRatatui.textarea_get_value() |> to_string() |> String.trim()

      cond do
        text == "" ->
          {:noreply, state}

        String.starts_with?(text, "/") ->
          append_and_noreply(state, {:warning, "Commands wait until the chat finishes."})

        true ->
          ExRatatui.textarea_set_value(ref, "")
          Agent.update(inbox, &(&1 ++ [text]))
          append_and_noreply(state, {:info, "Waiting for the chat to finish its step: " <> text})
      end
    end

    defp queue_message(state), do: {:noreply, state}

    # A message the run never took goes back into the box.
    defp hand_back_unsent(%State{inbox: inbox} = state) when is_pid(inbox) do
      unsent = Agent.get(inbox, & &1)
      Agent.stop(inbox)
      state = %{state | inbox: nil}

      if unsent == [] do
        state
      else
        if state.input_ref,
          do: ExRatatui.textarea_set_value(state.input_ref, Enum.join(unsent, "\n\n"))

        State.append_event(
          state,
          {:info, "Not sent before the chat stopped; it is back in the box."}
        )
      end
    end

    defp hand_back_unsent(state), do: state

    defp dispatch_command(:help, _args, state) do
      # Each event row renders as one line, so split the help text and append
      # one :info row per line (otherwise only the first line is visible).
      state =
        Commands.help_text()
        |> String.trim_trailing("\n")
        |> String.split("\n")
        |> Enum.reduce(state, fn line, s -> State.append_event(s, {:info, line}) end)

      {:noreply, state}
    end

    defp dispatch_command(:clear, _args, state) do
      {:noreply, State.clear_session(state)}
    end

    defp dispatch_command(:resume, [], state) do
      case Chats.list(cwd: session_cwd(state.session)) do
        [] ->
          append_and_noreply(state, {:info, "No saved chats for this folder yet."})

        chats ->
          items = Enum.map(chats, &{&1.id, resume_label(&1)})
          {:noreply, State.open_popup(state, {:resume, items})}
      end
    end

    defp dispatch_command(:resume, [id | _], state), do: state |> open_chat(id) |> noreply()

    defp dispatch_command(:fork, args, state) do
      with {:ok, steps} <- saved_steps(state),
           {:ok, step} <- pick_step(steps, args, :last),
           {:ok, fork} <- Chats.fork(state.session.chat_id, step: step.uuid) do
        state
        |> reopen_chat(fork.id)
        |> State.append_event({:info, "Forked into a new chat."})
        |> noreply()
      else
        {:error, reason} ->
          append_and_noreply(state, {:warning, "Could not fork: " <> describe(reason)})
      end
    end

    defp dispatch_command(:rewind, [], state) do
      case saved_steps(state) do
        {:ok, steps} ->
          state =
            steps
            |> Enum.with_index(1)
            |> Enum.reduce(
              State.append_event(state, {:info, "Steps (/rewind N goes back to step N):"}),
              fn {step, n}, s ->
                State.append_event(s, {:info, "  #{n}. #{step_line(step.message)}"})
              end
            )

          {:noreply, state}

        {:error, reason} ->
          append_and_noreply(state, {:warning, "Could not rewind: " <> describe(reason)})
      end
    end

    defp dispatch_command(:rewind, args, state) do
      with :ok <- idle(state),
           {:ok, steps} <- saved_steps(state),
           {:ok, step} <- pick_step(steps, args, nil),
           {:ok, result} <- Chats.rewind(state.session.chat_id, step.uuid) do
        state
        |> reopen_chat(state.session.chat_id)
        |> State.append_event(
          {:info, "Rewound to step #{hd(args)}; put back #{result.files_restored} file(s)."}
        )
        |> append_failed_files(result.files_failed)
        |> noreply()
      else
        {:error, reason} ->
          append_and_noreply(state, {:warning, "Could not rewind: " <> describe(reason)})
      end
    end

    defp dispatch_command(:tools, _args, state) do
      rows =
        Tools.builtins()
        |> Enum.map(fn mod -> {:info, "  - " <> inspect(mod)} end)

      state = State.append_event(state, {:info, "Tools available:"})
      state = Enum.reduce(rows, state, fn row, s -> State.append_event(s, row) end)
      {:noreply, state}
    end

    defp dispatch_command(:permissions, [], state) do
      {:noreply, State.open_popup(state, {:permissions, Permission.levels()})}
    end

    defp dispatch_command(:permissions, [arg | _], state) do
      if arg in Enum.map(Permission.levels(), &Atom.to_string/1) do
        level = Permission.parse(arg)

        state
        |> State.set_permission(level)
        |> State.append_event({:info, "The chat may now: " <> Permission.label(level)})
        |> noreply()
      else
        append_and_noreply(
          state,
          {:warning, "Unknown level: " <> arg <> ". Try read_only, ask, edit or trusted."}
        )
      end
    end

    defp dispatch_command(:model, [], state) do
      case list_models_for(state.session) do
        {:ok, []} ->
          append_and_noreply(state, {:warning, no_models_message(state.session.provider)})

        {:ok, models} ->
          {:noreply, State.open_popup(state, {:model, models})}

        {:error, reason}
        when reason in [:ollama_unreachable, :llamacpp_unreachable, :exo_unreachable] ->
          append_and_noreply(state, {:error, unreachable_message(state.session.provider)})

        {:error, reason} ->
          append_and_noreply(state, {:error, "Could not list models: " <> inspect(reason)})
      end
    end

    defp dispatch_command(:model, [arg | _], state) when is_binary(arg) do
      state
      |> State.set_model(arg)
      |> State.append_event({:info, "Model → " <> arg})
      |> noreply()
    end

    defp dispatch_command(:provider, [], state) do
      providers = ExAthena.Config.list_providers()
      items = Enum.map(providers, fn p -> {p.name, p.display_name} end)
      {:noreply, State.open_popup(state, {:provider, items})}
    end

    defp dispatch_command(:provider, [arg | _], state) when is_binary(arg) do
      provider = provider_name_to_atom(arg)

      state
      |> State.set_provider(provider)
      |> State.append_event({:info, "Provider → " <> arg})
      |> noreply()
    end

    defp dispatch_command(:slots, [], state) do
      slots = ExAthena.Config.request_queue_max_depth(state.session.provider)

      state
      |> State.append_event({:info, "#{state.session.provider} parallel slots: #{slots}"})
      |> noreply()
    end

    defp dispatch_command(:slots, [arg | _], state) do
      case Integer.parse(arg) do
        {n, ""} when n > 0 ->
          :ok = ExAthena.Config.set_request_queue_max_depth(state.session.provider, n)

          state
          |> State.append_event({:info, "#{state.session.provider} parallel slots → #{n}"})
          |> noreply()

        _ ->
          state
          |> State.append_event({:error, "usage: /slots N (positive integer)"})
          |> noreply()
      end
    end

    defp dispatch_command(:tab, _args, state) do
      state = State.cycle_details_tab(state)
      label = state.details_tab |> Atom.to_string() |> String.capitalize()
      state = maybe_kick_git_diff(state)

      state
      |> State.append_event({:info, "details tab → " <> label})
      |> noreply()
    end

    defp dispatch_command(:mouse, args, state) do
      requested =
        case args |> Enum.map(&String.downcase/1) |> List.first() do
          "on" -> true
          "off" -> false
          _ -> not state.mouse_enabled
        end

      if requested do
        # X10 click reporting + SGR (extended coords) — same sequences
        # Tui.start/1 writes on app startup.
        write_to_tty("\e[?1000h\e[?1006h")
      else
        write_to_tty("\e[?1006l\e[?1000l")
      end

      label = if requested, do: "on", else: "off (terminal text selection restored)"

      state
      |> State.set_mouse_enabled(requested)
      |> State.append_event({:info, "mouse capture → " <> label})
      |> noreply()
    end

    defp dispatch_command(:diff, args, state) do
      case args |> Enum.map(&String.downcase/1) |> List.first() do
        mode when mode in ["side", "side-by-side", "split"] ->
          state
          |> State.set_diff_mode(:side_by_side)
          |> State.set_details_tab(:changes)
          |> State.append_event({:info, "diff layout → side-by-side"})
          |> maybe_kick_git_diff()
          |> noreply()

        "inline" ->
          state
          |> State.set_diff_mode(:inline)
          |> State.set_details_tab(:changes)
          |> State.append_event({:info, "diff layout → inline"})
          |> maybe_kick_git_diff()
          |> noreply()

        _ ->
          state
          |> State.set_details_tab(:changes)
          |> State.append_event({:info, "details tab → Changes"})
          |> maybe_kick_git_diff()
          |> noreply()
      end
    end

    defp dispatch_command(:timeline, _args, state) do
      state
      |> State.set_details_tab(:timeline)
      |> State.append_event({:info, "details tab → Timeline"})
      |> noreply()
    end

    defp dispatch_command(:cd, [], state) do
      append_and_noreply(
        state,
        {:warning, "Usage: /cd PATH  (use /pwd to see the current directory)"}
      )
    end

    defp dispatch_command(:cd, [path_arg | _], state) do
      expanded = Path.expand(path_arg)

      cond do
        not File.exists?(expanded) ->
          append_and_noreply(state, {:warning, "Path does not exist: " <> expanded})

        not File.dir?(expanded) ->
          append_and_noreply(state, {:warning, "Not a directory: " <> expanded})

        true ->
          state
          |> update_in_session(&Session.set_cwd(&1, expanded))
          |> State.append_event({:info, "cwd → " <> expanded})
          |> maybe_kick_git_diff()
          |> noreply()
      end
    end

    defp dispatch_command(:pwd, _args, state) do
      {path, source} =
        case state.session.cwd do
          nil ->
            case File.cwd() do
              {:ok, p} -> {p, " (default, process cwd — use /cd or -p to override)"}
              _ -> {"?", " (unable to read process cwd)"}
            end

          p ->
            {p, " (set via /cd or --path)"}
        end

      append_and_noreply(state, {:info, "cwd: " <> path <> source})
    end

    defp dispatch_command(:details, args, state) do
      new_value =
        case Enum.map(args, &String.downcase/1) do
          ["on"] -> true
          ["off"] -> false
          _ -> not state.show_details
        end

      label = if new_value, do: "on", else: "off"

      state
      |> Map.put(:show_details, new_value)
      |> State.append_event({:info, "Details pane → " <> label})
      |> noreply()
    end

    defp dispatch_command(:expand, args, state) do
      results = Session.tool_results(state.session)
      total = length(results)
      n = parse_expand_index(args)

      case Enum.at(results, n - 1) do
        nil ->
          append_and_noreply(
            state,
            {:warning, "No tool result at position #{n} (total: #{total})."}
          )

        %ExAthena.Messages.ToolResult{content: content, is_error: is_error} ->
          kind = if is_error, do: :tool_result_error, else: :tool_result
          header_kind = if is_error, do: :error, else: :info

          state =
            state
            |> State.append_event({header_kind, "▼ tool result #{n}/#{total}"})
            |> append_expanded_lines(kind, to_string(content))
            |> State.append_event({:info, "▲ /expand"})

          {:noreply, state}
      end
    end

    defp dispatch_command(_, _, state), do: {:noreply, state}

    # ── Helpers ──────────────────────────────────────────────────────────────

    defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)

    defp append_status_row(%State{session: session} = state) do
      State.append_event(state, {:status, View.status_line(session)})
    end

    defp banner_events(%State{session: session} = state) do
      cwd_line =
        case session.cwd do
          nil ->
            case File.cwd() do
              {:ok, path} -> "cwd=" <> path <> "  (default — use /cd or -p to change)"
              _ -> "cwd=(unknown)"
            end

          path ->
            "cwd=" <> path
        end

      state
      |> State.append_event({:info, "ExAthena chat  (/help for commands, /exit to quit)"})
      |> State.append_event(
        {:info,
         "provider=#{session.provider}  model=#{session.model}  " <>
           "permission=#{Permission.label(session.permission)}"}
      )
      |> State.append_event({:info, cwd_line})
    end

    # ── Git diff (Changes tab) ────────────────────────────────────────────

    # Spawn an unsupervised Task that shells out to `git diff HEAD` in the
    # session's cwd and sends `{:git_diff, lines}` back to this process.
    # Wrapped in try/rescue/catch per the CLAUDE.md Task.start guidance.
    # Errors / non-git directories result in an empty diff (silently).
    defp maybe_kick_git_diff(state) do
      parent = self()
      cwd = state.session.cwd || File.cwd!()

      Task.start(fn ->
        try do
          lines = fetch_git_diff(cwd)
          send(parent, {:git_diff, lines})
        rescue
          _ -> send(parent, {:git_diff, []})
        catch
          _, _ -> send(parent, {:git_diff, []})
        end
      end)

      state
    end

    # All working-tree changes vs HEAD — including untracked (new) files —
    # via the shared ExAthena.GitDiff (same source the web Git tab uses).
    defp fetch_git_diff(cwd) do
      case ExAthena.GitDiff.build(cwd) do
        {:ok, ""} -> ["(no changes vs HEAD)", "cwd: #{cwd}"]
        {:ok, text} -> String.split(text, "\n")
        {:error, :not_a_repo} -> ["not a git repository (cwd: #{cwd})"]
        {:error, :no_git} -> ["`git` executable not found on PATH"]
        {:error, :timeout} -> ["git timed out (cwd: #{cwd})"]
      end
    end

    defp restore_logger(%State{prior_log_level: level} = state) do
      Logger.configure(level: level)
      state
    end

    defp append_provider_details(state, provider_name) do
      case lookup_provider_spec(provider_name) do
        {:ok, spec} when spec.extra_headers != %{} ->
          state
          |> State.append_detail_header("provider: #{provider_name}")
          |> State.append_detail_lines(:info, "extra_headers: #{inspect(spec.extra_headers)}")

        _ ->
          state
      end
    end

    defp lookup_provider_spec(name) when is_binary(name) do
      case Process.whereis(ExAthena.ProviderRegistry) do
        nil -> :error
        _pid -> ExAthena.ProviderRegistry.lookup(name)
      end
    end

    defp check_api_key_needed(%State{api_key: api_key, session: session}) do
      if is_nil(api_key) do
        case lookup_provider_spec(Atom.to_string(session.provider)) do
          {:ok, %{api_key_prompt: true, api_key_env: env}} when is_binary(env) ->
            if is_nil(System.get_env(env)) do
              {:needs_key, session.provider, env}
            else
              :ok
            end

          _ ->
            :ok
        end
      else
        :ok
      end
    end

    defp update_in_session(state, fun), do: %{state | session: fun.(state.session)}

    # ── Saved chats (ExAthena.Chats) ─────────────────────────────────────────

    # Saved while the turn still holds the chat, then released.
    defp save_chat(%State{} = state) do
      id = state.session.chat_id
      saved = Session.save(state.session)
      Chats.release(id)

      case saved do
        {:ok, session} ->
          %{state | session: session}

        {:moved, session} ->
          State.append_event(
            %{state | session: session},
            {:warning,
             "This chat moved on in another window, so this reply was saved as a new chat (#{session.chat_id})."}
          )

        {:error, reason} ->
          State.append_event(state, {:warning, "Could not save this chat: " <> describe(reason)})
      end
    end

    # Rewind and fork reopen a chat this window already had open: the settings
    # picked since the last save (permission, model, folder) stay.
    defp reopen_chat(%State{session: s} = state, id) do
      open_chat(state, id,
        provider: s.provider,
        model: s.model,
        permission: s.permission,
        cwd: s.cwd
      )
    end

    defp append_failed_files(state, []), do: state

    defp append_failed_files(state, paths),
      do: State.append_event(state, {:warning, "Could not put back: " <> Enum.join(paths, ", ")})

    defp open_chat(state, id, opts \\ [])

    defp open_chat(%State{run_task: task} = state, _id, _opts) when is_pid(task),
      do: State.append_event(state, {:warning, "Wait for the reply to finish first."})

    defp open_chat(%State{} = state, id, opts) do
      case Session.open(id, Enum.reject(opts, fn {_k, v} -> is_nil(v) end)) do
        {:ok, session} ->
          %{State.clear_session(state) | session: session} |> banner_events() |> replay_chat()

        {:error, reason} ->
          State.append_event(state, {:warning, "Could not open chat #{id}: " <> describe(reason)})
      end
    end

    # One row per saved message: what you typed, what the model said, and the
    # tools it used.
    defp replay_chat(%State{session: session} = state) do
      Enum.reduce(session.messages, state, fn message, s ->
        case replay_row(message) do
          nil -> s
          row -> State.append_event(s, row)
        end
      end)
    end

    defp replay_row(%{role: :user, content: text}) when is_binary(text), do: {:user, text}

    defp replay_row(%{role: :assistant, content: text}) when is_binary(text) and text != "",
      do: {:assistant, text}

    defp replay_row(%{role: :assistant, tool_calls: [_ | _] = calls}),
      do: {:info, "used " <> Enum.map_join(calls, ", ", & &1.name)}

    defp replay_row(_), do: nil

    defp saved_steps(state) do
      case Chats.load(state.session.chat_id) do
        {:ok, %{steps: [_ | _] = steps}} -> {:ok, steps}
        {:ok, _} -> {:error, :empty}
        {:error, :not_found} -> {:error, :empty}
        err -> err
      end
    end

    defp pick_step(steps, [], :last), do: {:ok, List.last(steps)}

    defp pick_step(steps, [n | _], _default) do
      case Integer.parse(n) do
        {i, ""} when i >= 1 and i <= length(steps) -> {:ok, Enum.at(steps, i - 1)}
        _ -> {:error, {:no_step, n, length(steps)}}
      end
    end

    defp pick_step(_steps, [], nil), do: {:error, :no_step_given}

    defp idle(%State{run_task: task}) when is_pid(task), do: {:error, :busy}
    defp idle(_), do: :ok

    defp step_line(%{role: :user, content: text}) when is_binary(text), do: "you: " <> short(text)

    defp step_line(%{role: :assistant, content: text}) when is_binary(text) and text != "",
      do: "model: " <> short(text)

    defp step_line(%{role: :assistant, tool_calls: [_ | _] = calls}),
      do: "model used " <> Enum.map_join(calls, ", ", & &1.name)

    defp step_line(%{role: :tool}), do: "tool result"
    defp step_line(%{role: role}), do: to_string(role)

    defp short(text),
      do: text |> String.split("\n", trim: true) |> List.first("") |> String.slice(0, 60)

    defp resume_label(chat) do
      when_text = Calendar.strftime(chat.updated_at, "%Y-%m-%d %H:%M")
      "#{chat[:title] || chat.id} · #{when_text}"
    end

    defp session_cwd(session), do: session.cwd || File.cwd!()

    defp describe(:busy), do: "wait for the reply to finish first"
    defp describe(:not_found), do: "no saved chat by that name"
    defp describe(:invalid_id), do: "that is not a chat name"
    defp describe(:empty), do: "nothing is saved in this chat yet"
    defp describe(:no_step_given), do: "say which step, e.g. /rewind 2 (/rewind lists them)"
    defp describe({:no_step, n, count}), do: "there is no step #{n}; this chat has #{count}"
    defp describe(other), do: inspect(other)

    defp noreply(state), do: {:noreply, state}

    defp append_and_noreply(state, row), do: {:noreply, State.append_event(state, row)}

    defp append_expanded_lines(state, kind, text) do
      text
      |> String.trim_trailing("\n")
      |> String.split("\n")
      |> Enum.reduce(state, fn line, s -> State.append_event(s, {kind, line}) end)
    end

    defp provider_name_to_atom(name) when is_binary(name) do
      String.to_existing_atom(name)
    rescue
      ArgumentError -> String.to_atom(name)
    end

    defp parse_expand_index([]), do: 1

    defp parse_expand_index([arg | _]) when is_binary(arg) do
      case Integer.parse(arg) do
        {n, ""} when n > 0 -> n
        _ -> 1
      end
    end

    # One call now covers local daemons, JSON-spec catalogs and cloud providers
    # alike — the per-provider branching this used to carry lives behind
    # `ExAthena.list_models/2`. The popup wants plain ids, and the messages
    # below are keyed on the legacy error atoms `legacy_result/1` preserves.
    defp list_models_for(%{provider: provider}) do
      provider
      |> ExAthena.list_models()
      |> ExAthena.ModelListing.legacy_result()
    end

    defp no_models_message(:llamacpp),
      do: "No models loaded. Start one with: llama-server --model path/to/model.gguf"

    defp no_models_message(:exo),
      do: "No models downloaded in the exo cluster. Download one via the exo dashboard."

    defp no_models_message(_),
      do: "No models installed. Pull one with: ollama pull llama3.1"

    defp unreachable_message(:llamacpp),
      do: "llama.cpp server not running. Start it with: llama-server --model path/to/model.gguf"

    defp unreachable_message(:exo),
      do: "exo is not reachable. Start it with: exo"

    defp unreachable_message(_),
      do: "Ollama not running. Start it with: ollama serve"

    # Reconcile the configured model against what the local provider has
    # available; surface diagnostics as banner rows but don't block startup.
    # Only the local servers are reconciled: they hold a small, changeable set
    # of installed models, so a stale configured model is both likely and
    # cheap to detect. Cloud catalogs are neither.
    defp reconcile_initial_session(%Session{provider: provider} = session)
         when provider in [:ollama, :llamacpp, :exo] do
      case Runner.select_initial_model(session.model, list_models_for(session)) do
        {:ok, _} -> session
        {:fallback, model} -> Session.set_model(session, model)
        {:error, _} -> session
      end
    end

    defp reconcile_initial_session(session), do: session
  end
end
