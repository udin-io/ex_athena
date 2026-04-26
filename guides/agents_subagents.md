# Agents + subagents (v0.4)

A **subagent** is a synchronous nested `Loop.run/2` — a model
delegating focused work (exploration, planning, verification) to a
fresh conversation with its own message history. The parent only
pays for the subagent's final text, not its intermediate steps.

v0.4 turns subagents from "spawn another loop" into "isolated,
observable, configurable sub-runtimes" via three additions:

1. Custom **agent definitions** in markdown + YAML frontmatter.
2. Optional **git-worktree isolation** with safety checks.
3. **Sidechain transcripts** persisted to disk.

## Spawning

The model invokes the `SpawnAgent` builtin tool:

```text
spawn_agent(
  prompt: "explore the auth module and list public functions",
  agent: "explore",
  max_iterations: 8
)
```

`agent` is optional — if set, ex_athena resolves it against the agent
definition catalog and applies its frontmatter (`tools`,
`permissions`, `mode`, `model`, `provider`, `isolation`) to the
sub-loop opts. Explicit `tools` / `system_prompt` / `max_iterations`
args still override.

## Agent definitions

Files at `<cwd>/.exathena/agents/<name>.md`,
`~/.config/ex_athena/agents/<name>.md`, or shipped builtins in
`priv/agents/`. Resolution: builtin → user → project, later sources
overriding earlier ones.

### Frontmatter

```markdown
---
name: explore
description: Read-only fast investigation
model: claude-haiku-4-5
provider: anthropic
tools: [read, glob, grep, web_fetch]
permissions: plan
mode: react
isolation: in_process
---

You are a read-only research assistant. Walk the codebase and report
findings concisely. Do not modify any files.
```

| Field | Meaning |
|---|---|
| `name` | Required. The string the model passes as `agent: "..."`. |
| `description` | Required. One sentence; surfaces in tool docs. |
| `model` | Optional. Overrides the parent's `:model`. |
| `provider` | Optional. Overrides the parent's `:provider`. |
| `tools` | Optional. List of tool names. Overrides parent's tools. |
| `permissions` | Optional. One of `:plan` / `:default` / `:accept_edits` / `:trusted` / `:bypass_permissions`. |
| `mode` | Optional. `:react` / `:plan_and_solve` / `:reflexion`. Default `:react`. |
| `isolation` | Optional. `:in_process` (default) or `:worktree`. |

The body becomes a system-prompt addendum appended to whatever the
parent's system prompt was.

### Builtin definitions

Three ship in `priv/agents/`:

- **`general`** — full-tool default. Matches the prior `SpawnAgent`
  behaviour. Use when you need a sub-loop with the parent's full kit.
- **`explore`** — read-only investigation. Tools: `read`, `glob`,
  `grep`, `web_fetch`. Permissions: `:plan`. The right pick for
  "summarise this codebase" or "find the bug" sub-tasks.
- **`plan`** — analysis-only with writes restricted to
  `.exathena/plans/*.md`. Mode: `plan_and_solve`. The right pick for
  "produce a written plan I'll review before letting an agent
  execute".

Project + user definitions override builtins by name; e.g. dropping a
`<cwd>/.exathena/agents/explore.md` lets a project teach `explore` how
its codebase is organised.

## Worktree isolation

Setting `isolation: :worktree` in an agent definition asks the
runtime to create a git worktree for the subagent. Three safety checks
run before creation:

1. **`git` is on PATH.**
2. **`cwd` is inside a git work tree** (`git rev-parse --is-inside-work-tree`).
3. **The work tree is clean** (`git status --porcelain` returns empty).

If any check fails, the subagent transparently falls back to
`:in_process` and the fallback reason (`:no_git`, `:not_a_repo`,
`:dirty_tree`, `:create_failed`) flows through the `SubagentStart` hook
payload.

When all checks pass:

- A new branch is created: `ex_athena/<parent_session_id>-<agent-name>-<n>`
- The worktree lives at `~/.cache/ex_athena/worktrees/<parent_session_id>/<agent-name>-<n>`
- The sub-loop's `:cwd` becomes the worktree path.

After the subagent finishes:

| State | Action |
|---|---|
| Worktree has uncommitted changes | Kept. Path + branch surface in spawn result's `ui_payload`. |
| Worktree clean | `git worktree remove --force` cleans up. |

`ExAthena.Agents.WorktreeSweeper` is a one-shot at boot under the
application supervisor that runs `git worktree prune` and removes
cache entries older than 7 days.

