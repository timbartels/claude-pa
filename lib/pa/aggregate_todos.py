"""Flatten TodoWrite / TaskCreate snapshots across all project panes into one
prioritized list.

Entry point: ``python3 -m pa.aggregate_todos`` (no arguments). The state
directory is resolved from the user's claude-pa config.
"""

from __future__ import annotations

import json
import sys

from pa.paths import ConfigError, load_config

STATUS_ORDER = {"in_progress": 0, "pending": 1, "completed": 2}
STATUS_MARK = {"in_progress": "~", "pending": " ", "completed": "x"}


def main() -> None:
    try:
        cfg = load_config()
    except ConfigError as exc:
        sys.exit(f"pa.aggregate_todos: {exc}")

    state_dir = cfg.state_dir
    if not state_dir.is_dir():
        print("no state directory yet")
        return

    rows: list[tuple[str, str, str]] = []
    for f in sorted(state_dir.glob("*.json")):
        # Skip session + dashboard sentinel files — they hold no todo lists.
        if f.name.startswith("vault-session-") or f.name in {"dashboard.pane"}:
            continue
        try:
            state = json.loads(f.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        repo = state.get("repo", f.stem)
        for todo in state.get("todos") or []:
            status = todo.get("status", "pending")
            content = todo.get("activeForm") or todo.get("content", "")
            rows.append((status, repo, content))

    if not rows:
        print(
            "no tasks reported yet — project Claudes haven't fired "
            "TaskCreate / TaskUpdate since hook install"
        )
        return

    rows.sort(key=lambda r: (STATUS_ORDER.get(r[0], 9), r[1]))

    print(f"{'STATE':<6} {'REPO':<28} TASK")
    last_status = None
    for status, repo, content in rows:
        if status != last_status:
            last_status = status
        mark = STATUS_MARK.get(status, "?")
        print(f"[{mark}]    {repo:<28} {content[:90]}")


if __name__ == "__main__":
    main()
