# ex_athena — project notes

Rules that are true of THIS repo. The global rules still apply; nothing here
repeats them.

## Project source of truth

`docs/PROJECT.md` and its pages (`roadmap.md`, `architecture.md`, `risks.md`,
`decisions.md`) **do not exist yet** and must be created. Until they do, every
session that touches this repo should treat creating them as the first
outstanding task, and `README.md` must link to the hub near the top once it
exists.

There is an `adr/` directory with 20+ entries. It must be migrated into
`docs/decisions.md` — one dated entry per decision that still shapes the
system, dropping the ones that were really bug fixes — and then deleted, in
the same PR as the migration. **Do not add new ADRs.** Two entries matter
most to anyone touching the loop's mistake counter: `adr/0007` (propagate
resets through the parallel fold) and `adr/0020` (reset at the turn boundary,
not per call).

Once the pages exist: every PR that changes behaviour, structure, a risk or a
decision updates them in the SAME PR, and a merge is not finished until they
describe `main` as it now is.

## Every behaviour change updates `CHANGELOG.md`

A PR that changes behaviour adds its entry to `CHANGELOG.md` under
`## Unreleased`, in the same PR. Match the style already in the file: a bold
one-line claim, the issue link, then prose saying what was broken, what
changed, and what a user or host now sees differently — written for someone
who was not there. Every figure comes from the issue, the PR or the code;
never invent one. Group under `### Added` / `### Changed` / `### Fixed` /
`### Security`, and place the entry where the section reads well rather than
strictly by merge date.

## Running the tests

There is **no database**. Skip every DB and partition-setup step in the global
rules. The suite still needs `MIX_TEST_PARTITION` set, because `config/test.exs`
derives `:web_dir` from it to isolate the session store between concurrent runs:

    MIX_TEST_PARTITION=_issue_<num> mix test

Omitting it makes two concurrent runs share one web session directory, which
fails in ways that look like flakes but are not.

### Known failures that are not yours

Measured 2026-09-13 on `main` (`5db70d8`). Do not chase these:

* 3 symlink-canonicalisation tests in `ExAthena.ToolContextTest`.
* 1 `ExAthena.Tools.BashTest` confinement test, "writes inside a root
  succeed". NOT a missing `bwrap` — the binary is on PATH here
  (`/usr/bin/bwrap`, 0.8.0) and the test still fails. It cannot create a user
  namespace inside the dev container: `bwrap --dev-bind / / true` exits 1 with
  "No permissions to create new namespace". `ExAthena.Sandbox.available?/1`
  only checks that the helper exists, so the confined path runs, every command
  under it fails, and the write never lands. Run that one-liner before
  believing any other explanation.
* `ExAthena.Tools.AskUserTest` flakes intermittently.
* The LSP / `ImplicitDiagnostics` family flakes in CI; re-run the job once
  before treating a failure there as real.

## Design documents go in `docs/design/`, not `tmp/`

`tmp/` is gitignored, so an architecture brief or UI mock written there cannot
be committed and will be lost. Put anything that has to survive the session in
`docs/design/<issue>-<topic>.html`.

## What a worker leaves on disk

Three files per worker, all under

    <parent cwd>/.exathena/sessions/<parent_session_id>/

* `sidechains/<id>.jsonl` — `ExAthena.Agents.Sidechain`. The worker's
  **Result**: its final text, its `finish` deliverable, the run's counters, its
  conclusions and todos. Written before either result branch runs, on success
  and failure alike. It is NOT the worker's full prose — `Result.text` is only
  the last non-blank assistant message.
* `transcript/<id>.ndjson` — `ExAthena.Agents.Transcript`. What the worker
  **said**: one line per conversational turn, written as the turn happens.
  This is the full prose, and the only copy of it — see below.
* `journal/<id>.ndjson` — `ExAthena.Agents.Journal`. What the worker **did**:
  files with sizes, commands with exit codes. It refuses prose by design.

`ExAthena.Tools.ReadWorkerReport` reads all three (`source:` selects).

Before reaching for "persist the worker's output", check whether it is already
there — it usually is.

All three must be written under the **parent's** cwd. A `:worktree`-isolated
worker's own cwd is deleted by `finalize_isolation/1` moments later, so a file
written there is written into a grave (fixed in issue 216; the bug lived for
several releases because nothing read the file).

### The report is built, not caught

Since issue 251 the report the parent receives is written by
`ExAthena.Agents.Summariser` from the transcript, not taken from the worker's
final message. `agents.summarise_reports` turns it off (it is ON in
production and OFF in `config/test.exs`, because it adds one model call per
spawn and every mock responder would have to answer it).

One shape skips the summariser, and only one: a worker that called `finish`
with a `deliverable` has that deliverable handed up verbatim (issue 263).
`Result.deliverable_source` says which `finish` argument it came from, because
the other one — `summary` — is by its own schema a brief account of what was
done, which is the 251 pathology in a tool call. `Result.text` never skips the
summariser either, at any length: 251's failure was 545 characters long.

Do **not** try to recover a worker's prose from `Result.messages`. Compaction
replaces the middle of history while the worker is still running
(`Compactors.Summary`), and `Compactors.EpisodicArchive` keeps the sliced text
in `state.meta` — in memory, dying with the process. A report written at turn
19 is gone at turn 20. That is why the transcript is written turn by turn
instead.

## The mistake counter has three outcomes, not two

`ExAthena.Modes.ReAct` can bump it, reset it, or leave it alone. The third is
`{:error, :uncounted, text}` from a tool — a failure the model reads but the
loop does not score. See `ExAthena.Tool`'s `execute/2` contract and
`ExAthena.Loop.Terminations.budget_exhaustion?/1`.

Do **not** reach for `Terminations.category/1 == :capacity` to mean "ran out of
room". That category also covers `:error_consecutive_mistakes`,
`:error_no_progress` and `:error_max_structured_output_retries`, which are
faults that repeat when the work is re-issued.

## Adding a builtin tool

Two edits, and the second is easy to forget:

1. The module, implementing `ExAthena.Tool`.
2. `@builtins` in `lib/ex_athena/tools.ex`.

If the tool is orchestrator-scoped, also add it to the reject list AND a
`maybe_grant/3` line in `SpawnAgent.resolve_tools/3` — otherwise every worker
inherits it from the default ceiling and carries it as dead schema.
