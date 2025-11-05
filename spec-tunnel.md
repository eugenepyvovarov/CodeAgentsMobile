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
STORE = Path("sessions"); STORE.mkdir(exist_ok=True)

def write_event(session_id: str, event_id: int, payload: dict):
    line = json.dumps(payload, separators=(",", ":"))
    (STORE / f"{session_id}.ndjson").open("a").write(line + "\n")

async def sse_iter(session_id: str, options: ClaudeAgentOptions):
    eid = 0
    yield ": ping\n\n"  # optional heartbeat
    async for msg in query(prompt=options.prompt, options=options):
        eid += 1
        payload = msg.to_dict() if hasattr(msg, "to_dict") else json.loads(json.dumps(msg, default=str))
        payload.setdefault("session_id", session_id)
        write_event(session_id, eid, payload)
        data = json.dumps(payload, separators=(",", ":"))
        yield f"id: {eid}\n" + f"data: {data}\n\n"
    # final result marker if SDK doesn’t emit one
    eid += 1
    result = {"type": "result", "session_id": session_id}
    write_event(session_id, eid, result)
    yield f"id: {eid}\n" + f"data: {json.dumps(result)}\n\n"

@app.get("/healthz")
def healthz():
    return PlainTextResponse("ok")

@app.post("/v1/agent/stream")
async def agent_stream(req: Request):
    body = await req.json()
    text = body.get("text")
    if not text:
        raise HTTPException(400, "text required")
    session_id = body.get("session_id") or uuid.uuid4().hex
    options = ClaudeAgentOptions(
        cwd=body.get("cwd"),
        allowed_tools=body.get("allowed_tools"),
        system_prompt=body.get("system_prompt"),
        max_turns=body.get("max_turns"),
    )
    options.prompt = text  # convenience; or pass separately to query
    return StreamingResponse(sse_iter(session_id, options), media_type="text/event-stream")

@app.get("/v1/sessions/{session_id}/events")
def replay(session_id: str, since: int = 0):
    p = STORE / f"{session_id}.ndjson"
    if not p.exists():
        raise HTTPException(404, "unknown session")
    return PlainTextResponse(p.read_text())  # simple; client filters by lastEventId
```

Notes:
- The above is a minimal scaffold. In production, stream replay selectively (`since`), and keep an in-memory ring buffer for fast resumptions.
- Make sure the JSON structure matches what the app’s `StreamingJSONParser` expects.

## Deployment

### Ubuntu/Debian (systemd)

1. Create user and folder:
   - `sudo adduser --system --group claudeproxy`
   - `sudo mkdir -p /opt/claude-proxy && sudo chown -R claudeproxy: /opt/claude-proxy`
2. Install deps:
   - `sudo apt-get update`
   - `sudo apt-get install -y python3.11 python3.11-venv nodejs` (or Nodesource for newer Node)
   - `python3.11 -m venv /opt/claude-proxy/venv`
   - `/opt/claude-proxy/venv/bin/pip install claude-agent-sdk fastapi uvicorn[standard]`
   - `npm install -g @anthropic-ai/claude-code`
3. Env file `/etc/claude-proxy.env` (chmod 600):
   - `ANTHROPIC_API_KEY=...`
4. Systemd unit `/etc/systemd/system/claude-agent-proxy.service`:
   - `[Unit] Description=Claude Agent SSE Proxy After=network.target`
   - `[Service] User=claudeproxy WorkingDirectory=/opt/claude-proxy`
   - `EnvironmentFile=/etc/claude-proxy.env`
   - `ExecStart=/opt/claude-proxy/venv/bin/uvicorn app:app --host 127.0.0.1 --port 8787`
   - `Restart=always RestartSec=5`
   - `[Install] WantedBy=multi-user.target`
5. Start: `sudo systemctl daemon-reload && sudo systemctl enable --now claude-agent-proxy`
6. Logs: `journalctl -u claude-agent-proxy -f`

### RHEL/CentOS/Rocky (systemd)

- `sudo dnf install -y python3.11 python3.11-devel nodejs`
- Same venv, npm global install, env file, and systemd unit as Ubuntu.
- If SELinux prevents binds, since binding to `127.0.0.1` only, defaults usually suffice.

### macOS (launchd)

1. Install deps with Homebrew: `brew install python@3.11 node`
2. App folder: e.g., `~/claude-proxy`; create venv and install dependencies.
3. `~/Library/LaunchAgents/com.company.claude-proxy.plist`:
   - ProgramArguments: `["/usr/local/bin/uvicorn","app:app","--host","127.0.0.1","--port","8787"]`
   - WorkingDirectory: `~/claude-proxy`
   - EnvironmentVariables: include `ANTHROPIC_API_KEY`
   - KeepAlive: true, RunAtLoad: true
   - StandardOutPath/StandardErrorPath: log files
4. `launchctl load ~/Library/LaunchAgents/com.company.claude-proxy.plist`

### Ports and Exposure

- Tunnel path (recommended):
  - Only SSH (22) must be open inbound. Proxy binds to loopback and is unreachable externally.
- HTTPS (optional):
  - Terminate TLS via nginx/caddy on 443; disable proxy buffering for SSE.
  - Require short-lived JWT tokens; pin TLS in app.

## Security

- Authentication handling:
  - Today, the app supports local API key/token storage in iOS Keychain for the CLI path.
  - The proxy path should prefer server‑side environment keys when available.
  - Longer‑term, migrate secrets to server‑managed storage; keep the app path for backward compatibility during rollout.
- Bind proxy to `127.0.0.1` when using tunnels; no external exposure.
- Restrict file permissions on env files (`chmod 600`).
- Optionally set SSH server `ClientAliveInterval 30` and `ClientAliveCountMax 2` to drop dead sessions.

## Testing Plan

- Server: `curl -N http://127.0.0.1:8787/healthz` and a manual stream request.
- iOS: establish SSH, open tunnel, request `/healthz` via `http://127.0.0.1:<localPort>/healthz`.
- Kill proxy process; verify app recreates tunnel and replays via `events?since=`.

## Migration Phases

1. Stand up proxy and feature flag in app (CLI vs Proxy).
2. Implement `SSHTunnelManager` and `ClaudeAgentProxyService`; keep UI and parser unchanged.
3. Swap `ClaudeCodeService.sendMessage(...)` to call proxy behind flag.
4. Replace `MCPService` SSH calls with proxy endpoints later.
5. Remove CLI/SSH tailing path once stable.

## Open Items

- Implement SSH `direct-tcpip` bridge with SwiftNIO handlers.
- Define exact JSON to match `StreamingJSONParser` and extend if needed.
- Add replay filtering by `since` on server for large sessions.
- Optional: comment heartbeats `: ping` every 15–30s from server.
