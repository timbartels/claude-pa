"""Check if a project pane has reached idle (Stop) state since a given timestamp.

Entry point: ``python3 -m pa.poll_pane_idle <pane-id> <since-epoch>``.

The state directory is resolved from the user's claude-pa config; the
caller does not pass it. Prints ``idle`` to stdout iff the matching state
file shows ``last_event=Stop`` with ``last_update >= since-epoch``.
Always exits 0 unless arguments are missing.
"""

from __future__ import annotations

import json
import sys
from datetime import datetime

from pa.paths import ConfigError, load_config


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit("usage: python3 -m pa.poll_pane_idle <pane-id> <since-epoch>")

    target_pane = sys.argv[1]
    try:
        since = int(sys.argv[2])
    except ValueError:
        sys.exit("pa.poll_pane_idle: <since-epoch> must be an integer")

    try:
        cfg = load_config()
    except ConfigError as exc:
        sys.exit(f"pa.poll_pane_idle: {exc}")

    state_dir = cfg.state_dir
    if not state_dir.is_dir():
        return

    for path in state_dir.glob("*.json"):
        if path.name.startswith("vault-session-") or path.name == "dashboard.pane":
            continue
        try:
            state = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if str(state.get("pane_id")) != target_pane:
            continue
        ts = state.get("last_update", "")
        try:
            last_ts = int(datetime.fromisoformat(ts).timestamp())
        except (TypeError, ValueError):
            last_ts = 0
        if state.get("last_event") == "Stop" and last_ts >= since:
            print("idle")
            return


if __name__ == "__main__":
    main()
