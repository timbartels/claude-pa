"""Minimal MCP stdio server for claude-pa.

Exposes 4 read tools + 1 write tool over the Model Context Protocol so
Claude can drive PA without going through bash. Tools:

  peek_pane(repo)               read a single project's state JSON
  list_panes()                  enumerate every tracked project repo
  aggregate_todos()             flatten todos across all panes
  current_state(repo=None)      shortcut: peek_pane if repo given else list_panes
  dispatch_to_pane(pane, text)  terminal_send + terminal_enter (write tool)

Protocol: JSON-RPC 2.0 line-delimited over stdio, matching the MCP
2024-11-05 schema for `initialize`, `tools/list`, `tools/call`. Keeps
the server dependency-free (no `mcp` package) so plain Python 3.10+
works.

Entry point: ``python3 -m pa.mcp_server``. Registered in
``.mcp.json`` at the plugin root.
"""

from __future__ import annotations

import json
import shlex
import subprocess
import sys
import traceback
from collections.abc import Callable
from pathlib import Path
from typing import Any

from pa.paths import Config, ConfigError, load_config

# ─── Tool implementations ──────────────────────────────────────────────────


def _state_path(cfg: Config, repo: str) -> Path:
    if "/" in repo or repo.startswith("."):
        raise ValueError(f"invalid repo identifier: {repo!r}")
    return cfg.state_dir / f"{repo}.json"


def tool_peek_pane(cfg: Config, repo: str) -> dict:
    """Return the state JSON for one repo, or an empty dict if no state exists yet."""
    path = _state_path(cfg, repo)
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def tool_list_panes(cfg: Config) -> list[dict]:
    """Return a list of {repo, idle, last_event, last_update} entries."""
    if not cfg.state_dir.is_dir():
        return []
    out: list[dict] = []
    for path in sorted(cfg.state_dir.glob("*.json")):
        if path.name.startswith(".") or path.name.startswith("vault-session-"):
            continue
        try:
            state = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        out.append(
            {
                "repo": state.get("repo", path.stem),
                "pane_id": state.get("pane_id"),
                "idle": state.get("idle"),
                "last_event": state.get("last_event"),
                "last_update": state.get("last_update"),
            }
        )
    return out


def tool_aggregate_todos(cfg: Config) -> list[dict]:
    """Cross-pane todos. One row per todo, sorted in_progress → pending → completed."""
    if not cfg.state_dir.is_dir():
        return []
    rows: list[dict] = []
    order = {"in_progress": 0, "pending": 1, "completed": 2}
    for path in sorted(cfg.state_dir.glob("*.json")):
        if path.name.startswith(".") or path.name.startswith("vault-session-"):
            continue
        try:
            state = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        repo = state.get("repo", path.stem)
        for todo in state.get("todos") or []:
            rows.append(
                {
                    "repo": repo,
                    "status": todo.get("status", "pending"),
                    "content": todo.get("activeForm") or todo.get("content", ""),
                }
            )
    rows.sort(key=lambda r: (order.get(r["status"], 9), r["repo"]))
    return rows


def tool_current_state(cfg: Config, repo: str | None = None) -> Any:
    """Convenience: peek_pane if repo given, else list_panes."""
    if repo:
        return tool_peek_pane(cfg, repo)
    return tool_list_panes(cfg)


def tool_dispatch_to_pane(cfg: Config, pane: str, text: str) -> dict:
    """Send literal `text` to `pane`, then submit (Enter). Routes through the
    configured terminal backend's shell library."""
    if not pane:
        raise ValueError("pane is required")
    if not text:
        raise ValueError("text is required")

    backend_lib = (
        Path(__file__).resolve().parents[1]
        / "terminal"
        / f"{cfg.terminal_backend}.sh"
    )
    if not backend_lib.exists():
        raise FileNotFoundError(f"backend lib not found: {backend_lib}")
    cmd = (
        f"source {shlex.quote(str(backend_lib))} && "
        f"terminal_send {shlex.quote(pane)} {shlex.quote(text)} && "
        f"terminal_enter {shlex.quote(pane)}"
    )
    res = subprocess.run(
        ["bash", "-c", cmd],
        capture_output=True,
        text=True,
        check=False,
    )
    return {
        "exit_code": res.returncode,
        "stdout": res.stdout,
        "stderr": res.stderr,
    }


