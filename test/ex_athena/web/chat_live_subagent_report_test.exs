defmodule ExAthena.Web.Live.ChatLiveSubagentReportTest do
  @moduledoc """
  A worker's report used to render twice in the Activity log — once as the
  `subagent_result` boundary event, once as the ordinary `tool_result` from
  the `spawn_agent` call that produced it, both carrying the same text
  (issue #264). Drives a connected `ChatLive` through its real UI entry point
  for the Log tab, then delivers the events a run would, exactly as
  `RunServer` does (`send(view.pid, {:athena, event})`), and asserts on the
  rendered HTML that the report appears once, with the runtime footer
  (which only ever rode on the tool_result) still present.

  Follows the connected-mount pattern in `chat_live_files_ui_test.exs`
  (`start_supervised!(Endpoint)`) rather than starting the endpoint by hand.
  """
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias ExAthena.Web.Endpoint
  @endpoint Endpoint

  setup do
    start_supervised!(Endpoint)
    %{conn: Phoenix.ConnTest.build_conn()}
  end

  @report "# Findings\n\nsomething the worker learned"
  @runtime_line "[runtime] worker 1 of 24 this run; 23 left. " <>
                  "Worker id: sub_a — read its full report or journal with read_worker_report."

  defp deliver(view, event), do: send(view.pid, {:athena, event})

  # The exact sequence a real spawn_agent call produces: the boundary
  # `subagent_spawn`/`subagent_result` pair straddling the ordinary
  # `tool_call`/`tool_result` of the tool that emitted them, the runtime
  # footer riding only on the tool_result (see spawn_agent.ex's
  # `annotate_allowance/2`, applied after `emit_event({:subagent_result, …})`
  # already fired).
  defp deliver_worker_report(view) do
    deliver(view, {:subagent_spawn, %{id: "sub_a", prompt: "explore the repo"}})
    deliver(view, {:tool_call, %{id: "c1", name: "spawn_agent", arguments: %{"prompt" => "go"}}})

    deliver(
      view,
      {:tool_result,
       %{tool_call_id: "c1", content: @report <> "\n" <> @runtime_line, is_error: false}}
    )

    deliver(view, {:subagent_result, %{id: "sub_a", text: @report}})
  end

  defp occurrences(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end

  test "a worker's report appears once in the Activity log", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("button[phx-value-tab=\"log\"]") |> render_click()

    deliver_worker_report(view)
    html = render(view)

    assert occurrences(html, "something the worker learned") == 1
    # The surviving copy is the tool_result, so the runtime footer — worker
    # id, quota remaining — is still on the page.
    assert html =~ @runtime_line
  end
end
