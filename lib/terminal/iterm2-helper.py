#!/usr/bin/env python3
"""Python helper for the iTerm2 backend.

Implements the iTerm2 operations that AppleScript cannot do reliably:
- list sessions across windows
- send text to a session
- capture buffer text

Invoked by lib/terminal/iterm2.sh. Requires the `iterm2` Python lib:
  python3 -m pip install --user iterm2

And in iTerm2 settings: General -> Magic -> Enable Python API (then
allow this script on first connection).

Usage:
  iterm2-helper.py list
  iterm2-helper.py send <session_id> <text>
  iterm2-helper.py capture <session_id>

Exit codes match the lib/terminal/_interface.sh contract:
  0 success, 1 transient, 2 backend unavailable, 3 pane gone.
"""

from __future__ import annotations

import asyncio
import sys
from typing import Awaitable, Callable


def _die_no_module() -> None:
    sys.stderr.write(
        "iterm2: Python lib not installed.\n"
        "  python3 -m pip install --user iterm2\n"
        "  then in iTerm2: Settings -> General -> Magic -> Enable Python API\n"
    )
    sys.exit(2)


try:
    import iterm2  # type: ignore
except ImportError:
    _die_no_module()


async def _connect() -> "iterm2.Connection":  # type: ignore[name-defined]
    try:
        return await iterm2.Connection.async_create()
    except Exception as exc:
        sys.stderr.write(f"iterm2: cannot connect ({exc}); is iTerm2 running with Python API enabled?\n")
        sys.exit(2)


async def _find_session(conn, session_id: str):
    app = await iterm2.async_get_app(conn)
    for window in app.windows:
        for tab in window.tabs:
            for sess in tab.sessions:
                if sess.session_id == session_id:
                    return sess
    return None


async def cmd_list(conn) -> int:
    app = await iterm2.async_get_app(conn)
    for window in app.windows:
        for tab in window.tabs:
            for sess in tab.sessions:
                try:
                    cwd = await sess.async_get_variable("path") or ""
                except Exception:
                    cwd = ""
                title = sess.name or ""
                print(f"{sess.session_id}|{cwd}|{title}")
    return 0


async def cmd_send(conn, session_id: str, text: str) -> int:
    sess = await _find_session(conn, session_id)
    if sess is None:
        return 3
    await sess.async_send_text(text)
    return 0


async def cmd_capture(conn, session_id: str) -> int:
    sess = await _find_session(conn, session_id)
    if sess is None:
        return 3
    contents = await sess.async_get_contents()
    for line_no in range(contents.number_of_lines):
        sys.stdout.write(contents.line(line_no).string + "\n")
    return 0


async def main_async(argv: list[str]) -> int:
    if not argv:
        sys.stderr.write("usage: iterm2-helper.py {list|send <id> <text>|capture <id>}\n")
        return 2

    conn = await _connect()
    op = argv[0]

    if op == "list":
        return await cmd_list(conn)
    if op == "send":
        if len(argv) < 3:
            sys.stderr.write("usage: iterm2-helper.py send <session_id> <text>\n")
            return 2
        return await cmd_send(conn, argv[1], argv[2])
    if op == "capture":
        if len(argv) < 2:
            sys.stderr.write("usage: iterm2-helper.py capture <session_id>\n")
            return 2
        return await cmd_capture(conn, argv[1])

    sys.stderr.write(f"iterm2: unknown op: {op}\n")
    return 2


def main() -> None:
    sys.exit(asyncio.run(main_async(sys.argv[1:])))


if __name__ == "__main__":
    main()
