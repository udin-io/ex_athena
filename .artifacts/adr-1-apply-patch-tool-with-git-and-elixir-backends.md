# ADR: ApplyPatch tool with git-apply backend and bounded Elixir fallback

## Status

Accepted

## Context

The existing `ExAthena.Tools.Edit` tool handles a single contiguous change per call. Multi-region or multi-file refactors require N sequential tool calls, each a network roundtrip. On a recent 7-file conflict resolution this cost ~297s, dominated by sequencing rather than reasoning. Modern LLMs natively emit unified diffs when asked to refactor; the current toolset forces them to translate diffs into discrete edits.

OpenCode ships an `apply_patch` tool with the same shape we want: a single unified-diff input applied atomically across one or more files. Git's `git apply` already understands the format and provides high-quality error messages on context mismatch.

## Decision

1. Add `ExAthena.Tools.ApplyPatch` accepting `{patch: string, dry_run?: boolean}` in unified-diff format.
2. Apply atomically: any hunk failing context match aborts the entire patch with no on-disk side effects.
3. Backend selection at execution time:
   - When `cwd` is inside a git work tree (probed with `git rev-parse --is-inside-work-tree`), shell out to `git apply --whitespace=nowarn` (and `--check` for dry-run). Atomicity comes from `git apply` itself.
   - Otherwise, a pure-Elixir parser/applier scoped to standard unified-diff hunks. Two-pass design: compute new contents for every file in memory; only write when every hunk validates.
4. v1 explicitly does not support binary diffs, `/dev/null` create/delete, rename detection beyond what unified-diff carries, or fuzzy context matching. Unsupported features return a structured error so the model can retry.
5. Path safety, snapshot, and permission/hook integration reuse existing infrastructure (`ToolContext.resolve_path/2`, `ExAthena.Checkpoint.snapshot/3`, the loop's tool dispatch). No new wiring inside ex_athena.

## Consequences

### Positive

- One tool call replaces N edits for multi-file refactors. Direct latency win on the SDK conflict-resolution path.
- The git backend leverages a battle-tested parser and produces high-quality error messages.
- Atomic semantics avoid half-applied refactors.
- The Elixir fallback keeps the tool usable in non-git working directories without a hard dependency on git.
- Reuses existing path safety and snapshot mechanisms — no new attack surface.

### Negative

- Two backends to maintain. Mitigated by keeping the Elixir backend deliberately small (no fuzz, no binary, no rename, no /dev/null).
- Hosts (e.g., `udin_code`) must extend any `Edit|Write` matchers in permission rules and hooks to include `ApplyPatch`. Tracked as a separate ticket.
- `git apply` error output format is not stable across git versions; we surface it verbatim rather than parsing it.

### Neutral

- No conflict with existing ADRs (tool-call parsing, schema compaction, structured output, assistant-message replay).
