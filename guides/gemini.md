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

ExAthena uses only the key you hand it. It reads no environment variable and
no `.env` file on its own, so you name the variable. Google's docs call it
`GEMINI_API_KEY`:

```bash
export GEMINI_API_KEY="AIza..."
```

```elixir
# config/runtime.exs
config :ex_athena, default_provider: :gemini

config :ex_athena, :gemini,
  api_key: System.get_env("GEMINI_API_KEY"),
  model: "gemini-2.5-flash"
```

A call with no key, or an empty one, returns
`{:error, %ExAthena.Error{kind: :unauthorized}}` and sends nothing. ExAthena
sends the key in the `x-goog-api-key` header, never in the URL, so a logged URL
carries no key. A redirect from the server is not followed, so the header never
reaches another host.

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
| JSON mode / structured output | ✅ via `ExAthena.StructuredOutput.request/3`, on a query (not a stream) |
| Resume | ❌ |

## Structured output

`ExAthena.StructuredOutput.request/3` sends your JSON Schema to Gemini as
`responseJsonSchema`, with `responseMimeType: "application/json"`, for every
model id, aliases such as `gemini-flash-lite-latest` included:

```elixir
schema = %{
  "type" => "object",
  "properties" => %{
    "pick" => %{"type" => "string", "enum" => ["tea", "coffee"]},
    "note" => %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}
  },
  "required" => ["pick", "note"]
}

ExAthena.StructuredOutput.request("Tea or coffee?", schema, provider: :gemini)
# => {:ok, %{"pick" => "tea", "note" => nil}}
```

Pass `"json"` instead of a schema for plain JSON mode. Google accepts a subset
of JSON Schema; its [API reference](https://ai.google.dev/api/generate-content)
lists the keywords. A stream that asks for a JSON shape returns `:bad_request`.

## Safety blocks

Gemini's filter can refuse a prompt or stop an answer. ExAthena reports both as
`finish_reason: :content_filter`, so a block never reads as an empty answer:

- a refused prompt (Google returns no answer at all);
- an answer stopped for safety, recitation, a blocklist term, prohibited
  content or personal data.

`ExAthena.StructuredOutput.request/3` returns `{:error, :content_filter}` for
either.

On a stream, req_llm reports a blocklist term, prohibited content or personal
data as a plain `:error`, because its stream decoder drops Google's reason; only
safety and recitation reach `:content_filter` there. Use a query when the reason
matters.

## Logging

By default the adapter's debug log shows message previews and replies, and a
failed call logs Google's error body at warning. To keep user text out of your
logs, turn that off:

```elixir
config :ex_athena, :gemini, log_bodies: false
# or per call: ExAthena.query(prompt, provider: :gemini, log_bodies: false)
```

Errors then log their kind and status only. One line stays outside
ExAthena's reach: req_llm itself logs a failed stream's body at warning when
the server answers with an error status. Raise that module's level in your app
to drop it (req_llm 1.29 and later log it from `ReqLLM.Streaming.Failure`,
earlier versions from `ReqLLM.Streaming`):

```elixir
Logger.put_module_level(ReqLLM.Streaming.Failure, :error)
```

Two more places can still carry text you'd rather keep out of logs:

- The error ExAthena returns keeps req_llm's original error in its `raw` field,
  and that holds the request body, prompt included. Log `kind` and `status`,
  not the whole struct.
- If Google's stream sends an event req_llm cannot read, req_llm's stream
  process crashes, takes the calling process with it, and the crash report
  prints that process's state, key and prompt included. A fix belongs in
  req_llm.

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
| `:unauthorized` before any request | No key was passed | Set `api_key:` in `config :ex_athena, :gemini` or per call. |
| HTTP `401` / `403` | Invalid key | Confirm the key is active in AI Studio. |
| HTTP `429` | Rate limit exceeded | Back off and retry. Check the [rate limits page](https://ai.google.dev/gemini-api/docs/rate-limits). |
| HTTP `400 INVALID_ARGUMENT` on tool call | Empty or non-conformant tool schema | See [Tool-calling caveats](#tool-calling-caveats). Ensure `properties` is non-empty and arrays declare `items.type`. |
