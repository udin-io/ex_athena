# Hooks reference (v0.4)

Hooks are functions ex_athena calls at lifecycle events so hosts can
observe, deny, halt, or augment the run without subclassing the loop
or modes.

## Shape

```elixir
hooks = %{
  PreToolUse:  [%{matcher: "Write|Edit", hooks: [&deny_protected/2]}],
  PostToolUse: [%{matcher: "Bash",       hooks: [&capture_test/2]}],
  ChatParams:  [&inject_metadata/2],
  Stop:        [&log_stop/2]
}

ExAthena.run("...", tools: :all, hooks: hooks)
```

Per-tool events take **matcher groups**: `%{matcher: pattern, hooks:
funs}`. The matcher is a regex string, `Regex` struct, or `nil`. A
`nil` matcher fires for every tool. Lifecycle events take a flat list
of functions.

## Callback contract

Each hook function receives `(input, tool_use_id_or_session_id)` and
returns one of:

| Return | Meaning |
|---|---|
| `:ok` | Continue with no side effects. |
| `{:halt, reason}` | Stop the loop. Sets `finish_reason: :error_halted`. |
| `{:deny, reason}` | Only valid from `PreToolUse` / `PermissionRequest`. Denies the tool call; routed back to the model as an error tool-result. |
| `{:inject, msg_or_msgs}` | Append a `Message.t()` (or list) to the conversation. |
| `{:transform, prompt}` | Only valid from `UserPromptSubmit`. Rewrites the user's prompt before it enters the loop. |

## Catalog

`ExAthena.Hooks.events/0` enumerates all 17 supported events.

### Session lifecycle

| Event | Fires at | Payload |
|---|---|---|
| `:SessionStart` | Just after `Loop.run/2` builds initial state | `%{session_id, parent_session_id}` |
| `:SessionEnd` | After `Stop` / `StopFailure` in `to_result/2` | `%{session_id, parent_session_id, finish_reason, result}` |

### Per-turn

| Event | Fires at | Payload |
|---|---|---|
| `:UserPromptSubmit` | Before the first iteration | `%{prompt, session_id, parent_session_id}` |
| `:ChatParams` | Before every provider call inside `Modes.ReAct.iterate/1` | `%{request, session_id, messages}` |
| `:Stop` | Run finished cleanly (`finish_reason == :stop`) | `%{session_id, finish_reason: :stop, result}` |
| `:StopFailure` | Run finished with any error finish_reason | `%{session_id, finish_reason, result}` |

`UserPromptSubmit` honours `{:transform, prompt}` to rewrite the
incoming user message; `ChatParams` honours `{:inject, msg}` to add
context just before a provider call.

### Per-tool

| Event | Fires at | Payload |
|---|---|---|
| `:PreToolUse` | Before tool execution. Honours `{:deny, reason}`. | `%{tool_name, tool_use_id, ...args}` |
| `:PostToolUse` | After successful execution. Halt-only (deny is too late). | `%{tool_name, tool_use_id, result}` |
| `:PostToolUseFailure` | After tool returns `{:error, reason}` | `%{tool_name, tool_use_id, reason}` |
| `:PermissionRequest` | Before `can_use_tool` callback (when `:default` mode prompts) | `%{tool_name, tool_use_id, arguments}` |
| `:PermissionDenied` | Whenever the gate decides `{:deny, _}` | `%{tool_name, tool_use_id, arguments, reason}` |

`PermissionDenied` fires alongside the model getting the deny reason
as a tool-result — Claude Code's "deny as routing signal" pattern.
Hooks observe; the model adjusts.

### Subagent

| Event | Fires at | Payload |
|---|---|---|
| `:SubagentStart` | Before sub-loop starts in `Tools.SpawnAgent` | `%{subagent_id, prompt, parent_session_id, agent, isolation}` |
| `:SubagentStop` | After sub-loop terminates (any outcome) | `%{subagent_id, outcome, result, isolation}` |

`isolation` carries the resolution decision (`{:in_process, :requested}`,
`{:in_process, :no_git}`, `{:in_process, :dirty_tree}`, `{:worktree, info}`).
After completion it becomes `:worktree_kept`, `:worktree_removed`, or
`:worktree_error`.

### Compaction

| Event | Fires at | Payload |
|---|---|---|
| `:PreCompact` | Before `maybe_compact/1` runs the pipeline | `%{estimate}` |
| `:PreCompactStage` | Before each individual pipeline stage | `%{stage, estimate}` |
| `:PostCompact` | After a successful compaction | `%{metadata: %{before, after, dropped_count, stages_applied, reason}}` |

### Notification

| Event | Fires at | Payload |
|---|---|---|
| `:Notification` | Manual host trigger via `ExAthena.Hooks.run_lifecycle/3` | host-defined |

## Worked examples

### Deny writes to a protected path

```elixir
deny_protected = fn %{tool_name: name, "path" => path}, _id ->
  if name in ["write", "edit"] and String.contains?(path, "priv/secrets") do
    {:deny, :protected_path}
  else
    :ok
  end
end

ExAthena.run("ship it",
  tools: :all,
  hooks: %{PreToolUse: [%{matcher: "write|edit", hooks: [deny_protected]}]})
```

### Inject project metadata into every chat call

```elixir
inject_metadata = fn _payload, _id ->
  {:inject,
   ExAthena.Messages.system("Current ticket: ENG-1234")
   |> Map.put(:name, "ticket-context")}
end

ExAthena.run("...", tools: :all, hooks: %{ChatParams: [inject_metadata]})
```

### Rewrite a user prompt with project conventions

```elixir
expand_macros = fn %{prompt: prompt}, _id ->
  if String.starts_with?(prompt, "/deploy") do
    {:transform, "Deploy the staging branch to production. Steps: ..."}
  else
    :ok
  end
end

ExAthena.run("...", tools: :all, hooks: %{UserPromptSubmit: [expand_macros]})
```

### Capture every tool failure to telemetry

```elixir
capture = fn %{tool_name: name, reason: reason}, tool_use_id ->
  :telemetry.execute([:my_app, :tool_failure], %{}, %{
    tool: name,
    reason: inspect(reason),
    tool_use_id: tool_use_id
  })

  :ok
end

ExAthena.run("...", tools: :all, hooks: %{PostToolUseFailure: [capture]})
```

### Persist results on every Stop

```elixir
ExAthena.run("...",
  tools: :all,
  hooks: %{
    Stop: [fn %{result: r}, sid -> MyApp.Sessions.persist(sid, r); :ok end],
    StopFailure: [fn %{result: r}, sid -> MyApp.Sessions.alert(sid, r); :ok end]
  })
```

## Programmatic dispatch

`ExAthena.Hooks.run_lifecycle_with_outputs/3` returns the structured
outputs for callers that need them:

```elixir
%{halt: nil, injects: [msg1, msg2], transform: nil} =
  ExAthena.Hooks.run_lifecycle_with_outputs(hooks, :ChatParams, payload)
```

`run_lifecycle/3` returns `:ok | {:halt, reason}` for backward-compat;
use the `_with_outputs` variant when you need to read injects /
transform.

## See also

- [`ExAthena.Hooks`](https://hexdocs.pm/ex_athena/ExAthena.Hooks.html)
- [Permissions](permissions.md) — `PermissionDenied` semantics.
- [Compaction pipeline](compaction_pipeline.md) — `PreCompactStage`
  payload.
