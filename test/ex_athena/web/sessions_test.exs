defmodule ExAthena.Web.SessionsTest do
  use ExUnit.Case, async: true

  alias ExAthena.Web.Sessions
  alias ExAthena.Result

  # `Enum.sort_by(&(&1.updated_at), :desc)` compares %DateTime{} structs as raw
  # terms. Map comparison walks keys in ascending order, so :day decides before
  # :month or :year is ever reached — `~U[2026-05-31] > ~U[2026-08-10]` is true.
  # The sidebar was therefore ordered by day-of-month, burying today's sessions
  # behind anything created late in an earlier month.
  describe "sort_by_recency/1" do
    defp header(id, dt), do: %{id: id, updated_at: dt}

    test "orders across months chronologically, not by day-of-month" do
      headers = [
        header("may31", ~U[2026-05-31 07:53:49Z]),
        header("aug10", ~U[2026-08-10 14:12:57Z]),
        header("jul30", ~U[2026-07-30 09:00:00Z])
      ]

      assert Enum.map(Sessions.sort_by_recency(headers), & &1.id) == ["aug10", "jul30", "may31"]
    end

    test "orders across years chronologically" do
      headers = [
        header("old", ~U[2025-12-31 23:59:59Z]),
        header("new", ~U[2026-01-01 00:00:01Z])
      ]

      assert Enum.map(Sessions.sort_by_recency(headers), & &1.id) == ["new", "old"]
    end

    test "orders within a day by time" do
      headers = [
        header("morning", ~U[2026-08-10 08:03:05Z]),
        header("afternoon", ~U[2026-08-10 14:12:57Z])
      ]

      assert Enum.map(Sessions.sort_by_recency(headers), & &1.id) == ["afternoon", "morning"]
    end

    test "sorts a header with a missing or malformed timestamp last instead of crashing" do
      headers = [
        header("broken", nil),
        header("good", ~U[2026-08-10 14:12:57Z])
      ]

      assert Enum.map(Sessions.sort_by_recency(headers), & &1.id) == ["good", "broken"]
    end
  end

  describe "merge_run_result/4 — durable run-result append" do
    test "appends the assistant message and refreshes ex_messages/session when new" do
      data = %{
        id: "s",
        display_messages: [%{id: "u1", role: :user, text: "hi"}],
        ex_messages: [:old],
        provider_session_id: nil
      }

      msg = %{id: "a1", role: :assistant, text: "the answer"}
      result = %Result{messages: [:m1, :m2], session_id: "ps"}

      assert {:save, merged} = Sessions.merge_run_result(data, "a1", msg, result)
      assert List.last(merged.display_messages) == msg
      assert merged.ex_messages == [:m1, :m2]
      assert merged.provider_session_id == "ps"
    end

    test "is a no-op when the message id is already present (LiveView already saved it)" do
      data = %{
        id: "s",
        display_messages: [%{id: "a1", role: :assistant, text: "rich version"}],
        ex_messages: []
      }

      msg = %{id: "a1", role: :assistant, text: "lean version"}
      result = %Result{messages: [], session_id: nil}

      assert :skip = Sessions.merge_run_result(data, "a1", msg, result)
    end

    test "keeps existing ex_messages/provider id when the result carries none" do
      data = %{id: "s", display_messages: [], ex_messages: [:keep], provider_session_id: "old"}
      result = %Result{messages: nil, session_id: nil}

      assert {:save, merged} = Sessions.merge_run_result(data, "a1", %{id: "a1"}, result)
      assert merged.ex_messages == [:keep]
      assert merged.provider_session_id == "old"
    end
  end

  describe "final_message_text/2 — surfacing the finish deliverable" do
    test "uses the deliverable as the message when nothing was streamed" do
      result = %Result{finish_reason: :submitted, deliverable: "the final answer"}
      assert Sessions.final_message_text("", result) == "the final answer"
      assert Sessions.final_message_text("   \n ", result) == "the final answer"
    end

    test "appends the deliverable to streamed text so the submitted answer shows" do
      result = %Result{finish_reason: :submitted, deliverable: "summary line"}
      assert Sessions.final_message_text("the story", result) == "the story\n\nsummary line"
    end

    test "does not duplicate when streamed text already contains the deliverable" do
      result = %Result{finish_reason: :submitted, deliverable: "the answer"}

      assert Sessions.final_message_text("here is the answer in full", result) ==
               "here is the answer in full"
    end

    test "non-submitted runs keep the streamed text unchanged" do
      assert Sessions.final_message_text("streamed", %Result{finish_reason: :stop}) == "streamed"

      assert Sessions.final_message_text("streamed", %Result{
               finish_reason: :submitted,
               deliverable: nil
             }) == "streamed"
    end
  end
end
