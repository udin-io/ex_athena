defmodule ExAthena.Web.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ExAthena.Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # Shared-secret gate (no-op on the default loopback bind). The plug only
    # covers HTTP; the on_mount hook below is the real gate for the websocket.
    plug ExAthena.Web.Auth
  end

  # File bytes for the Files tab and for the paths auto-linked in a report
  # (issue #269). Same `:browser` pipeline, so `ExAthena.Web.Auth` gates these
  # exactly as it gates the chat. The root they serve from arrives as a token
  # this server signed, never as a caller-supplied directory.
  scope "/files", ExAthena.Web do
    pipe_through :browser

    get "/download", FileController, :download
    get "/preview", FileController, :preview
  end

  scope "/", ExAthena.Web.Live do
    pipe_through :browser

    # Both routes mount the same LiveView. `/c/:session_id` carries the stable
    # session id in the URL so a websocket reconnect re-mounts with the same id
    # and can re-attach to an in-flight run (see ChatLive.mount + RunServer).
    live_session :chat, on_mount: ExAthena.Web.Auth do
      live "/", ChatLive
      live "/c/:session_id", ChatLive
    end
  end
end
