# Tools

Tools are stateless modules that implement the `ExAthena.Tool` behaviour.
The agent loop calls them, and the result is replayed back to the model as
a tool-result message.

## Builtin tools

| Tool | Purpose | Phase: `:plan` |
|---|---|---|
| `ExAthena.Tools.Read` | Read a file, with optional offset/limit | ✅ |
| `ExAthena.Tools.Glob` | Find files by wildcard pattern | ✅ |
| `ExAthena.Tools.Grep` | Search file contents by regex | ✅ |
| `ExAthena.Tools.Write` | Create/overwrite a file | ❌ |
| `ExAthena.Tools.Edit` | Exact-string replacement in a file | ❌ |
| `ExAthena.Tools.Bash` | Shell execution with timeout | ❌ |
| `ExAthena.Tools.WebFetch` | HTTP GET (http/https only, 1 MB cap) | ✅ |
| `ExAthena.Tools.TodoWrite` | Agent todo list | ❌ |
| `ExAthena.Tools.PlanMode` | Request phase transition | ✅ |
| `ExAthena.Tools.SpawnAgent` | Synchronous sub-agent | ✅ |

Use `:all` or a list of modules to enable tools:

```elixir
# All builtins
ExAthena.run("refactor this project", tools: :all)

# A subset
ExAthena.run("find the bug", tools: [
  ExAthena.Tools.Read,
  ExAthena.Tools.Glob,
  ExAthena.Tools.Grep
])

# Configured globally
config :ex_athena, tools: [ExAthena.Tools.Read, ExAthena.Tools.Bash]
```

## Path resolution

The `Read`, `Write`, and `Edit` tools accept absolute paths or paths relative
to `ctx.cwd`. `ExAthena.ToolContext.resolve_path/2` rejects path traversal
(`..`) and null bytes before the tool runs.

## Writing your own tool

```elixir
defmodule MyApp.Tools.DescribePage do
  @behaviour ExAthena.Tool

  @impl true
  def name, do: "describe_page"

  @impl true
  def description, do: "Summarise the content of a web page"

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        url: %{type: "string", description: "URL to fetch"}
      },
      required: ["url"]
    }
  end

  @impl true
  def execute(%{"url" => url}, _ctx) do
    # … fetch + summarise
    {:ok, "summary of " <> url}
  end
end

# Register it:
ExAthena.run("describe https://example.com", tools: [MyApp.Tools.DescribePage])
```

### Return shapes

| Return | Behaviour |
|---|---|
| `{:ok, result}` | Stringified and replayed to the model. |
| `{:ok, llm, ui}` | LLM text + structured UI payload. The model sees `llm`; hosts get a `:tool_ui` event with the `ui` map. |
| `{:error, reason}` | Replayed as an error tool-result; loop continues. The kernel fires the `PostToolUseFailure` hook. |
| `{:halt, reason}` | Loop stops immediately (emergency brake). |

#### Structured tool results (`{:ok, llm, ui}`)

The 3-tuple lets a tool return one string for the LLM and a richer
payload for hosts (TUIs, Phoenix LiveView frontends) that want to
render rich previews without parsing text. The `ui` shape is
`%{kind: atom(), payload: map()}`. The loop emits a `:tool_ui` event
after `:tool_result` for any tool that returned the 3-tuple.

Built-in payload shapes:

| Tool | `kind` | Payload fields |
|---|---|---|
| `Read` | `:file` | `path`, `content`, `line_range` |
| `Edit` | `:diff` | `path`, `before`, `after`, `replacements` |
| `Bash` | `:process` | `command`, `exit_code`, `stdout`, `duration_ms` |
| `Glob` | `:matches` | `pattern`, `count`, `items` |
| `Grep` | `:matches` | `pattern`, `count`, `items` |
| `WebFetch` | `:webpage` | `url`, `status`, `truncated?` |
| `SpawnAgent` | `:subagent` | `subagent_id`, `iterations`, `cost_usd`, `duration_ms`, `isolation` |
| `Write`, `TodoWrite`, `PlanMode` | — | text-only, no UI payload |

Custom tools use any atom `kind` they like — hosts pattern-match on
`{:tool_ui, %{kind: :my_kind}}` events. Returning `{:ok, text}`
remains fully supported and the loop simply skips the `:tool_ui`
event.

### Using `ctx.assigns`

`ExAthena.ToolContext.assigns` is a map threaded through every tool call.
Use it for data the host app needs during tool execution — project id,
conversation id, database ref, user id, pubsub name.

```elixir
ExAthena.run("…", assigns: %{project_id: 42, user_id: "abc"})
```

### `TodoWrite` notifier

`ExAthena.Tools.TodoWrite` optionally calls `ctx.assigns[:todo_writer]`
with the new list — useful for broadcasting to a LiveView:

```elixir
writer = fn todos -> MyAppWeb.Endpoint.broadcast("todos", "update", todos) end

ExAthena.run("build the feature",
  tools: :all,
  assigns: %{todo_writer: writer})
```

## Phase gating (permissions)

Each builtin has a static "mutating or not" classification. The `:plan`
phase permits only the non-mutating ones; `:default` permits everything
(subject to `can_use_tool` + hooks); `:bypass_permissions` skips checks.

See `ExAthena.Permissions` for the full check order and `guides/agent_loop.md`
for end-to-end examples including permission flows.
