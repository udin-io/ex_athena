defmodule ExAthena.Web.Live.ChatLiveAutoScrollTest do
  @moduledoc """
  Covers the *server-rendered* half of the "only auto-scroll when the reader is
  at the bottom" behaviour (#206).

  The behaviour itself — measuring the scroll position, arming/disarming the
  pin, showing the jump-to-latest pill — lives in the `ScrollToBottom` JS hook
  and cannot be observed from `LiveViewTest`, which never runs a browser. What
  the server owns, and therefore what is asserted here, is the contract the
  hook depends on: each scroll container carries the hook, advertises whether a
  run is live via `data-streaming`, and is paired with the hook-owned slot the
  pill is mounted into. If any of those three drift, the hook silently stops
  working, which is exactly the regression worth catching here.

  See the PR's "Manual verification" section for the browser-side steps.
  """
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias ExAthena.Web.Endpoint
  @endpoint Endpoint

  setup do
    # `start_supervised` rather than `start_link`: ExUnit then waits for the
    # endpoint to be fully down before the next test starts it again. Starting
    # over an endpoint that is still dying is what makes `:ets.lookup(Endpoint,
    # …)` blow up mid-mount.
    case start_supervised(Endpoint) do
      {:ok, _pid} -> :ok
      {:error, {{:already_started, _pid}, _}} -> :ok
    end

    %{conn: Phoenix.ConnTest.build_conn()}
  end

  describe "chat thread scroll container" do
    test "carries the scroll hook and starts with no run in flight", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#messages[phx-hook=\"ScrollToBottom\"]")
      # The hook reads this to decide whether the pill may appear at all: the
      # pill is only meaningful while content is still arriving.
      assert has_element?(view, "#messages[data-streaming=\"false\"]")
    end

    test "renders the hook-owned slot the jump-to-latest pill mounts into", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # phx-update="ignore" because the hook — not the server — owns what goes
      # inside: without it the next streamed token's diff would delete the pill.
      assert has_element?(view, "#messages-jump[phx-update=\"ignore\"]")
    end
  end

  describe "details pane scroll container" do
    test "gets the same hook, streaming flag and pill slot as the chat thread", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # The Log tab is the one that scrolls with the run, and it shares the
      # hook with the chat thread — so it inherits the same behaviour.
      view |> element("button[phx-value-tab=\"log\"]") |> render_click()

      assert has_element?(view, "#details-pane[phx-hook=\"ScrollToBottom\"]")
      assert has_element?(view, "#details-pane[data-streaming=\"false\"]")
      assert has_element?(view, "#details-pane-jump[phx-update=\"ignore\"]")
    end
  end
end