### Permission reentrancy

The runtime invokes `git` directly via `System.cmd/3` — **not**
through `Tools.Bash` — so worktree creation/teardown bypasses the
parent's permission gate. Without this, a parent in `:plan` mode could
never spawn a worktree-isolated subagent (the `bash` calls would be
denied), defeating the point.

## Sidechain transcripts

Every subagent run writes its full transcript to:

```
<cwd>/.exathena/sessions/<parent_session_id>/sidechains/<subagent_id>.jsonl
```

The file contains one JSON object per line: prompt, opts (best-effort
inspect-serialised — closures and PIDs render as strings), and the
final result with `text`, `finish_reason`, `iterations`,
`tool_calls_made`, `duration_ms`, `cost_usd`.

The parent only sees the subagent's `text`. The full conversation
lives here for review, replay, and debugging.

## Hooks

`SubagentStart` and `SubagentStop` (see [hooks reference](hooks_reference.md)):

```elixir
ExAthena.run("...",
  tools: :all,
  hooks: %{
    SubagentStart: [fn p, _ ->
      Logger.info("subagent #{p.subagent_id} started: agent=#{p.agent} isolation=#{inspect(p.isolation)}")
      :ok
    end],
    SubagentStop: [fn p, _ ->
      Logger.info("subagent #{p.subagent_id} stopped: outcome=#{p.outcome}")
      :ok
    end]
  })
```

`SubagentStart` payload includes the resolved `agent` name and
`isolation` decision. `SubagentStop` includes the *finalized*
isolation state — `:worktree_kept`, `:worktree_removed`,
`:worktree_error`, or `{:in_process, reason}`.

## Spawn result UI payload

`SpawnAgent` returns the PR3b 3-tuple `{:ok, text, ui}` where `ui` is:

```elixir
%{
  kind: :subagent,
  payload: %{
    subagent_id: "subagent_2KLm9P",
    iterations: 5,
    tool_calls_made: 12,
    cost_usd: 0.014,
    duration_ms: 8230,
    isolation: {:worktree_kept, %{path: "...", branch: "ex_athena/...", parent_cwd: "..."}}
  }
}
```

Hosts watching the loop's `:tool_ui` event get this on every spawn
completion — useful for rendering "subagent ran for 8.2s, kept worktree
at /path" cards in a TUI or LiveView UI.

## Worked examples

### Investigate before changing

```elixir
# Parent agent uses `explore` to gather context, then `general` to act.
ExAthena.run("refactor the auth flow",
  tools: :all,
  cwd: project_root,
  assigns: %{
    spawn_agent_opts: [
      provider: :ollama,
      model: "qwen2.5-coder",
      memory: false  # subagents don't re-load AGENTS.md
    ]
  })
```

The model's first move is typically:

```text
spawn_agent(prompt: "List every file that imports MyApp.Auth", agent: "explore")
```

### Plan-then-execute pipeline

```elixir
# Define a custom workflow agent that uses `plan` then `general`.
File.write!(".exathena/agents/refactor.md", """
---
name: refactor
description: Two-phase refactor with planning + execution
mode: plan_and_solve
permissions: accept_edits
isolation: worktree
---

You are a refactoring specialist. Phase 1: read the relevant files
and produce a plan. Phase 2: implement the plan. Verify with tests.
""")

ExAthena.run("refactor the auth flow",
  tools: :all,
  assigns: %{spawn_agent_opts: [provider: :anthropic, model: "claude-sonnet-4-6"]})
```

The model spawns:

```text
spawn_agent(prompt: "Refactor MyApp.Auth into MyApp.Identity", agent: "refactor")
```

The refactor agent runs in an isolated worktree (clean tree assumed).
On completion, the parent gets the final summary text and a UI payload
with the worktree path/branch — the human reviews and merges.

## See also

- [`ExAthena.Agents`](https://hexdocs.pm/ex_athena/ExAthena.Agents.html)
- [`ExAthena.Agents.Definition`](https://hexdocs.pm/ex_athena/ExAthena.Agents.Definition.html)
- [`ExAthena.Agents.Worktree`](https://hexdocs.pm/ex_athena/ExAthena.Agents.Worktree.html)
- [Sessions + checkpoints](sessions_and_checkpoints.md) — sidechain
  transcripts share the JSONL store.
- [Hooks reference](hooks_reference.md) — Subagent* event payloads.
