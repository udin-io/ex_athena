defmodule ExAthena.Web.PathLinks do
  @moduledoc """
  Turns the file paths a run names in its prose into links.

  A report ends by naming what it wrote — `docs/design/brief.html`,
  `lib/ex_athena/modes/re_act.ex` — and until issue #269 those were dead text.
  `linkify/2` rewrites each one as a link that opens the file in the Files tab,
  followed by a small download link.

  ## Conservative on purpose

  A false link is worse than a missed one. Reports are dense with dotted
  identifiers that look exactly like filenames — `Fudu.Accounts.TenantClaim`,
  `ExAthena.Loop.Terminations`, `Req.Test` — and turning those into links would
  litter every paragraph. Three tests must all pass, and anything failing one
  is escaped as ordinary text:

    1. **Shape.** The candidate contains a `/`, or is a dotted name whose last
       segment is 1–8 alphanumeric characters (so `mix.exs` qualifies and
       `Fudu.Accounts.TenantClaim` does not).
    2. **Existence.** `File.regular?/1`. A directory has no bytes to serve and
       a path that was never written is not worth a broken link.
    3. **Confinement.** `ExAthena.Web.Files.resolve/2` — the same guard the
       HTTP routes and the file tools use — must land it inside the open root.
       `..`, an absolute path elsewhere and an escaping symlink all fail here.

  Matching works on whitespace-separated tokens rather than a regex swept over
  the whole line, so a link can only ever replace a whole word. Wrapping
  brackets and trailing punctuation are peeled off first, because reports write
  "wrote `docs/brief.html`, then stopped".

  ## Cost

  Each shaped candidate costs one `stat`. A long report stats a few hundred
  times per render, on the order of a millisecond, and only for finalized text
  — streaming text is rendered raw and never reaches here.
  """

  alias ExAthena.Web.FileLinks
  alias ExAthena.Web.Files
  alias Phoenix.HTML.Safe

  # Peel wrappers and trailing punctuation off a token before testing it.
  # Lazy `core` with an anchored `trail` makes the trailing run as long as the
  # character class allows, so "brief.html," yields core "brief.html".
  @token_shape ~r/\A(?<lead>[\(\[\{"'`<]*)(?<core>.*?)(?<trail>[,.;:!?\)\]\}"'`>]*)\z/s

  # A path with a separator: optional `~`, `.` or `..` prefix, then segments.
  @with_slash ~r|\A[~.]{0,2}/?(?:[\w.@+-]+/)*[\w.@+-]+\z|

  # A bare filename: dotted, and the extension is short. The length cap is what
  # keeps `Fudu.Accounts.TenantClaim` out.
  @dotted ~r/\A[\w@+-]+(?:\.[\w@+-]+)*\.[A-Za-z0-9]{1,8}\z/

  @min_length 3

  @type links :: %{root: Path.t(), token: String.t()} | nil

  @doc """
  Escape `text`, linking every token that survives the three tests.

  Returns HTML-safe iodata. With `nil` links (no folder open) it is exactly
  `Phoenix.HTML.Safe.to_iodata/1`.
  """
  @spec linkify(String.t(), links()) :: iodata()
  def linkify(text, %{root: root, token: token})
      when is_binary(text) and is_binary(root) and is_binary(token) do
    ~r/(\s+)/
    |> Regex.split(text, include_captures: true)
    |> Enum.map(&render_token(&1, root, token))
  end

  def linkify(text, _links), do: escape(text)

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp render_token(token, root, root_token) do
    %{"lead" => lead, "core" => core, "trail" => trail} =
      Regex.named_captures(@token_shape, token)

    case resolve(core, root) do
      {:ok, absolute} -> [escape(lead), anchor(core, absolute, root_token), escape(trail)]
      :error -> escape(token)
    end
  end

  defp resolve(core, root) do
    with true <- shaped?(core),
         {:ok, absolute} <- Files.resolve(root, core),
         true <- File.regular?(absolute) do
      {:ok, absolute}
    else
      _not_a_file_in_the_root -> :error
    end
  end

  defp shaped?(core) do
    cond do
      byte_size(core) < @min_length -> false
      String.contains?(core, "/") -> Regex.match?(@with_slash, core)
      true -> Regex.match?(@dotted, core)
    end
  end

  # The label keeps the path as the report wrote it; the click and the download
  # both carry the resolved absolute path, so neither depends on re-resolving
  # the same relative spelling later.
  defp anchor(label, absolute, root_token) do
    [
      ~s(<a class="path-link" phx-click="files_open" phx-value-path="),
      escape(absolute),
      ~s(" title="Open in the Files tab">),
      escape(label),
      ~s(</a><a class="path-dl" href="),
      escape(FileLinks.download_url(root_token, absolute)),
      ~s(" title="Download ),
      escape(Path.basename(absolute)),
      ~s(">&#8595;</a>)
    ]
  end

  defp escape(value), do: Safe.to_iodata(value)
end
