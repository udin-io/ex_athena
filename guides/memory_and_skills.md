# Memory + Skills (v0.4)

ex_athena ships two file-based context mechanisms that let projects
teach the agent things without code changes: **memory** (rules the
agent should always know) and **skills** (instructions the agent loads
on demand).

Both are auto-discovered at `Loop.run/2` start. Both can be disabled
or overridden per-call.

## Memory — `AGENTS.md` / `CLAUDE.md`

Drop an `AGENTS.md` (preferred) or `CLAUDE.md` at your project root
and ex_athena prepends its contents as a user-context message at the
very front of every conversation:

```
project root/
  AGENTS.md            # project-wide rules (committed)
  AGENTS.local.md      # personal scratch (gitignore this one)
  src/...
```

Plus a global personal file at `~/.config/ex_athena/AGENTS.md` for
cross-project preferences.

Load order (each level is a separate user-context message):

1. **User** — `~/.config/ex_athena/AGENTS.md`
2. **Project** — `<cwd>/AGENTS.md` (or `CLAUDE.md` as a fallback)
3. **Local override** — `<cwd>/AGENTS.local.md`

`AGENTS.md` wins over `CLAUDE.md` at the same level — matches opencode
for cross-tool compatibility.

### Why user-context, not system?

The Claude Code paper notes that Claude Code delivers memory as
user-context (probabilistic compliance) rather than as a system prompt
(deterministic compliance). We copy the pattern: each loaded file
becomes a `%Message{role: :user, name: "memory"}` placed at the front
of the conversation.

The compactor pins these messages — `Compactors.Summary` extends its
effective pinned-prefix by `meta[:memory_count]` so memory messages
survive every compaction cycle.

### Disable or override

```elixir
# Skip memory entirely
ExAthena.run("hi", tools: :all, memory: false)

# Provide an explicit list (e.g. dynamically constructed for a tenant)
ExAthena.run("hi",
  tools: :all,
  memory: [
    ExAthena.Messages.user("...your custom rules...")
    |> Map.put(:name, "memory")
  ])
```

## Skills — `SKILL.md` with progressive disclosure

A skill is a directory containing a `SKILL.md` markdown file. The
file's frontmatter is auto-injected into the system prompt; the body
loads only when the model decides it needs the skill.

```
project root/
  .exathena/skills/
    deploy/SKILL.md
    audit/SKILL.md
```

Plus the user-level home at `~/.config/ex_athena/skills/<name>/SKILL.md`.

### `SKILL.md` shape

```markdown
---
name: deploy
description: Ship the staging branch to production
allowed-tools: [bash, read]
disable-model-invocation: false
---

# How to deploy

1. Run `mix test` and ensure it passes.
2. Run `bin/deploy` and wait for the green check.
3. Tail `prod-logs` for two minutes; abort + revert on errors.
```

Required: `name`, `description`. Optional:
- `allowed-tools` — restricts which tools can run while the skill is
  active (PR3a's `:active_skills` permission scoping).
- `disable-model-invocation` — hides the skill from the catalog. The
  host can still pre-attach via `Skills.preload/3`.

### Two activation paths

**Sentinel auto-load.** When the model writes `[skill: deploy]` in its
response, the loop intercepts it (after extracting tool calls, before
the next iteration) and appends the skill body as a system-role message.
Idempotent — already-loaded skills are no-ops:

```text
Model says: "I'll [skill: deploy] this branch."
↓
Loop appends a system message tagged `name: "skill:deploy"` containing
the SKILL.md body. The model sees it on the next iteration.
```

**Pre-load.** The host knows up-front which skills the agent will need:

```elixir
ExAthena.run("ship it",
  tools: :all,
  preload_skills: ["deploy", "audit"])
```

Pre-loaded skill messages sit at the front of the conversation alongside
memory; the compactor pins them.

### Catalog rendering

When skills are present, ex_athena appends a section to the system prompt:

```text
## Available Skills

Use `[skill: <name>]` in your response to load a skill's full instructions.

  - `audit` — Audit perms.
  - `deploy` — Ship the staging branch to production
```

~50 tokens per skill in the catalog. Bodies stay on disk until the
model asks for them.

### Disable or override

```elixir
# Skip discovery entirely
ExAthena.run("hi", tools: :all, skills: false)

# Provide an explicit map (e.g. constructed from a database)
ExAthena.run("hi",
  tools: :all,
  skills: %{
    "deploy" => %ExAthena.Skills.Skill{
      name: "deploy",
      description: "Ship",
      body: "...",
      path: "<dynamic>"
    }
  })
```

## Auto-memory writes (light)

The agent can append to memory files via the existing `Write` tool.
The path `~/.config/ex_athena/AGENTS.md` is allowlisted by default for
this case — no special tool needed.

## See also

- [`ExAthena.Memory`](https://hexdocs.pm/ex_athena/ExAthena.Memory.html)
- [`ExAthena.Skills`](https://hexdocs.pm/ex_athena/ExAthena.Skills.html)
- [Compaction pipeline](compaction_pipeline.md) — memory + pre-loaded
  skills are pinned across compactions.
- [Permissions](permissions.md) — `allowed-tools` frontmatter scopes
  the active permission set.
