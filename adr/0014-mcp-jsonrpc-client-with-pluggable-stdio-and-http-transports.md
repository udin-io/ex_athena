# ADR: MCP JSON-RPC client with pluggable stdio and HTTP transports

## Status

Accepted

## Context

ex_athena needs to speak the Model Context Protocol so consumers can mount external tool servers (search engines, ticket systems, custom org tools) into the agent loop the same way Claude Code, Cursor, OpenCode, and Codex CLI do.

MCP is JSON-RPC 2.0 over one of two transports:

- **stdio**: child process, `\n`-delimited JSON on stdin/stdout (no `Content-Length` headers).
- **Streamable HTTP**: POST to a single endpoint; response body is either `application/json` (single object) or `text/event-stream` (one or more SSE events). The client MUST advertise both via `Accept` and MUST handle both response types.

This is the first of three sub-tickets adding native MCP support. We need a usable client library whose API and error surface are stable before sub-tickets 2 (config/supervision) and 3 (loop integration) build on it.

## Decision

1. Introduce `ExAthena.Mcp.Client` as a `GenServer` that owns request/response correlation (per-call ids, pending callers map, per-call timeouts) and the `initialize` handshake. The Client speaks to a transport process via a small `ExAthena.Mcp.Transport` behaviour with three callbacks (`start_link/2`, `send/2`, `close/1`) and a documented inbound message contract: `{:mcp_message, line}`, `{:transport_down, reason}`, `{:mcp_response_error, id, %ExAthena.Error{}}`.

2. Implement two transports under `ExAthena.Mcp.Transport.{Stdio, Http}`.
   - Stdio uses `Port.open` with `line: N` framing, consistent with `ExAthena.Tools.Bash`'s port pattern. Env passthrough via the `:env` port opt.
   - HTTP uses `Req.post/2` per outbound JSON-RPC message, advertising `Accept: application/json, text/event-stream` per spec, parsing either a plain JSON body or one-shot SSE-framed `data:` blocks, echoing any returned `Mcp-Session-Id`, and emitting `MCP-Protocol-Version: 2025-06-18` on post-init requests.

3. Encode/decode is centralised in `ExAthena.Mcp.Protocol`. JSON-RPC 2.0 error codes map onto `ExAthena.Error` (`-32601 → :not_found`, `-32602 → :bad_request`, `-32603 → :server_error`). Tool-execution failures (`result.isError: true`) are NOT converted to errors — they are returned as `{:ok, %{is_error: true, content: ...}}` because they are successful protocol responses; sub-ticket 3 (loop integration) decides what to do with them.

4. Out of scope for this ticket: server→client requests (sampling, elicitation, roots), resource subscriptions, OAuth dynamic client registration, the older HTTP+SSE two-endpoint transport, and long-lived server-streamed responses. Server→client requests received during a session are logged and dropped; the client does not crash on them.

5. The Client is **not** started by `ExAthena.Application`. Lifecycle ownership stays with callers in this ticket; sub-ticket 2 will add a supervisor.

## Consequences

### Positive

- One Client API for both transports — callers don't switch on transport.
- Reuses `ExAthena.Error` so MCP failures surface through the same channel as provider/transport errors.
- Spec-conformant on the wire (Accept header, protocol version, session id), so we work out of the box with real MCP servers (Anthropic, GitHub, Cloudflare, custom).
- No new dependencies. `Req`, `Jason`, `Bypass`, `NimbleOptions` already in tree.

### Negative

- Two transports to maintain. Mitigated by the very small surface (`start_link`, `send`, `close`) and a shared `Protocol` module.
- We accept SSE-framed responses but only the single-response case (read full body, parse the first `data:` block). Servers that hold the stream open to push later notifications won't have those notifications delivered. Documented in moduledoc.
- Stdio child stderr is left to flow to the parent OS process's stderr (no `:stderr_to_stdout` because the spec reserves stderr for server logs). Acceptable for v1; revisit if it becomes noisy.

### Neutral

- The Client's auto-initialize-on-start design means the `initialize` handshake is part of `init/1`. A failed handshake stops the process with `{:shutdown, %Error{}}`. Sub-ticket 2's supervisor will decide restart strategy.
- Conformance target is MCP `2025-06-18`. Older spec versions (2024-11-05) are not supported.
