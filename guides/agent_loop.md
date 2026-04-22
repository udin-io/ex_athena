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

```elixir
# Read-only exploration
ExAthena.run("explore", tools: :all, phase: :plan)

# Deny specific tools regardless of phase
ExAthena.run("refactor", tools: :all, disallowed_tools: ["web_fetch"])

# Restrict to an allowlist
ExAthena.run("summarise", tools: :all, allowed_tools: ["read", "glob"])

# Interactive approval
can_use_tool = fn name, args, _ctx ->
  case name do
    "bash" -> ask_user("Run `#{args["command"]}`?")  # your impl
    _ -> :allow
  end
end

ExAthena.run("deploy", tools: :all, can_use_tool: can_use_tool)
```

## Hooks

Hooks fire at lifecycle points so hosts can:

- Deny specific tool calls mid-loop (`PreToolUse` returning `{:deny, reason}`)
- Capture tool outputs (`PostToolUse`)
- React to conversation end (`Stop`)

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

The event shape is `%ExAthena.Streaming.Event{type: atom, data: term}`:
`:text_delta`, `:tool_call_start`, `:tool_call_end`, `:usage`, `:stop`.

## Sub-agents

The `SpawnAgent` tool lets a model delegate focused work to a fresh
sub-conversation — useful for summarisation or exploration that would bloat
the parent's token budget:

```elixir
ExAthena.run("refactor the project",
  tools: :all,
  assigns: %{
    spawn_agent_opts: [tools: [ExAthena.Tools.Read, ExAthena.Tools.Glob]]
  })
```

The parent sees only the sub-agent's final text, not its intermediate steps.

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
