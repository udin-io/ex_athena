# The agent loop

`ExAthena.Loop` is the engine that drives multi-turn tool-using conversations.
`ExAthena.run/2` is the thin facade you'll call in practice.

## End-to-end example

```elixir
config :ex_athena,
  default_provider: :ollama

config :ex_athena, :ollama,
  base_url: "http://localhost:11434",
  model: "qwen2.5-coder"

result =
  ExAthena.run(
    "read mix.exs and list the deps",
    tools: [
      ExAthena.Tools.Read,
      ExAthena.Tools.Glob,
      ExAthena.Tools.Grep
    ],
    cwd: "/path/to/my/project",
    phase: :plan
  )

IO.puts(result.text)
```

The loop:

1. Sends the request to the provider with the tool schemas.
2. Parses the response — text only, or text + `tool_calls`.
3. For each tool call: checks `Permissions` + `PreToolUse` hooks → executes
   the tool → fires `PostToolUse` hooks → appends a tool-result message.
4. Replays everything back to the provider and repeats.
5. Stops when the model responds with text and no tool calls, or hits
   `:max_iterations` (default 25).

## Multi-turn: `ExAthena.Session`

For user-facing chat where the conversation spans multiple messages, use
a `Session`:

```elixir
{:ok, pid} = ExAthena.Session.start_link(
  provider: :ollama,
  model: "qwen2.5-coder",
  tools: :all,
  cwd: "/path/to/project",
  system_prompt: "You are a senior Elixir engineer."
)

{:ok, r1} = ExAthena.Session.send_message(pid, "look at the auth module")
{:ok, r2} = ExAthena.Session.send_message(pid, "ok now add a password-reset flow")
# r2 has the full context of r1 because the Session persists message history.

ExAthena.Session.stop(pid)
```

## Permissions

Five modes, with deny-first ordering — denylist always wins:

```elixir
# Read-only exploration
ExAthena.run("explore", tools: :all, phase: :plan)

# Auto-allow edits, still prompt for bash + custom tools
ExAthena.run("refactor", tools: :all, phase: :accept_edits, can_use_tool: ask)

# Trust mode — skip the callback for every tool. Denylist still respected.
ExAthena.run("CI agent", tools: :all, phase: :trusted)

# Full YOLO — opt-in only:
ExAthena.run("CI agent", tools: :all, phase: :trusted, respect_denylist: false)

# Deny specific tools regardless of phase
ExAthena.run("refactor", tools: :all, disallowed_tools: ["web_fetch"])

# Restrict to an allowlist
ExAthena.run("summarise", tools: :all, allowed_tools: ["read", "glob"])

# Interactive approval
can_use_tool = fn name, args, _ctx ->
  case name do
    "bash" -> ask_user("Run `#{args["command"]}`?")
    _ -> :allow
  end
end

ExAthena.run("deploy", tools: :all, can_use_tool: can_use_tool)
```

See the [permissions guide](permissions.md) for the full ordering, the
`:auto` reservation, and `can_use_tool` callback contract.

## Hooks

Hooks fire at 14 lifecycle events so hosts can:

- Deny specific tool calls mid-loop (`PreToolUse` returning `{:deny, reason}`)
- Capture tool outputs (`PostToolUse`)
- React to conversation end (`Stop` / `StopFailure` / `SessionEnd`)
- Inject context (`{:inject, msg}` from any event)
- Rewrite the user's prompt (`{:transform, prompt}` from `UserPromptSubmit`)
- Observe permission denials, subagent spawns, compaction stages

See the [hooks reference](hooks_reference.md) for the full event
catalog + payload shapes.

```elixir
deny_protected = fn %{tool_name: name, tool_input: %{"path" => path}}, _id ->
  if name in ["write", "edit"] and String.contains?(path, "priv/secrets") do
    {:deny, permission_decision_reason: "protected path"}
  else
    :ok
  end
end

capture_test = fn %{tool_name: "bash", tool_input: %{"command" => cmd}, result: result}, _id ->
  if String.contains?(cmd, "mix test") do
    MyApp.Store.save_test_run(result)
  end

  :ok
end

