# Gemini

ExAthena's `:gemini` provider routes requests through the `req_llm` library's
Google adapter, giving you Google's Gemini models with native tool calls,
streaming, and structured output behind the same `ExAthena.query/2` interface
used by every other provider.

## Get an API key

1. Open [Google AI Studio](https://aistudio.google.com/app/apikey).
2. Click **Create API key** and copy the result.

The free tier is available without billing — see [Rate limits](#rate-limits) for
what it includes. Paid usage requires a Google Cloud billing account.

## Configure

Export the key as an environment variable. ExAthena's Gemini provider routes
through `req_llm`'s Google adapter, which reads `GOOGLE_API_KEY` by default —
match that convention so the same key works whether you configure it in
ExAthena or let `req_llm` pick it up directly:

```bash
export GOOGLE_API_KEY="AIza..."
```

> Google's own docs sometimes name the variable `GEMINI_API_KEY`. If you
> already export that one, either rename it to `GOOGLE_API_KEY` or read it
> explicitly in your config via `System.get_env("GEMINI_API_KEY")`.

Then configure ExAthena to use it:

```elixir
# config/config.exs  (or config/runtime.exs for production)
config :ex_athena, default_provider: :gemini

config :ex_athena, :gemini,
  api_key: System.get_env("GOOGLE_API_KEY"),
  model: "gemini-2.5-flash"
```

## First call

```elixir
{:ok, response} = ExAthena.query("Say hi", provider: :gemini)
IO.puts(response.text)
```

Override the model for a single call:

```elixir
{:ok, response} =
  ExAthena.query("Reason through this carefully",
    provider: :gemini,
    model: "gemini-2.5-pro")
```

## Models

| Model | Best for | Notes |
|---|---|---|
| `gemini-2.5-flash` | Speed, cost efficiency | Recommended default. Supports thinking budget. |
| `gemini-2.5-pro` | Complex reasoning, code | Higher quality, lower free-tier rate limits. |

Both models support [thinking token budgets](https://ai.google.dev/gemini-api/docs/thinking)
via the `google_thinking_budget` provider option. `req_llm`'s Google adapter
reads it from a nested `:provider_options` keyword — pass it through
`:provider_opts` like this:

```elixir
ExAthena.query("Hard problem",
  provider: :gemini,
  provider_opts: [provider_options: [google_thinking_budget: 8192]])
```

Pass `google_thinking_budget: 0` to disable thinking for a call.

## Capabilities

| Feature | Status |
|---|---|
| Native tool calls | ✅ (v1beta API, the default) |
| Streaming | ✅ SSE |
| JSON mode / structured output | ✅ via `response_format` |
| Resume | ❌ |

## Tool-calling caveats

Gemini validates tool schemas strictly on the server side. The most common
issues are:

- **Empty parameter schemas** — Gemini rejects tools whose `parameters` object
  has no `properties` at all. ExAthena's built-in tool schema builder always
  produces at least a minimal schema, so you won't hit this with built-in tools.
  Custom tools with `parameters: %{}` will fail with a `400 INVALID_ARGUMENT`.
  Add an explicit (possibly empty-typed) properties map.

- **Array items must declare a type** — Arrays of primitives need
  `items: %{type: "string"}` (or the appropriate scalar type). An array without
  an `items.type` field is rejected.

- **`additionalProperties` is ignored** — Gemini silently ignores this field;
  do not rely on it for schema validation.

ExAthena's schema layer already produces conformant schemas for built-in tools.
If you write custom tools targeting Gemini, run a quick sanity call with a
simple query to confirm your schema passes before wiring it into an agent loop.

## Rate limits

Free-tier and paid-tier limits change frequently. Rather than committing
numbers that drift out of date, check the live page:
[Google Gemini API rate limits](https://ai.google.dev/gemini-api/docs/rate-limits).

Free-tier `gemini-2.5-flash` has historically allowed an order of magnitude
more requests-per-minute than `gemini-2.5-pro`, so prefer flash for any
workload that fans out.

When you hit a rate limit, the API returns HTTP `429`. ExAthena surfaces this
as `{:error, %ExAthena.Error{code: :rate_limited}}`. Back off and retry with
exponential delay.

## Troubleshooting

| Error | Likely cause | Fix |
|---|---|---|
| HTTP `401` | Invalid or missing API key | Confirm `GOOGLE_API_KEY` is set and the key is active in AI Studio. |
| HTTP `429` | Rate limit exceeded | Back off and retry. Check the [rate limits page](https://ai.google.dev/gemini-api/docs/rate-limits). |
| HTTP `400 INVALID_ARGUMENT` on tool call | Empty or non-conformant tool schema | See [Tool-calling caveats](#tool-calling-caveats). Ensure `properties` is non-empty and arrays declare `items.type`. |
