"""PA state-file IPC: project-Claude hook that writes a per-repo state JSON.

Fires on SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop,
and SessionEnd. Skips entirely when the session's CWD is inside the vault
(orchestrator conversations don't pollute project state).

Output: ``$PA_DATA_DIR/state/<repo>.json``, plus a rolling
``$PA_DATA_DIR/state/events.log`` for the dashboard's event stream.

The hook shim at ``hooks/scripts/pa-state-update.py`` is a thin entry
point that calls :func:`main`.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from pa.paths import ConfigError, load_config

MAX_EVENTS = 20
MAX_PROMPT_LEN = 240


def _resolve_repo(cwd: Path) -> str:
    repo = cwd.name
    if not (cwd / ".git").exists():
        return repo
    try:
        remote = (
            subprocess.check_output(
                ["git", "-C", str(cwd), "remote", "get-url", "origin"],
                stderr=subprocess.DEVNULL,
            )
            .decode()
            .strip()
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return repo
    if not remote:
        return repo
    return Path(remote.rstrip("/").removesuffix(".git")).name


def _detect_pane_id(backend: str) -> str | None:
    """Return the active pane id for the active backend, or ``None``.

    Each backend exports a different env var inside the pane it owns; we
    pick by configured backend first, then fall back to whichever var is
    set (covers nested setups like wezterm-running-tmux).
    """
    by_backend = {
        "wezterm": "WEZTERM_PANE",
        "tmux": "TMUX_PANE",
        "iterm2": "ITERM_SESSION_ID",
        "kitty": "KITTY_WINDOW_ID",
    }
    primary = by_backend.get(backend)
    if primary and os.environ.get(primary):
        return os.environ[primary]
    for var in by_backend.values():
        value = os.environ.get(var)
        if value:
            return value
    return None


def _load_state(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def _capture_todos(tool_input: dict) -> list[dict] | None:
    """Normalise both TodoWrite and TaskCreate/TaskUpdate shapes into a flat list."""
    items = tool_input.get("todos") or tool_input.get("tasks") or []
    if not items:
        return None
    out: list[dict] = []
    for t in items:
        if not isinstance(t, dict):
            continue
        out.append(
            {
                "content": t.get("content")
                or t.get("description")
                or t.get("title", ""),
                "status": t.get("status", "pending"),
                "activeForm": t.get("activeForm") or t.get("active_form", ""),
            }
        )
    return out or None


def _append_event_log(log_path: Path, payload: dict) -> None:
    try:
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(payload) + "\n")
    except OSError:
        pass


def main() -> None:
    try:
        cfg = load_config()
    except ConfigError as exc:
        print(f"pa.state_update: {exc}", file=sys.stderr)
        sys.exit(0)

    cwd = Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()).resolve()

    # Skip vault-owned sessions — they manage state via the skill, not the hook.
    try:
        cwd.relative_to(cfg.vault.resolve())
        return
    except ValueError:
        pass

    repo = _resolve_repo(cwd)

    try:
        event = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        event = {}

    cfg.state_dir.mkdir(parents=True, exist_ok=True)
    state_file = cfg.state_dir / f"{repo}.json"
    state = _load_state(state_file)

    now = datetime.now().isoformat(timespec="seconds")
    event_name = event.get("hook_event_name") or os.environ.get(
        "CLAUDE_HOOK_EVENT", "unknown"
    )

    state["repo"] = repo
    state["cwd"] = str(cwd)
    state["pane_id"] = _detect_pane_id(cfg.terminal_backend)
    state["pid"] = os.environ.get("CLAUDE_SESSION_PID") or os.getpid()
    state["last_update"] = now
    state["last_event"] = event_name

    if event_name == "UserPromptSubmit":
        prompt = (event.get("prompt") or "").strip()
        state["last_prompt"] = prompt[:MAX_PROMPT_LEN]
        state["idle"] = False
        m = re.match(r"/([\w:-]+)", prompt)
        if m:
            state["current_workflow"] = m.group(1)
    elif event_name == "PreToolUse":
        tool_name = event.get("tool_name", "")
        state["last_tool"] = tool_name
        state["idle"] = False
        tool_input = event.get("tool_input") or {}
        if tool_name in ("Edit", "Write", "Read", "MultiEdit", "NotebookEdit"):
            fp = tool_input.get("file_path")
            if fp:
                state["last_file"] = fp
        elif tool_name == "Bash":
            cmd = tool_input.get("command", "")
            if cmd:
                state["last_bash"] = cmd[:120]
        if tool_name in ("TodoWrite", "TaskCreate", "TaskUpdate"):
            todos = _capture_todos(tool_input)
            if todos:
                state["todos"] = todos
                state["todos_updated"] = now
    elif event_name == "PostToolUse":
        state["last_tool"] = event.get("tool_name", state.get("last_tool"))
    elif event_name == "Stop":
        state["idle"] = True
    elif event_name == "SessionEnd":
        state["idle"] = True
        _append_event_log(
            cfg.state_dir / "events.log",
            {"ts": now, "repo": repo, "event": "SessionEnd", "tool": None},
        )
        try:
            state_file.unlink(missing_ok=True)
        except OSError:
            pass
        return
    elif event_name == "SessionStart":
        state["idle"] = False
        state["session_started"] = now

    events = state.setdefault("events", [])
    events.append(
        {
            "ts": now,
            "event": event_name,
            "tool": event.get("tool_name"),
        }
    )
    state["events"] = events[-MAX_EVENTS:]

    state_file.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")

    _append_event_log(
        cfg.state_dir / "events.log",
        {
            "ts": now,
            "repo": repo,
            "event": event_name,
            "tool": event.get("tool_name"),
        },
    )


if __name__ == "__main__":
    main()
