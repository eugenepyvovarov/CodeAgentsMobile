OpenCode fixtures captured from `opencode serve --hostname 127.0.0.1 --port 4096`.

Captured version: 1.14.21
Captured date: 2026-05-01

Notes:
- Provider/auth output is intentionally excluded because local provider config can contain secrets.
- SSE fixtures use raw `data:` frames as returned by `/event` and `/global/event`.
- Current OpenCode SSE frames did not include durable event ids during capture.
- Permission request fixtures still need to be captured on a server configured to ask for a tool action.

