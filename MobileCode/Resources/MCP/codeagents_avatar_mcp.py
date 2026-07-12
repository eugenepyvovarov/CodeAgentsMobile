#!/usr/bin/env python3
"""Minimal stdio MCP server: set/get/clear agent avatar in .codeagents/codeagents.json.

Wire format: MCP stdio = newline-delimited JSON-RPC (NDJSON), one message per line.
OpenCode uses @modelcontextprotocol/sdk StdioClientTransport (NDJSON), not LSP Content-Length.
SCRIPT_VERSION is checked by the iOS app to force re-deploy after protocol fixes.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Bump when the on-disk script must be replaced on remote hosts.
SCRIPT_VERSION = "2"

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "codeagents-avatar"
SERVER_VERSION = "1.0.1"

IDENTITY_REL = Path(".codeagents") / "codeagents.json"
AVATAR_IMAGE_REL = Path(".codeagents") / "avatar.png"


def project_root() -> Path:
    raw = os.environ.get("CODEAGENTS_PROJECT_PATH") or os.getcwd()
    return Path(raw).expanduser().resolve()


def identity_path() -> Path:
    return project_root() / IDENTITY_REL


def load_identity() -> dict[str, Any]:
    path = identity_path()
    if not path.is_file():
        return {"schema_version": 2, "agent_id": "", "avatar": {"kind": "none"}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return {"schema_version": 2, "agent_id": "", "avatar": {"kind": "none"}}
        return data
    except Exception:
        return {"schema_version": 2, "agent_id": "", "avatar": {"kind": "none"}}


def save_identity(doc: dict[str, Any]) -> None:
    path = identity_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    doc["schema_version"] = max(int(doc.get("schema_version") or 1), 2)
    path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def validate_relative_path(raw: str) -> Path | None:
    text = (raw or "").strip()
    if not text or text.startswith("/") or text.startswith("~"):
        return None
    parts = Path(text).parts
    if not parts or any(p in ("", ".", "..") for p in parts):
        return None
    rel = Path(*parts)
    root = project_root()
    candidate = (root / rel).resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        return None
    return rel


def tool_result(text: str, is_error: bool = False) -> dict[str, Any]:
    return {
        "content": [{"type": "text", "text": text}],
        "isError": is_error,
    }


def get_agent_avatar() -> dict[str, Any]:
    doc = load_identity()
    avatar = doc.get("avatar") or {"kind": "none"}
    return tool_result(json.dumps({"avatar": avatar}, indent=2))


def set_agent_avatar_emoji(emoji: str) -> dict[str, Any]:
    emoji = (emoji or "").strip()
    if not emoji:
        return tool_result("emoji is required", is_error=True)
    # First Unicode scalar (good enough for common emoji avatars).
    emoji = list(emoji)[0] if emoji else ""
    if not emoji:
        return tool_result("emoji is required", is_error=True)

    doc = load_identity()
    previous = doc.get("avatar") if isinstance(doc.get("avatar"), dict) else {}
    doc["avatar"] = {
        "kind": "emoji",
        "emoji": emoji,
        "image": previous.get("image"),
        "updated_at": now_iso(),
        "updated_by": "mcp",
    }
    save_identity(doc)
    return tool_result(json.dumps({"ok": True, "avatar": doc["avatar"]}, indent=2))


def set_agent_avatar_image(path: str) -> dict[str, Any]:
    rel = validate_relative_path(path)
    if rel is None:
        return tool_result("path must be project-relative without ..", is_error=True)
    ext = rel.suffix.lower().lstrip(".")
    if ext not in {"png", "jpg", "jpeg", "webp", "gif"}:
        return tool_result("image must be png/jpg/jpeg/webp/gif", is_error=True)

    src = (project_root() / rel).resolve()
    if not src.is_file():
        return tool_result(f"file not found: {rel.as_posix()}", is_error=True)

    dest_rel = AVATAR_IMAGE_REL
    dest = project_root() / dest_rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)

    doc = load_identity()
    doc["avatar"] = {
        "kind": "image",
        "emoji": None,
        "image": dest_rel.as_posix(),
        "updated_at": now_iso(),
        "updated_by": "mcp",
    }
    save_identity(doc)
    return tool_result(json.dumps({"ok": True, "avatar": doc["avatar"]}, indent=2))


def clear_agent_avatar() -> dict[str, Any]:
    doc = load_identity()
    previous = doc.get("avatar") if isinstance(doc.get("avatar"), dict) else {}
    image = previous.get("image")
    doc["avatar"] = {
        "kind": "none",
        "emoji": None,
        "image": None,
        "updated_at": now_iso(),
        "updated_by": "mcp",
    }
    save_identity(doc)
    for candidate in {AVATAR_IMAGE_REL.as_posix(), image}:
        if not candidate:
            continue
        rel = validate_relative_path(str(candidate))
        if rel is None:
            continue
        path = project_root() / rel
        if path.is_file() and ".codeagents" in path.parts:
            try:
                path.unlink()
            except OSError:
                pass
    return tool_result(json.dumps({"ok": True, "avatar": doc["avatar"]}, indent=2))


TOOLS = [
    {
        "name": "get_agent_avatar",
        "description": (
            "Return the current agent avatar from .codeagents/codeagents.json. "
            "Prefer this over reading the file directly."
        ),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "set_agent_avatar_emoji",
        "description": (
            "Set this agent's avatar to an emoji. Required when the user asks to change the avatar. "
            "Do not edit codeagents.json by hand — this tool merges identity safely."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"emoji": {"type": "string", "description": "Emoji character"}},
            "required": ["emoji"],
            "additionalProperties": False,
        },
    },
    {
        "name": "set_agent_avatar_image",
        "description": (
            "Set avatar from a project-relative image path (copied to .codeagents/avatar.png). "
            "Do not edit codeagents.json by hand."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Path relative to project root (png/jpg/jpeg/webp/gif)",
                }
            },
            "required": ["path"],
            "additionalProperties": False,
        },
    },
    {
        "name": "clear_agent_avatar",
        "description": "Clear the agent avatar (monogram fallback in the app).",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
]


def handle_tools_call(params: dict[str, Any]) -> dict[str, Any]:
    name = params.get("name")
    arguments = params.get("arguments") or {}
    if name == "get_agent_avatar":
        return get_agent_avatar()
    if name == "set_agent_avatar_emoji":
        return set_agent_avatar_emoji(str(arguments.get("emoji") or ""))
    if name == "set_agent_avatar_image":
        return set_agent_avatar_image(str(arguments.get("path") or ""))
    if name == "clear_agent_avatar":
        return clear_agent_avatar()
    return tool_result(f"Unknown tool: {name}", is_error=True)


def send(msg: dict[str, Any]) -> None:
    """Write one NDJSON JSON-RPC message (MCP stdio spec)."""
    # Compact JSON, no embedded newlines — required by NDJSON framing.
    line = json.dumps(msg, separators=(",", ":"), ensure_ascii=False)
    sys.stdout.buffer.write(line.encode("utf-8"))
    sys.stdout.buffer.write(b"\n")
    sys.stdout.buffer.flush()


def read_message() -> dict[str, Any] | None:
    """Read one JSON-RPC message.

    Primary: NDJSON (OpenCode / official MCP SDK).
    Fallback: LSP-style Content-Length framing (older clients).
    """
    line = sys.stdin.buffer.readline()
    if not line:
        return None

    # Content-Length header path (legacy / dual-compat).
    if line.lower().startswith(b"content-length:"):
        headers: dict[str, str] = {}
        text = line.decode("ascii", errors="replace").strip()
        if ":" in text:
            k, v = text.split(":", 1)
            headers[k.strip().lower()] = v.strip()
        while True:
            hline = sys.stdin.buffer.readline()
            if not hline or hline in (b"\r\n", b"\n"):
                break
            t = hline.decode("ascii", errors="replace").strip()
            if ":" in t:
                k, v = t.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        length = int(headers.get("content-length") or "0")
        if length <= 0:
            return None
        raw = sys.stdin.buffer.read(length)
        if not raw:
            return None
        return json.loads(raw.decode("utf-8"))

    # NDJSON path.
    text = line.decode("utf-8", errors="replace").strip()
    if not text:
        # Blank line — keep reading (some clients pad).
        return read_message()
    return json.loads(text)


def main() -> None:
    while True:
        try:
            msg = read_message()
        except Exception as exc:  # noqa: BLE001
            # Malformed input: log to stderr only (never stdout).
            sys.stderr.write(f"codeagents-avatar: parse error: {exc}\n")
            sys.stderr.flush()
            continue
        if msg is None:
            break

        method = msg.get("method")
        msg_id = msg.get("id")
        params = msg.get("params") or {}

        if method == "initialize":
            result = {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {
                    "name": SERVER_NAME,
                    "version": SERVER_VERSION,
                },
                "instructions": (
                    "Use set_agent_avatar_emoji / set_agent_avatar_image / clear_agent_avatar "
                    "to change this agent's avatar. Do not edit .codeagents/codeagents.json by hand."
                ),
            }
            send({"jsonrpc": "2.0", "id": msg_id, "result": result})
            continue

        if method == "notifications/initialized":
            continue

        if method == "ping":
            send({"jsonrpc": "2.0", "id": msg_id, "result": {}})
            continue

        if method == "tools/list":
            send({"jsonrpc": "2.0", "id": msg_id, "result": {"tools": TOOLS}})
            continue

        if method == "tools/call":
            try:
                result = handle_tools_call(params if isinstance(params, dict) else {})
                send({"jsonrpc": "2.0", "id": msg_id, "result": result})
            except Exception as exc:  # noqa: BLE001
                send(
                    {
                        "jsonrpc": "2.0",
                        "id": msg_id,
                        "result": tool_result(f"error: {exc}", is_error=True),
                    }
                )
            continue

        if msg_id is not None:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "error": {"code": -32601, "message": f"Method not found: {method}"},
                }
            )


if __name__ == "__main__":
    main()
