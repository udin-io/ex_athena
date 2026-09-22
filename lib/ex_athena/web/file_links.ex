defmodule ExAthena.Web.FileLinks do
  @moduledoc """
  URLs for `ExAthena.Web.FileController`, and the signed root they carry.

  The root a request is confined to never arrives as a plain string. It is a
  `Phoenix.Token` signed with the endpoint's `secret_key_base`, minted only
  inside an authenticated LiveView from `socket.assigns.cwd`. A route that took
  the root as an ordinary parameter would let a client ask for
  `root=/&path=etc/shadow`, and the confinement check would then be checking
  the attacker's own answer.

  The token grants nothing the session did not already have: the LiveView will
  only sign a directory the user has opened, and its Files tab already browses
  that directory. Tokens expire after #{div(86_400, 3600)} hours and die with
  the endpoint's secret, so restarting the server invalidates every link a
  previous run handed out.
  """

  alias ExAthena.Web.Endpoint

  # Namespaced so a token minted here can never be replayed against another
  # `Phoenix.Token` consumer sharing the same secret.
  @salt "ex_athena:web:file_root"
  @max_age 86_400

  # Preview renders the bytes as a page. Only markup we are willing to put in a
  # sandboxed iframe qualifies; everything else downloads.
  @previewable ~w(.html .htm)

  @doc "Sign an absolute root directory into an opaque, expiring token."
  @spec sign_root(Path.t()) :: String.t()
  def sign_root(root) when is_binary(root) do
    Phoenix.Token.sign(Endpoint, @salt, root)
  end

  @doc """
  Recover the root from a token this server signed.

  `{:error, :invalid}` covers a forged, malformed, missing or expired token —
  the caller has nothing useful to tell them apart with, and saying which is
  an oracle.
  """
  @spec verify_root(term()) :: {:ok, Path.t()} | {:error, :invalid}
  def verify_root(token) when is_binary(token) do
    case Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age) do
      {:ok, root} when is_binary(root) -> {:ok, root}
      _ -> {:error, :invalid}
    end
  end

  def verify_root(_token), do: {:error, :invalid}

  @doc "URL that downloads `path` (relative to the root, or absolute inside it)."
  @spec download_url(String.t(), Path.t()) :: String.t()
  def download_url(root_token, path) do
    "/files/download?" <> URI.encode_query(root: root_token, path: path)
  end

  @doc "URL that renders `path` as a page inside a sandboxed iframe."
  @spec preview_url(String.t(), Path.t()) :: String.t()
  def preview_url(root_token, path) do
    "/files/preview?" <> URI.encode_query(root: root_token, path: path)
  end

  @doc "Whether `path` is markup the preview route will render."
  @spec previewable?(Path.t()) :: boolean()
  def previewable?(path) when is_binary(path) do
    String.downcase(Path.extname(path)) in @previewable
  end

  def previewable?(_path), do: false
end
