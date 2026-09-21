defmodule ExAthena.Web.Live.ChatLiveFilesUITest do
  @moduledoc """
  Drives the rebuilt Files tab of `ExAthena.Web.Live.ChatLive` through its
  real UI entry points — a connected mount (`live/2`) plus `render_click` /
  `render_submit` / `has_element?` — so the lazy directory tree and the file
  viewer are exercised end to end, not just via `handle_event/3` in isolation.
  """
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias ExAthena.Web.Endpoint
  alias ExAthena.Web.Sessions
  @endpoint Endpoint

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Start the (server: false) endpoint in-process so `live/2` can mount the
    # connected LiveView. `start_supervised!/1` makes ExUnit own the
    # lifecycle: on exit it stops the endpoint and WAITS for it to actually
    # terminate before the next test runs, unlike a hand-rolled
    # `start_link/0` + `{:error, {:already_started, _}}` swallow, which let
    # the next test mount against an endpoint still tearing down its ETS
    # table (issue #234).
    start_supervised!(Endpoint)

    # Temp fixture: a root with one subdirectory holding one text file, plus a
    # root-level text file, so the lazy tree + viewer are meaningful.
    root = Path.join(tmp_dir, "root")
    File.mkdir_p!(Path.join(root, "subdir"))
    File.write!(Path.join(root, "subdir/inner.txt"), "inner file content")
    File.write!(Path.join(root, "a.txt"), "hello a")

    %{conn: Phoenix.ConnTest.build_conn(), root: root}
  end

  # Open the working folder through the real "New session" modal — the
  # canonical UI flow that sets `cwd` (the precondition the Files tab needs).
  defp open_folder(view, root) do
    view
    |> element("button.btn-plus[phx-click=\"show_modal\"]")
    |> render_click()

    view
    |> form("form[phx-submit=\"create_session\"]", %{"path" => root})
    |> render_submit()

    view
  end

  test "switching to the Files tab renders the tree with the root expanded", %{
    conn: conn,
    root: root
  } do
    {:ok, view, _html} = live(conn, "/")
    view = open_folder(view, root)

    # (a) Switch to the Files tab — auto-init lists the root and expands it.
    view |> element("button[phx-value-tab=\"files\"]") |> render_click()
    assert has_element?(view, ".files-panel")
    assert has_element?(view, ".files-tree")
    # The root is auto-listed and expanded, so its entries render:
    assert has_element?(view, "button.files-row--dir")
    assert has_element?(view, "button.files-tree-file")
  end

  test "toggling a directory row lazy-loads its children, and re-toggling collapses them", %{
    conn: conn,
    root: root
  } do
    {:ok, view, _html} = live(conn, "/")
    view = open_folder(view, root)
    view |> element("button[phx-value-tab=\"files\"]") |> render_click()

    # (b) Expand the subdir — its children are listed lazily and appear.
    view |> element("button.files-row--dir") |> render_click()
    assert has_element?(view, "button.files-tree-file", "inner.txt")

    # (c) Collapse the same subdir — the children are no longer rendered.
    view |> element("button.files-row--dir") |> render_click()
    refute has_element?(view, "button.files-tree-file", "inner.txt")
  end

  test "opening a file shows the viewer with its content and marks the row active", %{
    conn: conn,
    root: root
  } do
    {:ok, view, _html} = live(conn, "/")
    view = open_folder(view, root)
    view |> element("button[phx-value-tab=\"files\"]") |> render_click()

    # (d) Click the root-level file row — the viewer opens with the content
    # and the row becomes active.
    view |> element("button.files-tree-file") |> render_click()
    assert has_element?(view, ".files-view")
    assert has_element?(view, "pre.files-view-content", "hello a")
    assert has_element?(view, "button.files-row--active")
  end

  test "collapse-all folds every expanded directory", %{conn: conn, root: root} do
    {:ok, view, _html} = live(conn, "/")
    view = open_folder(view, root)
    view |> element("button[phx-value-tab=\"files\"]") |> render_click()

    # Expand the subdir so there is something to collapse…
    view |> element("button.files-row--dir") |> render_click()
    assert has_element?(view, "button.files-row--dir.files-row--expanded")

    # …then "collapse all" folds it.
    view |> element("button.files-toolbar-collapse") |> render_click()
    refute has_element?(view, "button.files-row--dir.files-row--expanded")
  end

  test "closing the viewer clears the open file", %{conn: conn, root: root} do
    {:ok, view, _html} = live(conn, "/")
    view = open_folder(view, root)
    view |> element("button[phx-value-tab=\"files\"]") |> render_click()

    # Open the file first…
    view |> element("button.files-tree-file") |> render_click()
    assert has_element?(view, ".files-view")

    # …then close it.
    view |> element("button.files-view-close") |> render_click()
    refute has_element?(view, ".files-view")
  end

  # ── Download, preview and auto-linked paths (issue #269) ─────────────────

  describe "getting the bytes out of the browser" do
    test "opening a file offers a download link for it", %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, "/")
      view = open_folder(view, root)
      view |> element("button[phx-value-tab=\"files\"]") |> render_click()
      view |> element("button.files-tree-file") |> render_click()

      assert has_element?(view, ~s(a.files-view-download[href^="/files/download?"]))
    end

    test "an HTML file previews in an iframe that cannot reach this origin", %{
      conn: conn,
      root: root
    } do
      File.write!(Path.join(root, "mock.html"), "<h1>a mock</h1>")

      {:ok, view, _html} = live(conn, "/")
      view = open_folder(view, root)
      view |> element("button[phx-value-tab=\"files\"]") |> render_click()
      view |> element("button.files-tree-file", "mock.html") |> render_click()

      # Source first; the preview is opt-in.
      assert has_element?(view, "pre.files-view-content")
      refute has_element?(view, "iframe.files-preview")

      html = view |> element("button.files-view-preview") |> render_click()

      assert has_element?(view, ~s(iframe.files-preview[src^="/files/preview?"]))
      assert has_element?(view, ~s(iframe.files-preview[sandbox="allow-scripts"]))
      # The whole point: scripts may run, but never on this app's origin.
      refute html =~ "allow-same-origin"
      refute has_element?(view, "pre.files-view-content")
    end

    test "a file that is not HTML offers no preview", %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, "/")
      view = open_folder(view, root)
      view |> element("button[phx-value-tab=\"files\"]") |> render_click()
      view |> element("button.files-tree-file", "a.txt") |> render_click()

      assert has_element?(view, ".files-view")
      refute has_element?(view, "button.files-view-preview")
    end

    test "a binary file can still be downloaded", %{conn: conn, root: root} do
      File.write!(Path.join(root, "logo.png"), <<0x89, ?P, ?N, ?G, 0, 1, 2>>)

      {:ok, view, _html} = live(conn, "/")
      view = open_folder(view, root)
      view |> element("button[phx-value-tab=\"files\"]") |> render_click()
      view |> element("button.files-tree-file", "logo.png") |> render_click()

      assert has_element?(view, ".files-notice", "binary file")
      assert has_element?(view, ~s(a.files-view-download[href^="/files/download?"]))
    end

    test "a path an assistant message names is a link, an invented one is not", %{
      conn: conn,
      root: root
    } do
      id = "issue269-#{System.unique_integer([:positive])}"
      on_exit(fn -> Sessions.delete(id) end)

      Sessions.save(%{
        id: id,
        title: "paths",
        cwd: root,
        provider: "anthropic",
        model: "claude",
        mode: "react",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now(),
        display_messages: [
          %{
            id: "m1",
            role: :assistant,
            text: "Wrote a.txt, but not tmp/invented.html.",
            tool_events: [],
            status: nil
          }
        ],
        ex_messages: [],
        provider_session_id: nil,
        tool_uis: %{},
        details_stream: [],
        orchestrator: nil
      })

      Sessions.touch_recent(root)

      {:ok, view, _html} = live(conn, "/")
      view |> element(~s(button.recent-open[phx-value-cwd="#{root}"])) |> render_click()
      view |> element(~s(button.session-load[phx-value-id="#{id}"])) |> render_click()

      assert has_element?(
               view,
               ~s(a.path-link[phx-value-path="#{Path.join(root, "a.txt")}"])
             )

      html = render(view)
      assert html =~ "tmp/invented.html"
      refute html =~ ~s(>tmp/invented.html</a>)
    end
  end
end
