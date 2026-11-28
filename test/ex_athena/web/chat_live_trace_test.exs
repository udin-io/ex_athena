defmodule ExAthena.Web.ChatLiveTraceTest do
  @moduledoc """
  Issue 352: the Trace tab, through the LiveView's own mount, events and
  render, so a passing test proves the HTML the browser gets.
  """
  use ExUnit.Case, async: true

  alias ExAthena.Web.Live.ChatLive

  defp d(id, type, payload, at),
    do: %{id: id, type: type, message_id: "m1", payload: payload, at: at}

  # Oldest first here; the socket keeps them newest first.
  defp entries do
    [
      d("u", :user_text, %{text: "fix the upload"}, 0),
      d("i1", :iteration, %{n: 1}, 100),
      d(
        "c1",
        :tool_call,
        %{tool_call_id: "b1", name: "bash", arguments: %{"command" => "mix test"}},
        200
      ),
      d(
        "r1",
        :tool_result,
        %{tool_call_id: "b1", content: "3 tests, 1 failure", is_error: false},
        900
      ),
      d("ui1", :tool_ui, %{tool_call_id: "b1", ui: %{kind: :process}, test: :failed}, 900),
      d("i2", :iteration, %{n: 2}, 1_000),
      d("s1", :steer, %{kind: :wrap_up, text: "[runtime] You are 2 turns in <b>now</b>"}, 1_000),
      d(
        "c2",
        :tool_call,
        %{tool_call_id: "e1", name: "edit", arguments: %{"path" => "lib/a.ex"}},
        1_100
      )
    ]
  end

  defp socket(overrides \\ %{}) do
    {:ok, socket} = ChatLive.mount(%{}, nil, %Phoenix.LiveView.Socket{})

    assigns =
      socket.assigns
      |> Map.merge(%{
        session_id: "sess1",
        details_tab: :trace,
        show_details: true,
        page_loading: false,
        session_created_at: ~U[2026-11-28 10:00:00.000Z],
        details_stream: Enum.reverse(entries())
      })
      |> Map.merge(overrides)

    %{socket | assigns: assigns}
  end

  defp html(socket) do
    socket.assigns
    |> ChatLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> LazyHTML.from_document()
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()
  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()

  test "the Trace tab draws one mark per turn, coloured by what it did" do
    doc = html(socket())

    assert count(doc, "#details-tab-trace") == 1
    assert count(doc, "#trace-lane-chat [data-kind='test_failed']") == 1
    assert count(doc, "#trace-lane-chat [data-kind='edit']") == 1
    assert count(doc, "#trace-notes [data-note='W']") == 1
  end

  test "clicking a mark shows that turn's tool calls, results and note" do
    {:noreply, s} = ChatLive.handle_event("trace_select", %{"mark" => "t1"}, socket())
    doc = html(s)

    assert count(doc, "#trace-detail-t1") == 1
    assert count(doc, "#trace-detail-t1 [data-tool='bash']") == 1
    assert text(doc, "#trace-detail-t1") =~ "3 tests, 1 failure"
    assert text(doc, "#trace-detail-t1") =~ "test failed"

    {:noreply, s} = ChatLive.handle_event("trace_select", %{"mark" => "t2"}, s)
    doc = html(s)

    assert count(doc, "#trace-detail-t1") == 0
    assert text(doc, "#trace-detail-t2") =~ "wrap up"
  end

  test "clicking a note opens the turn it was sent with, inside a group mark too" do
    reads =
      Enum.flat_map(1..300, fn n ->
        [
          d("i#{n}", :iteration, %{n: n}, n * 10),
          d(
            "c#{n}",
            :tool_call,
            %{tool_call_id: "r#{n}", name: "read", arguments: %{}},
            n * 10 + 1
          )
        ]
      end)

    steer = d("s", :steer, %{kind: :research, text: "[runtime] look it up"}, 1_501)
    stream = (Enum.take(reads, 300) ++ [steer] ++ Enum.drop(reads, 300)) |> Enum.reverse()

    {:noreply, s} =
      ChatLive.handle_event(
        "trace_select",
        %{"mark" => "t150"},
        socket(%{details_stream: stream})
      )

    doc = html(s)
    assert count(doc, "#trace-turn-t150") == 1
    assert text(doc, "#trace-turn-t150") =~ "[runtime] look it up"
  end

  test "session text in a turn is escaped, never markup" do
    {:noreply, s} = ChatLive.handle_event("trace_select", %{"mark" => "t2"}, socket())
    doc = html(s)

    assert count(doc, "#trace-detail-t2 b") == 0
    assert text(doc, "#trace-detail-t2") =~ "<b>now</b>"
  end

  test "clicking the open mark again closes it" do
    {:noreply, s} = ChatLive.handle_event("trace_select", %{"mark" => "t1"}, socket())
    {:noreply, s} = ChatLive.handle_event("trace_select", %{"mark" => "t1"}, s)

    assert count(html(s), "#trace-detail-t1") == 0
  end

  test "a mark id the trace never drew opens nothing" do
    {:noreply, s} = ChatLive.handle_event("trace_select", %{"mark" => "nope"}, socket())

    assert count(html(s), ".trace-details") == 0
  end

  test "a session saved without times says its turns are evenly spaced" do
    untimed = Enum.map(entries(), &Map.delete(&1, :at)) |> Enum.reverse()
    doc = html(socket(%{details_stream: untimed}))

    assert count(doc, "#trace-untimed") == 1
    assert count(doc, "#trace-lane-chat [data-kind]") == 2
  end

  test "a text delta does not rebuild the drawing, any other event does" do
    {:noreply, s} = ChatLive.handle_event("switch_details_tab", %{"tab" => "trace"}, socket())
    before = s.assigns.trace

    {:noreply, s} = ChatLive.handle_info({:athena, {:content, "more words"}}, s)
    assert s.assigns.trace == before

    {:noreply, s} = ChatLive.handle_info({:athena, {:iteration, 3}}, s)
    assert s.assigns.trace.turn_count == before.turn_count + 1
  end

  test "no token bar runs past the right edge" do
    usage = fn id, at -> d(id, :usage, %{usage: %{input_tokens: 100, cached_tokens: 50}}, at) end
    stream = Enum.reverse(entries() ++ [usage.("u1", 150), usage.("u2", 1_100)])

    ends =
      socket(%{details_stream: stream})
      |> html()
      |> LazyHTML.query(".trace-tokens-in")
      |> Enum.map(fn rect ->
        [x] = LazyHTML.attribute(rect, "x")
        [w] = LazyHTML.attribute(rect, "width")
        pct(x) + pct(w)
      end)

    assert length(ends) == 2
    assert Enum.all?(ends, &(&1 <= 100.0))
  end

  defp pct(text), do: text |> String.trim_trailing("%") |> Float.parse() |> elem(0)

  test "Save sends the open chat's trace as one file named for the session" do
    assert {"trace-sess1.html", html} = ChatLive.trace_file(socket().assigns)

    doc = LazyHTML.from_document(html)
    assert count(doc, "#trace-lane-chat [data-kind='test_failed']") == 1
    assert count(doc, "#trace-export-notice") == 1
    assert {:noreply, _} = ChatLive.handle_event("trace_save", %{}, socket())
  end

  test "an empty chat shows how the trace fills in" do
    assert count(html(socket(%{details_stream: []})), "#trace-empty") == 1
  end

  test "a new run event redraws the trace live" do
    s = socket(%{pending_assistant_msg_id: "m1"})
    {:noreply, s} = ChatLive.handle_info({:athena, {:iteration, 3}}, s)

    {:noreply, s} =
      ChatLive.handle_info(
        {:athena, {:tool_call, %{id: "g1", name: "grep", arguments: %{}}}},
        s
      )

    assert count(html(s), "#trace-lane-chat [data-kind='read']") == 1
  end
end
