defmodule ExAthena.Sandbox do
  @moduledoc """
  OS-level command confinement for the Bash tool.

  When a run is confined (`ExAthena.ToolContext.allowed_roots` is set), shell
  commands are wrapped so they cannot write outside the roots:

    * **macOS** — `sandbox-exec` with a generated SBPL profile that allows reads,
      exec and network but denies all writes except under the roots and the OS
      temp dir.
    * **Linux** — `bwrap` (bubblewrap): the whole filesystem mounted read-only,
      the roots and the temp dir bind-mounted read-write.

  Reads and network stay open — that's the FS write boundary, not a full jail
  (network egress is handled separately by the web tools' SSRF guard). The OS
  temp dir stays writable so ordinary toolchains (compilers, `mktemp`) work.

  Where no sandbox helper is available the command is returned **unwrapped**
  as `{:unavailable, argv}` and the caller decides the policy. The Bash tool
  fails closed by default (`ExAthena.ToolContext.confine_mode` `:enforced`
  refuses to run) because we never fake confinement with a command-string scan
  (trivially bypassed via subshells/`eval`) — it's real-sandbox-or-refusal,
  with `:best_effort` as the explicit degrade-with-warning opt-in.
  """

  require Logger

  @type finder :: (String.t() -> String.t() | nil)

  @doc """
  Build the argv to run `command` confined to `roots` with working dir `cwd`.

  Returns `{:ok, {executable, args}}` when an OS sandbox is available, or
  `{:unavailable, {executable, args}}` (the bare `sh -c command`) otherwise.

  `opts`:

    * `:finder` — executable-lookup function (default
      `&System.find_executable/1`). A seam so hosts/tests can simulate a
      machine without the sandbox helper; never model-controlled.
  """
  @spec wrap(String.t(), [Path.t()], Path.t(), keyword()) ::
          {:ok, {String.t(), [String.t()]}} | {:unavailable, {String.t(), [String.t()]}}
  def wrap(command, roots, cwd, opts \\ []) when is_binary(command) and is_list(roots) do
    finder = finder(opts)
    sh = finder.("sh") || "/bin/sh"
    roots = Enum.map(roots, &Path.expand/1)

    case backend(finder) do
      {:macos, exe} ->
        {:ok, {exe, ["-p", macos_profile(roots), sh, "-c", command]}}

      {:linux, exe} ->
        {:ok, {exe, bwrap_args(roots, cwd) ++ [sh, "-c", command]}}

      :none ->
        {:unavailable, {sh, ["-c", command]}}
    end
  end

  @doc """
  Whether an OS sandbox helper is available on this host.

  Accepts the same `:finder` option as `wrap/4`.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []), do: backend(finder(opts)) != :none

  @doc """
  Name of the sandbox helper this platform needs (`"sandbox-exec"` on macOS,
  `"bwrap"` on other Unixes). Used to build actionable missing-helper errors.
  """
  @spec required_helper() :: String.t()
  def required_helper do
    case :os.type() do
      {:unix, :darwin} -> "sandbox-exec"
      {:unix, _} -> "bwrap"
      _ -> "sandbox-exec/bwrap"
    end
  end

  # ── platform detection ──

  defp finder(opts), do: Keyword.get(opts, :finder) || (&System.find_executable/1)

  defp backend(finder) do
    case :os.type() do
      {:unix, :darwin} ->
        with exe when is_binary(exe) <- find(finder, "sandbox-exec"), do: {:macos, exe}

      {:unix, _} ->
        with exe when is_binary(exe) <- find(finder, "bwrap"), do: {:linux, exe}

      _ ->
        :none
    end
  end

  defp find(finder, bin), do: finder.(bin) || :none

  # ── macOS: SBPL profile (pure) ──

  @doc false
  @spec macos_profile([Path.t()]) :: String.t()
  def macos_profile(roots) do
    writable =
      (roots ++ ["/private/tmp", "/private/var/folders", "/private/var/tmp", "/dev"])
      |> Enum.map(&~s|  (subpath "#{escape(&1)}")|)
      |> Enum.join("\n")

    """
    (version 1)
    (allow default)
    (deny file-write*)
    (allow file-write*
    #{writable})
    """
  end

  # SBPL string literals are double-quoted; escape backslashes and quotes.
  defp escape(path), do: path |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

  # ── Linux: bwrap args (pure) ──

  @doc false
  @spec bwrap_args([Path.t()], Path.t()) :: [String.t()]
  def bwrap_args(roots, cwd) do
    binds = Enum.flat_map(roots, fn r -> ["--bind", r, r] end)

    ["--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--bind", "/tmp", "/tmp"] ++
      binds ++ ["--chdir", cwd, "--"]
  end
end
