defmodule ExAthena.Tools.Bash do
  @moduledoc """
  Executes a shell command via `/bin/sh -c` with a configurable timeout.

  Arguments:

    * `command` (required) — the shell command.
    * `timeout_ms` (optional, default 120_000, max 600_000).

  Returns captured stdout+stderr plus the exit code. Timeouts kill the spawned
  process and surface `{:error, :timeout}` to the loop.

  Runs with `cd: ctx.cwd`, `stderr_to_stdout: true`. No input redirection.

  When the run is confined (`ctx.allowed_roots` is set), the command is wrapped
  in an OS sandbox (`ExAthena.Sandbox`) that blocks writes outside the roots.
  If no sandbox helper (`sandbox-exec`/`bwrap`) is available the tool **fails
  closed**: it refuses to run and returns
  `{:error, {:sandbox_unavailable, helper}}` naming the missing helper —
  running unconfined would silently break the confinement contract, and a
  command-string scan is never a substitute (trivially bypassed). Hosts that
  accept degradation opt in with `confine: :best_effort` on the run
  (`ctx.confine_mode == :best_effort`), which runs the command unconfined with
  a logged warning. Either way an `[:ex_athena, :sandbox, :unavailable]`
  telemetry event is emitted.
  """

  @behaviour ExAthena.Tool

  require Logger

  alias ExAthena.Tuning

  @default_timeout 120_000
  @max_timeout 600_000

  # Output cap: an uncapped `find .` dumped megabytes into a worker's
  # context (observed live: 204k input tokens by iteration 24 → starved to
  # error_max_turns). Head + tail survive; the cut is explicit so the model
  # narrows the command instead of assuming it saw everything.
  @max_output_chars 16_000

  # How much of the cap goes to the head. The tail takes the rest, so the two
  # always sum to the cap however it is configured — deriving them beats three
  # independent knobs a host could set into an inconsistent triple (a cap
  # smaller than head+tail made `binary_part/3` raise on a negative length).
  @head_share 0.75

  # Deny patterns — a first-pass backstop that marks a command as
  # write/destructive regardless of what the allowlist below would say.
  # Retained from the original (blocklist-only) classifier as
  # defense-in-depth; the actual read-only decision is allowlist-based
  # (see `read_only_command?/1`).
  # Each carries the label used in the denial. "matches a known write
  # pattern" named nothing the model could act on; saying which construct
  # tripped turns a blind retry into a corrected one.
  @write_patterns [
    {~r/\b(mkdir|touch|rm|mv|cp|chmod|chown)\b/, "a filesystem-modifying command"},
    {~r/\bgit\s+(add|commit|push|merge|rebase|checkout|reset|clean|stash|branch\s+-[dD])\b/,
     "a git subcommand that writes to the repository"},
    {~r/\b(npm|yarn|pnpm|mix|bundle|pip|cargo)\s+(install|add|remove|update|new|init)\b/,
     "a package-manager command that installs or modifies dependencies"},
    {~r/\bmix\s+(ecto\.migrate|ecto\.create|ecto\.rollback|ecto\.gen\.migration|ash\.codegen|phx\.gen)\b/,
     "a mix task that generates or migrates"},
    {~r/[>|]\s*tee\b/, "a `tee` redirect"},
    {~r/>>?\s/, "a file redirect (`>`)"},
    {~r/\bsed\s+-i\b/, "an in-place `sed -i` edit"},
    {~r/\bdd\b/, "`dd`"},
    {~r/\btruncate\b/, "`truncate`"},
    {~r/\bcurl\b.*-[oO]\b/, "a `curl` download that writes a file"},
    {~r/\bwget\b/, "`wget`"}
  ]

  # Commands whose plain invocation is read-only. The head of EVERY shell
  # segment (split on `;`, `&&`, `||`, `|`, `&`, newline) must appear here —
  # or be one of the subcommand-gated commands below (git/gh/mix/find/sort) —
  # for the whole invocation to classify read-only. Anything unknown
  # (including interpreters: python/perl/ruby/node/sh/ex/ed/…) is treated
  # as MUTATING: interpreters execute arbitrary code, so a blocklist can
  # never enumerate the write verbs.
  #
  # `cd` is here because it moves the shell's own working directory and
  # nothing else. It grants no reach either: `cat` is already allowed and
  # takes absolute paths, so anything reachable after a `cd` was reachable
  # before it. Its absence denied every `cd repo && <read-only cmd>` chain,
  # which is how models habitually scope a command to a project.
  @readonly_commands ~w(
    cd
    cat tac ls dir grep egrep fgrep rg ag ack head tail wc file stat pwd
    tree du df basename dirname realpath readlink which type whereis
    whoami id groups date cal uptime uname hostname printenv echo printf
    uniq cut tr diff comm column nl od strings hexdump xxd less more
    man apropos jq yq ps lsof locale arch nproc sw_vers seq expr
    md5sum shasum sha256sum cksum true false test
  )

  # git subcommands that only inspect the repository. Deliberately excludes
  # branch/tag/stash/remote/config/worktree — their bare forms list, but
  # their argument forms create/delete, and telling those apart reliably
  # is not worth the risk in a read-only phase.
  @git_readonly_subcommands ~w(
    status log diff show blame grep shortlog describe rev-parse ls-files
    ls-tree ls-remote cat-file reflog help version var count-objects
  )

  # gh: `gh <group> <verb>` is read-only only for these verbs
  # (view/list/status/diff/checks); `gh api` can POST, so it is excluded.
  @gh_readonly_verbs ~w(view list status diff checks)

  # mix tasks that only read project state. Excludes compile/test — they
  # execute arbitrary project code and write _build.
  @mix_readonly_tasks ~w(help deps deps.tree app.tree xref hex.info hex.search hex.outdated)

  # find actions that mutate or execute — a `find` carrying any of these is
  # not read-only.
  @find_mutating_flags ~w(-delete -exec -execdir -ok -okdir -fprint -fprintf -fls)

  @impl true
  def name, do: "bash"

  @impl true
  def description,
    do: "Run a shell command in the working directory. Captures stdout+stderr and the exit code."

  # Arity-0 and therefore argument-blind: `bash` as a *tool* can run anything,
  # so it can never declare itself read-only. Per-invocation classification
  # lives in `read_only_command?/1` below, which the permissions layer calls
  # instead for this tool.
  @impl true
  def read_only?, do: false

  @doc """
  Classify a bash invocation's `args` as read-only or not. Used by the
  permissions layer to allow read-only bash calls (cat, ls, grep, git log,
  gh issue view, …) during `:plan` phase while still denying mutations
  (rm, mkdir, redirects, git add/commit, mix ecto.migrate, …).

  **Allowlist-based**: a command is read-only only when every shell segment
  (split on `;`, `&&`, `||`, `|`, `&`, newline) starts with a command known
  to be read-only. Unknown commands — including interpreter one-liners like
  `python -c`, `perl -e`, `ruby -e`, `node -e`, and editors like `ex`/`ed` —
  are treated as MUTATING, because arbitrary code execution can never be
  proven read-only by a string scan. Command substitution (`$(…)`, backticks)
  and file redirects (except `2>&1`-style fd duplication and `/dev/null`
  discards) also disqualify a command.

  Missing/empty command → `false` (treat as not read-only so the model gets
  a clear phase-gated denial rather than a silent allow).

  This classifier gates the `:plan` phase only; it is advisory next to the
  OS sandbox (`ExAthena.Sandbox`) which enforces write confinement for
  confined runs regardless of phase.
  """
  @spec read_only_command?(map()) :: boolean()
  def read_only_command?(args), do: is_nil(read_only_violation(args))

  @doc """
  Why `args` failed to classify read-only, or `nil` when it is read-only.

  Returns `%{reason: String.t(), segment: String.t() | nil}`. `segment` names
  the offending command (`"cd"`, `"git commit"`) when a single shell segment
  is at fault, and is `nil` when the whole invocation is disqualified by a
  construct — command substitution, a write pattern, a file redirect.

  `read_only_command?/1` answers *whether*; a model that chained four
  segments also needs *which*. Denying with only "not recognized as
  read-only" sent a live subagent into a retry loop, re-sending the same
  shape three times because nothing told it which part lost.
  """
  @spec read_only_violation(map()) :: nil | %{reason: String.t(), segment: String.t() | nil}
  def read_only_violation(%{"command" => cmd}) when is_binary(cmd) and cmd != "" do
    trimmed = String.trim(cmd)
    stripped = strip_quoted(trimmed)

    # Harmless redirect forms are erased before the redirect scan AND the
    # segment split (`2>&1` contains `&`, which would otherwise split into
    # a bogus `1` segment).
    normalized =
      stripped
      |> String.replace(~r{\d*>&\d+}, " ")
      |> String.replace(~r{\d*>>?\s*/dev/null}, " ")

    cond do
      # Command substitution can hide arbitrary writes inside a read-only
      # head (`cat $(rm -rf x)`), including inside double quotes.
      String.contains?(trimmed, "$(") or String.contains?(trimmed, "`") ->
        violation("command substitution (`$(…)` or backticks) can hide writes")

      # Backstop deny patterns (checked against the quote-stripped command so
      # quoted text — e.g. `grep "rm -rf" lib/` — doesn't false-positive).
      label = matched_write_pattern(stripped) ->
        violation("it contains #{label}")

      # Any remaining `>` is a file redirect — a write.
      String.contains?(normalized, ">") ->
        violation("it contains a file redirect (`>`)")

      true ->
        case segments(normalized) do
          [] ->
            violation("the command is empty")

          segs ->
            case Enum.find(segs, &(not segment_read_only?(&1))) do
              nil ->
                nil

              segment ->
                name = segment_name(segment)

                %{
                  reason: "`#{name}` is not recognized as read-only",
                  segment: name
                }
            end
        end
    end
  end

  def read_only_violation(_), do: violation("no command was given")

  defp violation(reason), do: %{reason: reason, segment: nil}

  defp matched_write_pattern(cmd) do
    Enum.find_value(@write_patterns, fn {pattern, label} ->
      if Regex.match?(pattern, cmd), do: label
    end)
  end

  # The actionable part of a failing segment: the command, plus enough of its
  # verb to be correctable. `git commit` fails on `commit`, not on `git`, and
  # saying "git" would send a model in circles. `gh` groups one level deeper
  # (`gh <group> <verb>`), so it needs both words — reporting "gh pr" would
  # read as though no `gh pr` command were allowed, when `gh pr view` is.
  defp segment_name(segment) do
    case String.split(segment, ~r/\s+/, trim: true) do
      [] ->
        segment

      [head | rest] ->
        base = Path.basename(head)
        verbs = Enum.reject(rest, &String.starts_with?(&1, "-"))

        case base do
          "gh" -> Enum.join([base | Enum.take(verbs, 2)], " ")
          gated when gated in ~w(git mix) -> Enum.join([base | Enum.take(verbs, 1)], " ")
          _ -> base
        end
    end
  end

  # Replace quoted spans with a placeholder so quoted metacharacters
  # (`grep -E "foo|bar"`) neither split segments nor trip deny patterns.
  # Unbalanced quotes leave text in place — conservative: it can only cause
  # a deny, never an allow.
  defp strip_quoted(cmd), do: Regex.replace(~r/"[^"]*"|'[^']*'/, cmd, "_")

  defp segments(cmd) do
    cmd
    |> String.split(~r/&&|\|\||[;|&\n]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp segment_read_only?(segment) do
    tokens =
      segment
      |> String.split(~r/\s+/, trim: true)
      # `FOO=bar cmd` — skip leading environment assignments.
      |> Enum.drop_while(&Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, &1))

    case tokens do
      [] ->
        false

      [head | rest] ->
        case Path.basename(head) do
          "git" -> match?([sub | _] when sub in @git_readonly_subcommands, rest)
          "gh" -> gh_read_only?(rest)
          "mix" -> match?([task | _] when task in @mix_readonly_tasks, rest)
          "find" -> not Enum.any?(rest, &(&1 in @find_mutating_flags))
          "fd" -> not Enum.any?(rest, &(&1 in ["-x", "--exec", "-X", "--exec-batch"]))
          "sort" -> "-o" not in rest and "--output" not in rest
          base -> base in @readonly_commands
        end
    end
  end

  defp gh_read_only?(["status" | _]), do: true
  defp gh_read_only?(["auth", "status" | _]), do: true
  defp gh_read_only?(["search" | _]), do: true
  defp gh_read_only?([_group, verb | _]) when verb in @gh_readonly_verbs, do: true
  defp gh_read_only?(_), do: false

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        command: %{type: "string"},
        timeout_ms: %{type: "integer", description: "default 120_000, max 600_000"}
      },
      required: ["command"]
    }
  end

  @impl true
  def execute(%{"command" => command} = args, ctx) when is_binary(command) do
    timeout =
      case Map.get(args, "timeout_ms") do
        t when is_integer(t) and t > 0 -> min(t, @max_timeout)
        _ -> @default_timeout
      end

    run(command, ctx, timeout)
  end

  def execute(_, _), do: {:error, :missing_command}

  # Unconfined: bare `sh -c`. Confined: wrap in an OS sandbox restricted to the
  # roots; if no sandbox helper exists, fail closed (`:enforced`, the default)
  # or — only on an explicit `confine: :best_effort` opt-in — warn and run
  # unconfined. Never a bypassable command-string scan.
  defp run(command, ctx, timeout) do
    with {:ok, {exe, args}} <- sandboxed_argv(command, ctx) do
      port =
        Port.open({:spawn_executable, exe}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args,
          cd: ctx.cwd
        ])

      started_at = System.monotonic_time(:millisecond)
      deadline = started_at + timeout
      collect(port, [], deadline, command, started_at)
    end
  end

  defp sandboxed_argv(command, %{allowed_roots: nil}) do
    {:ok, {System.find_executable("sh") || "/bin/sh", ["-c", command]}}
  end

  defp sandboxed_argv(command, %{allowed_roots: roots} = ctx) do
    # `:sandbox_finder` in assigns is a host/test seam for executable lookup
    # (simulate a helperless machine); never model-controlled.
    wrap_opts =
      case Map.get(ctx.assigns || %{}, :sandbox_finder) do
        finder when is_function(finder, 1) -> [finder: finder]
        _ -> []
      end

    case ExAthena.Sandbox.wrap(command, roots, ctx.cwd, wrap_opts) do
      {:ok, argv} ->
        {:ok, argv}

      {:unavailable, argv} ->
        helper = ExAthena.Sandbox.required_helper()

        if Map.get(ctx, :confine_mode) == :best_effort do
          emit_sandbox_unavailable(ctx, helper, :ran_unconfined)

          Logger.warning(
            "[ExAthena.Bash] confinement requested but no OS sandbox helper " <>
              "(#{helper}) is available — running the command UNCONFINED " <>
              "(confine: :best_effort)"
          )

          {:ok, argv}
        else
          emit_sandbox_unavailable(ctx, helper, :denied)
          {:error, {:sandbox_unavailable, helper}}
        end
    end
  end

  defp emit_sandbox_unavailable(ctx, helper, outcome) do
    ExAthena.Telemetry.event([:ex_athena, :sandbox, :unavailable], %{}, %{
      helper: helper,
      outcome: outcome,
      session_id: ctx.session_id
    })
  end

  defp collect(port, acc, deadline, command, started_at) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        kill(port)
        {:error, :timeout}

      true ->
        receive do
          {^port, {:data, data}} ->
            collect(port, [data | acc], deadline, command, started_at)

          {^port, {:exit_status, code}} ->
            body = acc |> Enum.reverse() |> IO.iodata_to_binary() |> cap_output()
            duration_ms = System.monotonic_time(:millisecond) - started_at
            llm = "exit #{code}\n" <> body

            ui = %{
              kind: :process,
              payload: %{
                command: command,
                exit_code: code,
                stdout: body,
                duration_ms: duration_ms
              }
            }

            {:ok, llm, ui}
        after
          remaining ->
            kill(port)
            {:error, :timeout}
        end
    end
  end

  defp cap_output(body) do
    max = Tuning.get(:bash, :max_output_chars, @max_output_chars)

    if byte_size(body) <= max, do: body, else: truncate_middle(body, max)
  end

  defp truncate_middle(body, max) do
    head_chars = trunc(max * @head_share)
    tail_chars = max - head_chars
    cut = byte_size(body) - head_chars - tail_chars

    head = binary_part(body, 0, head_chars)
    tail = binary_part(body, byte_size(body) - tail_chars, tail_chars)

    head <>
      "\n…[truncated #{cut} chars — narrow the command (use head/grep/max_results)]…\n" <>
      tail
  end

  defp kill(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end
end
