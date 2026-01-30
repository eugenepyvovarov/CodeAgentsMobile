# SSH Tunnel + SSE Proxy Integration Spec

This document specifies how the iOS app will use an SSH tunnel to reach a local-only SSE proxy that wraps the Claude Agent Python SDK, including install/run instructions across Linux distributions and macOS, event replay for resume-after-background, and security considerations.

## Overview

- On-device SSH tunnel forwards a local port to a server-local proxy bound to `127.0.0.1:8787`.
- iOS connects to `http://127.0.0.1:<localPort>` and consumes SSE using LDSwiftEventSource (LaunchDarkly’s Swift EventSource library).
- Server proxy uses the Python Agent SDK (`claude-agent-sdk`) to query Claude Code and streams events as SSE.
- Proxy assigns monotonic `event_id` per event and persists NDJSON per `session_id` for replay.
- No public exposure of the proxy when tunneling; only SSH (22) is required.

## Goals

- Replace SSH + CLI process management in-app with a stable HTTP/SSE interface over a tunnel.
- Preserve existing UI and parser by matching current “stream-json per line” semantics.
- Resume streams after iOS background by replaying missed events.
- Support heterogeneous server installs (Ubuntu/Debian, RHEL/Rocky, macOS).

## Non‑Goals

- Embedding CPython or the Python SDK in the iOS binary.
- Immediate server‑side key migration. The current app continues to support local API key/token storage (Keychain) for the CLI path; the proxy path can use server‑side env when available, with migration to server‑managed secrets planned later.

## References (capabilities confirmed)

- Python SDK repo: https://github.com/anthropics/claude-agent-sdk-python
- Docs: https://docs.claude.com/en/api/agent-sdk/python
- SDK provides async streaming via `query(...)`, supports `allowed_tools`, `cwd`, external and in-process MCP servers, and hooks.
- Requires Python 3.10+, Node.js, and Claude Code 2.0+ (`npm i -g @anthropic-ai/claude-code`).

## Architecture

### iOS app (client)

- Establish SSH connection (SwiftNIO + NIOSSH).
- Open a local port-forward (L→R) to server `127.0.0.1:8787`:
  - Binds `127.0.0.1:<ephemeralLocalPort>` on device.
  - For each local connection, creates SSH `direct-tcpip` channel to `127.0.0.1:8787` on the server and relays bytes.
- Call proxy endpoints using base URL `http://127.0.0.1:<ephemeralLocalPort>`.
- Use LDSwiftEventSource for SSE:
  - Set `Accept: text/event-stream` and, when resuming, `Last-Event-ID`.
  - On each message, pass the `data` payload to the existing `StreamingJSONParser`.
  - Rely on library reconnect/backoff; optionally tune retry with server `retry:` hints.

### Server (proxy)

- FastAPI app uses `claude-agent-sdk` to run agent queries.
- Endpoints:
  - `POST /v1/agent/stream` → `text/event-stream` with `id:` for each event and `data: {json}` lines.
  - `GET /v1/sessions/{id}/events?since=<eventId>` → NDJSON replay (one JSON per line), for resume.
  - `GET /healthz` → liveness and Claude Code availability check.
- Bind to `127.0.0.1:8787` to be reachable only via SSH tunnel.
- Persist transcripts to `sessions/<session_id>.ndjson` and keep a small in-memory ring buffer for fast replay.

## Event Protocol

- SSE framing per event:
  - `id: <monotonic-int>`
  - `data: {json}` (JSON matches current “stream-json” blocks expected by the app)
  - blank line terminator
- JSON message types:
  - `system` (init; includes `session_id` and tool list when available)
  - `assistant` (text blocks, tool_use)
  - `user` (tool_result)
  - `result` (final marker; includes `session_id`, cost, usage as available)
- Replay endpoint returns the same JSON objects as NDJSON, ordered by `event_id`.

## iOS Implementation Details

### SSHTunnelManager (new)

- Responsibilities:
  - Open local listener on `127.0.0.1:0` (OS picks free port).
  - For each inbound local connection, request a new SSH `direct-tcpip` child channel to `remoteHost=127.0.0.1`, `remotePort=8787` and relay bytes bidirectionally.
  - Provide `SSHTunnel` handle: `{ localHost, localPort, stop() }`.