# ─── Tool registry ─────────────────────────────────────────────────────────

TOOL_SPECS: list[dict] = [
    {
        "name": "peek_pane",
        "description": "Return the live state JSON for one project Claude pane (repo identifier as written by the per-repo hook).",
        "inputSchema": {
            "type": "object",
            "properties": {"repo": {"type": "string", "description": "Repo identifier."}},
            "required": ["repo"],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_panes",
        "description": "Enumerate every tracked project repo with idle flag + last-event timestamp.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "aggregate_todos",
        "description": "Flatten cross-pane todo snapshots into a sorted list (in_progress → pending → completed).",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "current_state",
        "description": "Shortcut: peek_pane if `repo` provided, else list_panes.",
        "inputSchema": {
            "type": "object",
            "properties": {"repo": {"type": "string", "description": "Optional repo identifier."}},
            "additionalProperties": False,
        },
    },
    {
        "name": "dispatch_to_pane",
        "description": "Write tool — send literal text to a pane via the configured terminal backend, then submit. Returns exit_code + stdout + stderr.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pane": {"type": "string", "description": "Pane identifier (backend-specific)."},
                "text": {"type": "string", "description": "Text to send before pressing Enter."},
            },
            "required": ["pane", "text"],
            "additionalProperties": False,
        },
    },
]

_DISPATCH: dict[str, Callable[..., Any]] = {
    "peek_pane": tool_peek_pane,
    "list_panes": tool_list_panes,
    "aggregate_todos": tool_aggregate_todos,
    "current_state": tool_current_state,
    "dispatch_to_pane": tool_dispatch_to_pane,
}


# ─── JSON-RPC stdio loop ───────────────────────────────────────────────────


def _send(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def _error(req_id: Any, code: int, message: str, data: Any = None) -> dict:
    err: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return {"jsonrpc": "2.0", "id": req_id, "error": err}


def _result(req_id: Any, result: Any) -> dict:
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def _handle(cfg: Config, msg: dict) -> dict | None:
    method = msg.get("method")
    req_id = msg.get("id")
    params = msg.get("params") or {}

    # Notifications (no `id`) MUST NOT receive a response per JSON-RPC 2.0.
    is_notification = "id" not in msg

    if method == "initialize":
        return _result(
            req_id,
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "claude-pa", "version": "0.1.0"},
            },
        )

    if method == "notifications/initialized":
        return None  # spec-mandated silent ack

    if method == "tools/list":
        return _result(req_id, {"tools": TOOL_SPECS})

    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        fn = _DISPATCH.get(name)
        if fn is None:
            return _error(req_id, -32601, f"unknown tool: {name}")
        try:
            output = fn(cfg, **args)
        except TypeError as exc:
            return _error(req_id, -32602, f"bad arguments for {name}: {exc}")
        except (ValueError, FileNotFoundError, OSError) as exc:
            return _error(req_id, -32000, str(exc))
        except Exception:
            return _error(req_id, -32000, "internal tool error", data=traceback.format_exc())
        # Tool outputs are wrapped per MCP spec.
        return _result(
            req_id,
            {
                "content": [
                    {"type": "text", "text": json.dumps(output, indent=2, ensure_ascii=False)}
                ],
                "isError": False,
            },
        )

    if is_notification:
        return None
    return _error(req_id, -32601, f"method not found: {method}")


def main() -> None:
    try:
        cfg = load_config()
    except ConfigError as exc:
        # Without config we can't serve tools meaningfully. Emit a single
        # JSON-RPC error response if the harness ever sends a request, then
        # exit so the user sees something specific in their client logs.
        sys.stderr.write(f"pa.mcp_server: {exc}\n")
        sys.exit(1)

    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            _send(_error(None, -32700, "parse error"))
            continue
        try:
            reply = _handle(cfg, msg)
        except Exception:
            reply = _error(msg.get("id"), -32000, "internal error", data=traceback.format_exc())
        if reply is not None:
            _send(reply)


if __name__ == "__main__":
    main()
