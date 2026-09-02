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
  @endpoint Endpoint

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Start the (server: false) endpoint in-process so `live/2` can mount the
    # connected LiveView. Linked to the test process, so it's reaped on exit.
    case Endpoint.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

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
end