ExAthena.run("ship it",
  tools: :all,
  hooks: %{
    PreToolUse: [%{matcher: "write|edit", hooks: [deny_protected]}],
    PostToolUse: [%{matcher: "bash", hooks: [capture_test]}]
  })
```

## Streaming to a UI

Pass `:on_event` for LiveView-friendly updates:

```elixir
live_pid = self()

ExAthena.run("explain the architecture",
  tools: :all,
  on_event: fn event -> send(live_pid, {:athena_event, event}) end)
```

The loop emits flat tuples: `{:content, text}`, `{:tool_call, tc}`,
`{:tool_result, tr}`, `{:tool_ui, %{tool_call_id, kind, payload}}`,
`{:iteration, n}`, `{:compaction, metadata}`, `{:subagent_spawn, ...}`,
`{:subagent_result, ...}`, `{:usage, map}`, `{:done, Result.t()}`.

`:tool_ui` is the structured-payload sibling of `:tool_result` — see
the [tools guide](tools.md) for the per-tool kinds.

## Sub-agents

The `SpawnAgent` tool lets a model delegate focused work to a fresh
sub-conversation. v0.4 ships three builtin agent definitions — invoke
by name:

```elixir
# Read-only investigation
ExAthena.run("find the bug",
  tools: :all,
  assigns: %{spawn_agent_opts: [provider: :ollama, model: "qwen2.5-coder"]})

# Inside the loop, the model emits:
# spawn_agent(prompt: "explore the auth module", agent: "explore")
```

Built-in defs: `general` (full-tool default), `explore` (read-only +
`web_fetch`), `plan` (writes restricted to `.exathena/plans/*.md`).
Custom defs live at `.exathena/agents/<name>.md`. With
`isolation: :worktree` set in frontmatter, the subagent runs in an
isolated git checkout. The parent sees only the subagent's final text.

See [agents + subagents](agents_subagents.md) for the full surface.

## Memory + Skills

Drop an `AGENTS.md` at your project root for project-specific rules;
ex_athena prepends it as user-context on every turn. Drop `SKILL.md`
files under `.exathena/skills/<name>/` and they appear in the
system-prompt catalog at ~50 tokens; the body loads when the model
emits `[skill: <name>]`.

Override discovery on a per-call basis:

```elixir
ExAthena.run("hi", tools: :all, memory: false, skills: false)
ExAthena.run("hi", tools: :all, preload_skills: ["deploy", "audit"])
```

See [memory + skills](memory_and_skills.md).

## Sessions + checkpointing

`Session.start_link/1` accepts `:store` — `:in_memory` (default) or
`:jsonl` for durable storage. Resume a prior session:

```elixir
{:ok, prior_messages} = ExAthena.Session.resume("session-id-from-disk", store: :jsonl)

{:ok, pid} = ExAthena.Session.start_link(
  store: :jsonl,
  session_id: "session-id-from-disk",
  messages: prior_messages,
  provider: :ollama, model: "qwen2.5-coder",
  tools: :all
)
```

Every `Edit` / `Write` snapshots the prior file contents to
`.exathena/file-history/<session>/<sha>/<v>.bin`. `/rewind` restores
files + truncates the session log:

```elixir
ExAthena.Checkpoint.rewind(session_id, :code_and_history, to_uuid: uuid)
```

See [sessions + checkpoints](sessions_and_checkpoints.md).

## Structured extraction

When you need a JSON object back — not prose — use `extract_structured/2`:

```elixir
schema = %{
  "type" => "object",
  "required" => ["bugs"],
  "properties" => %{
    "bugs" => %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "properties" => %{
          "file" => %{"type" => "string"},
          "line" => %{"type" => "integer"},
          "issue" => %{"type" => "string"}
        }
      }
    }
  }
}

{:ok, %{"bugs" => bugs}} =
  ExAthena.extract_structured(
    "Find potential null-deref bugs in this code:\n\n#{source}",
    schema: schema,
    provider: :openai_compatible,
    model: "gpt-4o-mini"
  )
```

Uses the provider's JSON mode when available; falls back to a
`~~~json`-fenced block and validates against the schema.
