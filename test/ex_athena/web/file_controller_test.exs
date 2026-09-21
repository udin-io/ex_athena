defmodule ExAthena.Web.FileControllerTest do
  @moduledoc """
  The two HTTP routes that hand a run's output to the browser (issue #269).

  Three things are checked here, and they are the whole security story of the
  feature:

    * **Confinement.** Every requested path resolves through
      `ExAthena.Web.Files.resolve/2`, which is the same guard the file tools
      use. `..`, an absolute path elsewhere, and a symlink inside the root
      pointing out all get 403 — no second, hand-rolled check exists to drift
      away from it.
    * **The preview's headers.** The previewed HTML is model-authored, so the
      response must land it in an opaque origin. The positive assertion is
      `content-security-policy: sandbox allow-scripts`; the negative one —
      that `allow-same-origin` appears nowhere — is the regression that would
      actually matter, because `allow-scripts` plus `allow-same-origin` is a
      sandbox that isn't one.
    * **The gate.** Both routes sit in the `:browser` pipeline, so
      `ExAthena.Web.Auth` covers them. The app binds `0.0.0.0` under `--host`.
  """
  # async: false — `ExAthena.Web.Auth`'s required token lives in the (global)
  # application env, and the endpoint is started per test.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  alias ExAthena.Web.Auth
  alias ExAthena.Web.Endpoint
  alias ExAthena.Web.FileLinks

  @endpoint Endpoint
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    start_supervised!(Endpoint)
    on_exit(fn -> Application.delete_env(:ex_athena, Auth) end)

    root = Path.join(tmp_dir, "root")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(Path.join(root, "docs"))
    File.mkdir_p!(outside)

    File.write!(Path.join(root, "docs/brief.html"), "<h1>brief</h1>")
    File.write!(Path.join(root, "notes.txt"), "plain notes")
    File.write!(Path.join(root, "logo.png"), <<0x89, ?P, ?N, ?G, 0, 1, 2, 3>>)
    File.write!(Path.join(outside, "secret.txt"), "not yours")

    %{conn: build_conn(), root: root, outside: outside}
  end

  defp download(conn, root, path) do
    get(conn, "/files/download", %{"root" => FileLinks.sign_root(root), "path" => path})
  end

  defp preview(conn, root, path) do
    get(conn, "/files/preview", %{"root" => FileLinks.sign_root(root), "path" => path})
  end

  describe "download" do
    test "serves a file inside the root as an attachment", %{conn: conn, root: root} do
      conn = download(conn, root, "notes.txt")

      assert conn.status == 200
      assert conn.resp_body == "plain notes"

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="notes.txt"; filename*=UTF-8''notes.txt)
             ]

      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "a filename cannot break out of the Content-Disposition header", %{
      conn: conn,
      root: root
    } do
      File.write!(Path.join(root, ~s(od"d\;name.txt)), "odd")

      conn = download(conn, root, ~s(od"d\;name.txt))

      assert conn.status == 200
      [disposition] = get_resp_header(conn, "content-disposition")
      # The quote is replaced, not escaped: it must not be able to close the
      # quoted string and start header parameters of its own.
      assert disposition ==
               ~s(attachment; filename="od_d\;name.txt"; ) <> "filename*=UTF-8''od%22d%3Bname.txt"
    end

    test "serves a binary file rather than refusing it", %{conn: conn, root: root} do
      conn = download(conn, root, "logo.png")

      assert conn.status == 200
      assert conn.resp_body == <<0x89, ?P, ?N, ?G, 0, 1, 2, 3>>
    end

    test "accepts an absolute path that is inside the root", %{conn: conn, root: root} do
      conn = download(conn, root, Path.join(root, "docs/brief.html"))

      assert conn.status == 200
      assert conn.resp_body == "<h1>brief</h1>"
    end

    test "refuses `..` traversal", %{conn: conn, root: root} do
      conn = download(conn, root, "../outside/secret.txt")

      assert conn.status == 403
      refute conn.resp_body =~ "not yours"
    end

    test "refuses an absolute path elsewhere on the filesystem", %{
      conn: conn,
      root: root,
      outside: outside
    } do
      conn = download(conn, root, Path.join(outside, "secret.txt"))

      assert conn.status == 403
      refute conn.resp_body =~ "not yours"
    end

    test "refuses a symlink inside the root that points out of it", %{
      conn: conn,
      root: root,
      outside: outside
    } do
      link = Path.join(root, "escape.txt")
      File.ln_s!(Path.join(outside, "secret.txt"), link)
      assert File.exists?(link), "fixture symlink was not created"

      conn = download(conn, root, "escape.txt")

      assert conn.status == 403
      refute conn.resp_body =~ "not yours"
    end

    test "refuses a root token this server did not sign", %{conn: conn, root: root} do
      conn = get(conn, "/files/download", %{"root" => "forged." <> root, "path" => "notes.txt"})

      assert conn.status == 403
    end

    test "refuses a request with no root token at all", %{conn: conn} do
      conn = get(conn, "/files/download", %{"path" => "notes.txt"})

      assert conn.status == 403
    end

    test "404s a path inside the root that is not a file", %{conn: conn, root: root} do
      assert download(conn, root, "docs").status == 404
      assert download(conn, root, "docs/missing.html").status == 404
    end
  end

  describe "preview" do
    test "renders an HTML file with a sandbox CSP and no same-origin escape", %{
      conn: conn,
      root: root
    } do
      conn = preview(conn, root, "docs/brief.html")

      assert conn.status == 200
      assert conn.resp_body == "<h1>brief</h1>"

      assert get_resp_header(conn, "content-security-policy") == ["sandbox allow-scripts"]
      assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "never grants allow-same-origin, on any header of the response", %{
      conn: conn,
      root: root
    } do
      conn = preview(conn, root, "docs/brief.html")

      refute Enum.any?(conn.resp_headers, fn {_name, value} ->
               String.contains?(value, "allow-same-origin")
             end)
    end

    test "refuses to render a file that is not HTML", %{conn: conn, root: root} do
      conn = preview(conn, root, "notes.txt")

      assert conn.status == 415
      refute conn.resp_body =~ "plain notes"
    end

    test "refuses `..` traversal", %{conn: conn, root: root} do
      File.write!(Path.join(Path.dirname(root), "outside/evil.html"), "<h1>evil</h1>")

      conn = preview(conn, root, "../outside/evil.html")

      assert conn.status == 403
      refute conn.resp_body =~ "evil"
    end

    test "refuses a symlink inside the root that points out of it", %{
      conn: conn,
      root: root,
      outside: outside
    } do
      File.write!(Path.join(outside, "evil.html"), "<h1>evil</h1>")
      File.ln_s!(Path.join(outside, "evil.html"), Path.join(root, "escape.html"))

      conn = preview(conn, root, "escape.html")

      assert conn.status == 403
      refute conn.resp_body =~ "evil"
    end
  end

  describe "ExAthena.Web.Auth gates both routes" do
    setup do
      Application.put_env(:ex_athena, Auth, token: "s3cret")
      :ok
    end

    test "an unauthorized session gets 403 from download, not the bytes", %{
      conn: conn,
      root: root
    } do
      conn = download(conn, root, "notes.txt")

      assert conn.status == 403
      refute conn.resp_body =~ "plain notes"
    end

    test "an unauthorized session gets 403 from preview, not the bytes", %{
      conn: conn,
      root: root
    } do
      conn = preview(conn, root, "docs/brief.html")

      assert conn.status == 403
      refute conn.resp_body =~ "brief"
    end
  end
end
