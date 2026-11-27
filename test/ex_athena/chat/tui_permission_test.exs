defmodule ExAthena.Chat.TuiPermissionTest do
  @moduledoc """
  The terminal chat picks a permission level instead of a mode, and answers
  the run's questions and approvals from a popup (issue 322).
  """
  use ExUnit.Case, async: true

  alias ExAthena.Chat.{Session, Tui}
  alias ExAthena.Chat.Tui.State
  alias ExRatatui.Event

  defp key(code), do: %Event.Key{kind: "press", code: code, modifiers: []}

  defp state, do: State.new(Session.new(provider: :ollama, model: "llama3.1"))

  defp ask(state, question, options, extra \\ %{}) do
    q =
      Map.merge(
        %{tool_call_id: "approval-1", question: question, options: options, reply_to: self()},
        extra
      )

    {:noreply, state} = Tui.handle_info({:athena_ask_user, q}, state)
    state
  end

  test "a question from the run opens on Deny, and Enter answers the process that asked" do
    state = ask(state(), "Change a.txt?", ["Allow", "Deny"])

    assert {{:question, _q}, ["Allow", "Deny"], 1} = state.popup

    {:noreply, state} = Tui.handle_event(key("enter"), state)

    assert_received {:athena_user_answer, "approval-1", "Deny"}
    assert state.popup == nil
  end

  test "an approved plan moves the chat to the level it was approved at" do
    state = state() |> State.set_permission(:read_only)

    state =
      ask(
        state,
        "The chat's plan:\n\n1. Write a.txt\n\nGo ahead?",
        ["Yes, and ask before each edit", "Yes, and edit freely", "No, keep planning"],
        %{kind: :plan_approval}
      )

    {:noreply, state} = Tui.handle_event(key("up"), state)
    {:noreply, state} = Tui.handle_event(key("enter"), state)

    assert_received {:athena_user_answer, "approval-1", "Yes, and edit freely"}
    assert state.session.permission == :edit
  end

  test "keep planning leaves the chat read only" do
    state = state() |> State.set_permission(:read_only)
    state = ask(state, "Go ahead?", ["No, keep planning"])

    {:noreply, state} = Tui.handle_event(key("enter"), state)

    assert state.session.permission == :read_only
  end

  test "a question the model wrote with the same words moves nothing" do
    state = state() |> State.set_permission(:read_only)
    state = ask(state, "Shall I?", ["Yes, and edit freely"])

    {:noreply, state} = Tui.handle_event(key("enter"), state)

    assert state.session.permission == :read_only
  end

  test "Esc on a question answers Deny, so the run does not wait forever" do
    state = ask(state(), "Change a.txt?", ["Allow", "Deny"])

    {:noreply, state} = Tui.handle_event(key("esc"), state)

    assert_received {:athena_user_answer, "approval-1", "Deny"}
    assert state.popup == nil
  end

  test "a second question waits for the first, and a picker never covers one" do
    state = ask(state(), "First?", ["Allow", "Deny"])
    state = ask(state, "Second?", ["Allow", "Deny"], %{tool_call_id: "approval-2"})

    state = State.open_popup(state, {:permissions, [:ask]})
    assert {{:question, %{question: "First?"}}, _, _} = state.popup

    {:noreply, state} = Tui.handle_event(key("enter"), state)
    assert_received {:athena_user_answer, "approval-1", "Deny"}
    assert {{:question, %{question: "Second?"}}, _, 1} = state.popup
  end

  test "a question that lands on an open picker starts on Deny" do
    state = State.open_popup(state(), {:permissions, [:read_only, :ask]})
    state = ask(state, "Change a.txt?", ["Allow", "Deny"])

    {:noreply, _state} = Tui.handle_event(key("enter"), state)
    assert_received {:athena_user_answer, "approval-1", "Deny"}
  end

  test "a question without options can still be answered" do
    state = ask(state(), "Which file?", [])
    assert {{:question, _}, ["Yes", "No"], 1} = state.popup
  end

  describe "a message typed while the chat runs (issue 323)" do
    defp running(text) do
      ref = ExRatatui.textarea_new()
      ExRatatui.textarea_set_value(ref, text)
      {:ok, inbox} = Agent.start_link(fn -> [] end)

      state =
        state()
        |> Map.put(:input_ref, ref)
        |> Map.put(:inbox, inbox)
        |> State.set_loading(true)

      {state, inbox}
    end

    test "Enter queues it for the run's next turn and clears the box" do
      {state, inbox} = running("skip the admin login")

      {:noreply, state} = Tui.handle_event(key("enter"), state)

      assert Agent.get(inbox, & &1) == ["skip the admin login"]
      assert ExRatatui.textarea_get_value(state.input_ref) == ""
    end

    test "a command waits for the run to end" do
      {state, inbox} = running("/model")

      {:noreply, _state} = Tui.handle_event(key("enter"), state)

      assert Agent.get(inbox, & &1) == []
    end

    test "the message shows as the person's turn once the run takes it" do
      {state, _inbox} = running("")

      {:noreply, state} =
        Tui.handle_info({:athena_event, {:user_message_taken, "skip the admin login"}}, state)

      assert {:user, "skip the admin login"} in state.events
    end

    test "a message the run never took goes back into the box" do
      {state, inbox} = running("")
      Agent.update(inbox, &(&1 ++ ["one more thing"]))

      {:noreply, state} = Tui.handle_info({:athena_done, %ExAthena.Result{}}, state)

      assert ExRatatui.textarea_get_value(state.input_ref) == "one more thing"
      assert state.inbox == nil
    end
  end
end
