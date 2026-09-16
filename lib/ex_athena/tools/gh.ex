defmodule ExAthena.Tools.Gh do
  @moduledoc """
  Read-only access to a repository via the `gh` (GitHub CLI) binary.

  This is the *reading* half of `gh`: issues, pull requests, the repo, releases,
  Actions runs, search, and auth status. Mutating commands (`gh pr create`,
  `gh api` with a body, …) are **refused by construction** — every command is
  validated against the same read-only `gh` whitelist the `:plan` phase uses
  for `bash`, so this tool is safe to grant in read-only agents (`explore`,
  `research`) and is honest about `read_only?/0`.

  Prefer this over `bash` when an agent in a read-only phase needs GitHub
  context (`gh issue view 123`, `gh pr list --state open`, …). `bash` is not in
  the read-only agents' tool ceiling; `gh` is. For mutating GitHub commands,
  use `bash` with host approval.

  Requires the `gh` binary on `PATH` and a logged-in `gh auth login` visible
  from `ctx.cwd`. Missing binary → a descriptive `{:error, …}`; not logged in →
  surfaced as a non-zero exit with `gh`'s own message (the model reads it).

  ## Arguments

    * `command` (required) — the `gh` subcommand, **without the `gh` prefix**,
      e.g. `"issue view 123 --comments"` or `"pr list --state open"`.
      Whitespace-separated tokens (avoid quoting; args with spaces are not split
      back together).
    * `timeout_ms` (optional, default 20_000, max 60_000).

  Output is capped (head + tail) the same way `bash` output is, so a large
  `--json` dump can't flood the context.
  """

  @behaviour ExAthena.Tool

  alias ExAthena.Tuning
  alias ExAthena.ToolContext

  @default_timeout 20_000
  @max_timeout 60_000
  # Grace over the configured timeout for the outer Task.yield backstop: long
  # enough for the closure's own `rescue` to report back, short enough that a
  # hung `gh` (slow network, a stuck pager) is killed promptly.
  @timeout_grace_ms 250
  # Same context-protection budget as `bash` output.
  @max_output_chars 16_000
  @head_share 0.75

  @impl true
  def name, do: "gh"

  @impl true
  def description,
    do:
      "Read GitHub (issues, PRs, repo, releases, Actions runs, search) via the `gh` CLI. " <>
        "Read-only: pass the subcommand after `gh`, e.g. \"issue view 123\" or " <>
        "\"pr list --state open\". Mutating commands are refused."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        command: %{
          type: "string",
          description:
            "The `gh` subcommand without the `gh` prefix, e.g. \"issue view 123\" or " <>
              "\"pr list --state open\"."
        },
        timeout_ms: %{
          type: "integer",
          description:
            "Request timeout (default #{Tuning.get(:tools, :gh_default_timeout_ms, @default_timeout)}, " <>
              "max #{Tuning.get(:tools, :gh_max_timeout_ms, @max_timeout)})."
        }
      },
      required: ["command"]
    }
  end

  @impl true
  def parallel_safe?, do: true

  @impl true
  def read_only?, do: true

  @impl true
  def execute(%{"command" => command} = args, %ToolContext{} = ctx) when is_binary(command) do
    cmd = String.trim(command)

    if cmd == "" do
      {:error, :missing_command}
    else
      # Read-only by construction — enforce it in every phase, not just `:plan`,
      # so the tool cannot be used to mutate GitHub even in a permissive phase.
      case ExAthena.Tools.Bash.read_only_violation(%{"command" => "gh " <> cmd}) do
        nil ->
          run(cmd, ctx, resolve_timeout(args))

        %{reason: reason} ->
          {:error, {:not_read_only, "gh: #{reason}. " <> readonly_hint()}}
      end
    end
  end

  def execute(_, _), do: {:error, :missing_command}

  defp readonly_hint,
    do:
      "This tool is read-only: `view`/`list`/`status`/`diff`/`checks` on " <>
        "issue/pr/repo/release/run, plus `gh search` and `gh status`. For mutating " <>
        "GitHub commands (create/close/comment), use the `bash` tool with approval."

  defp resolve_timeout(args) do
    case Map.get(args, "timeout_ms") do
      t when is_integer(t) and t > 0 ->
        min(t, Tuning.get(:tools, :gh_max_timeout_ms, @max_timeout))

      _ ->
        Tuning.get(:tools, :gh_default_timeout_ms, @default_timeout)
    end
  end

  # System.cmd has no timeout — wrap in a Task so a hung `gh` (slow network, a
  # stuck pager) can never wedge the agent loop. The closure catches its own
  # ErlangError (e.g. missing `gh`) so the linked Task can't crash us with an
  # exit signal. `ctx.assigns[:gh_binary]` is a host/test seam for binary
  # lookup (simulate a machine without `gh`); never model-controlled.
  defp run(command, %ToolContext{} = ctx, timeout) do
    gh = gh_binary(ctx)
    argv = gh_argv(command)
    started_at = System.monotonic_time(:millisecond)

    unless gh do
      no_gh_error()
    else
      task =
        Task.async(fn ->
          try do
            {:ran, System.cmd(gh, argv, cd: ctx.cwd, stderr_to_stdout: true)}
          rescue
            e in ErlangError -> {:raised, e.original}
          end
        end)

      case Task.yield(task, timeout + @timeout_grace_ms) || Task.shutdown(task) do
        {:ok, {:ran, {out, code}}} ->
          duration_ms = System.monotonic_time(:millisecond) - started_at
          ok(command, out, code, duration_ms)

        {:ok, {:raised, :enoent}} ->
          no_gh_error()

        {:ok, {:raised, other}} ->
          {:error, {:gh, inspect(other)}}

        _ ->
          {:error, :timeout}
      end
    end
  end

  defp gh_binary(ctx), do: ctx.assigns[:gh_binary] || System.find_executable("gh")

  defp gh_argv(command), do: String.split(command, ~r/\s+/, trim: true)

  defp no_gh_error,
    do:
      {:error,
       "gh binary not found — install GitHub CLI (https://cli.github.com) and run " <>
         "`gh auth login` in the working directory"}

  defp ok(command, out, code, duration_ms) do
    body = cap_output(out)
    llm = "exit #{code}\n" <> body

    ui = %{
      kind: :process,
      payload: %{
        command: "gh " <> command,
        exit_code: code,
        stdout: body,
        duration_ms: duration_ms
      }
    }

    {:ok, llm, ui}
  end

  # Keep a huge `--json` dump from flooding the context (observed live with
  # `bash` output). Head + tail survive; the cut is explicit so the model
  # narrows the command instead of assuming it saw everything.
  defp cap_output(body) do
    max = Tuning.get(:tools, :gh_output_chars, @max_output_chars)

    if byte_size(body) <= max do
      body
    else
      truncate_middle(body, max)
    end
  end

  defp truncate_middle(body, max) do
    head_chars = trunc(max * @head_share)
    tail_chars = max - head_chars
    cut = byte_size(body) - head_chars - tail_chars

    head = binary_part(body, 0, head_chars)
    tail = binary_part(body, byte_size(body) - tail_chars, tail_chars)

    head <>
      "\n…[truncated #{cut} chars — narrow the command (add --limit or fewer --json fields)]…\n" <>
      tail
  end
end