- Suggested API:
  - `openTunnel(project: RemoteProject, remoteHost: String = "127.0.0.1", remotePort: Int = 8787) async throws -> SSHTunnel`
  - Internally reuses `SSHService.getConnection(for:purpose:)` to share the authenticated connection.

### ClaudeAgentProxyService (new)

- Uses `SSHTunnelManager` to obtain `baseURL` (`http://127.0.0.1:<localPort>`).
- `sendMessage(text, project, sessionId?, allowedTools, cwd, mcpServers?) -> AsyncThrowingStream<MessageChunk, Error>`
- Builds requests to `/v1/agent/stream` with `Accept: text/event-stream`.
- SSE handling with LDSwiftEventSource:
  - On connect, supply `Last-Event-ID` if resuming.
  - For each event, capture `id` and persist `lastEventId`; forward `data` to `StreamingJSONParser.parseStreamingLine(...)`.
  - Close source on completion/view disappear; recreate on demand.

### Lifecycle & Resume

- Persist per in-flight turn: `session_id` and `lastEventId`.
- On foreground/resume:
  1. Reconnect SSH and recreate tunnel.
  2. `GET /v1/sessions/{session_id}/events?since=<lastEventId>` and feed each line to `StreamingJSONParser`.
  3. If a `result` is encountered, mark message complete and clear `activeStreamingMessageId`; otherwise open SSE with `Last-Event-ID` to continue live.
- Close the tunnel when stream completes or on view disappear; recreate on demand to conserve battery.

## Server Implementation Details

### Dependencies

- Python 3.10+
- Node.js
- Claude Code 2.0+: `npm install -g @anthropic-ai/claude-code`
- Packages: `pip install claude-agent-sdk fastapi uvicorn[standard] python-dotenv` (optional)

### FastAPI skeleton (SSE + replay)

```python
import anyio
import json
import time
import uuid
from pathlib import Path
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import StreamingResponse, PlainTextResponse
from claude_agent_sdk import query, ClaudeAgentOptions

app = FastAPI()
SESS_DIR = Path("sessions")
SESS_DIR.mkdir(parents=True, exist_ok=True)

def sse_event(event_id: int, data: dict) -> str:
    return f"id: {event_id}\\n" + "data: " + json.dumps(data, ensure_ascii=False) + "\\n\\n"

@app.get("/healthz")
async def healthz():
    return PlainTextResponse("ok")

@app.post("/v1/agent/stream")
async def agent_stream(req: Request):
    payload = await req.json()
    session_id = payload.get("session_id") or str(uuid.uuid4())
    path = SESS_DIR / f"{session_id}.ndjson"
    event_id = 0

    async def gen():
        nonlocal event_id
        # example init event
        event_id += 1
        init = {"type": "system", "subtype": "init", "session_id": session_id}
        path.write_text(json.dumps(init) + "\\n")
        yield sse_event(event_id, init)

        async for event in query(
            payload.get("text", ""),
            options=ClaudeAgentOptions(
                allowed_tools=payload.get("allowed_tools", []),
                cwd=payload.get("cwd"),
            ),
        ):
            event_id += 1
            data = event.model_dump()
            with path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(data, ensure_ascii=False) + "\\n")
            yield sse_event(event_id, data)

    return StreamingResponse(gen(), media_type="text/event-stream")

@app.get("/v1/sessions/{session_id}/events")
async def replay(session_id: str, since: int = 0):
    path = SESS_DIR / f"{session_id}.ndjson"
    if not path.exists():
        raise HTTPException(404, "session not found")
    lines = path.read_text(encoding="utf-8").splitlines()
    # since is last seen id; server assigns monotonically, so replay everything after it
    # NOTE: this example assumes 1:1 mapping between line index and event id.
    start = max(0, since)
    body = "\\n".join(lines[start:]) + ("\\n" if lines[start:] else "")
    return PlainTextResponse(body, media_type="application/x-ndjson")
```

## Security Considerations

- The proxy binds to `127.0.0.1` only; only reachable via SSH tunnel.
- Do not expose proxy port publicly.
- Protect `sessions/` (contains transcript data).
- Prefer server-side auth and minimal logging in production.

