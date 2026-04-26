defmodule ExAthena.Memory do
  @moduledoc """
  File-based project memory.

  Loads `AGENTS.md` (preferred) / `CLAUDE.md` files from a small fixed
  hierarchy and turns them into messages the agent sees on every turn.

  The hierarchy, in load order, is:

    1. **User-level** — `~/.config/ex_athena/AGENTS.md` (or `CLAUDE.md`).
       Cross-project preferences a user wants every agent to honour.
    2. **Project-level** — `<cwd>/AGENTS.md` (or `CLAUDE.md`).
       Repository conventions; usually committed.
    3. **Local override** — `<cwd>/AGENTS.local.md`.
       Personal scratch on top of project conventions; usually
       gitignored.

  When both `AGENTS.md` and `CLAUDE.md` exist at the same level, the
  `AGENTS.md` file wins (matches opencode's behaviour for cross-tool
  compatibility).

  ## Where the messages live

  Every loaded file becomes a single user-role message tagged
  `name: "memory"` — placed at the front of the conversation so it
  precedes the user's first prompt. The Claude Code paper notes that
  Claude Code delivers memory as user-context (probabilistic compliance)
  rather than as a system prompt (deterministic compliance), and we
  copy that pattern.

  The compactor pipeline pins these messages: see
  `ExAthena.Memory.pinned_count/1`.
  """

  alias ExAthena.Messages
  alias ExAthena.Messages.Message

  @user_dir Path.expand("~/.config/ex_athena")
  @memory_filenames ["AGENTS.md", "CLAUDE.md"]
  @local_override "AGENTS.local.md"

  @doc """
  Discover and load the memory hierarchy for `cwd`. Returns a list of
  `Message.t()` in load order.

  Each file's contents are wrapped with a header that names the source so
  the model can tell them apart. Empty / missing files are skipped.

  ## Options

    * `:user_dir` — override the user-level memory directory. Defaults to
      `~/.config/ex_athena/`. Useful in tests.
    * `:filenames` — override the candidate filenames (defaults to
      `["AGENTS.md", "CLAUDE.md"]`).
  """
  @spec discover(String.t(), keyword()) :: [Message.t()]
  def discover(cwd, opts \\ []) when is_binary(cwd) do
    user_dir = Keyword.get(opts, :user_dir, @user_dir)
    names = Keyword.get(opts, :filenames, @memory_filenames)

    [
      {:user, find_first_existing(user_dir, names)},
      {:project, find_first_existing(cwd, names)},
      {:local, file_if_present(Path.join(cwd, @local_override))}
    ]
    |> Enum.flat_map(&load_one/1)
  end

  @doc """
  Number of pinned-prefix slots the compactor must preserve for memory
  messages already prepended to `messages`. Used by
  `ExAthena.Compactors.Summary` (and the PR2 pipeline) to compute the
  effective floor for the pinned prefix.
  """
  @spec pinned_count([Message.t()]) :: non_neg_integer()
  def pinned_count(messages) when is_list(messages) do
    Enum.count(messages, &memory_message?/1)
  end

  @doc "Is `message` a memory user-context message produced by `discover/2`?"
  @spec memory_message?(Message.t() | term()) :: boolean()
  def memory_message?(%Message{role: :user, name: "memory"}), do: true
  def memory_message?(_), do: false

  # ── Internal ──────────────────────────────────────────────────────

  defp load_one({_level, nil}), do: []

  defp load_one({level, path}) do
    case File.read(path) do
      {:ok, body} ->
        body = String.trim(body)
        if body == "", do: [], else: [build_message(level, path, body)]

      {:error, _} ->
        []
    end
  end

  defp build_message(level, path, body) do
    header = "<!-- memory: #{level} #{path} -->\n"
    Messages.user(header <> body) |> Map.put(:name, "memory")
  end

  defp find_first_existing(dir, names) do
    Enum.find_value(names, fn name ->
      candidate = Path.join(dir, name)
      if File.regular?(candidate), do: candidate, else: nil
    end)
  end

  defp file_if_present(path) do
    if File.regular?(path), do: path, else: nil
  end
end
