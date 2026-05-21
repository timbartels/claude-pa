#!/usr/bin/env python3
"""Python helper for the iTerm2 backend.

Implements ALL iTerm2 operations against the typed `iterm2` Python lib —
shell-side iterm2.sh shells out here for everything. Earlier versions used
AppleScript heredocs in the shell layer for spawn/kill/activate/set_title;
those were vulnerable to AppleScript injection via interpolated paths and
have been moved here.

Subcommands (all match the lib/terminal/_interface.sh contract):

    iterm2_helper.py spawn <cwd> <cmd>          -> stdout: session_id
    iterm2_helper.py list                       -> stdout: <id>|<cwd>|<title>...
    iterm2_helper.py send <id> <text>
    iterm2_helper.py enter <id>
    iterm2_helper.py capture <id>               -> stdout: buffer text
    iterm2_helper.py kill <id>
    iterm2_helper.py activate <id>
    iterm2_helper.py set_title <id> <tag>
    iterm2_helper.py health                     -> stdout: short status

Exit codes: 0 success, 1 transient, 2 backend unavailable, 3 pane gone.

Requires (checked at runtime in main()):
    python3 -m pip install --user iterm2
    iTerm2 >= 3.5 with Settings -> General -> Magic -> Enable Python API.
"""

from __future__ import annotations

import asyncio
import sys
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import iterm2  # noqa: F401  # for type checking only


def _require_iterm2():
    """Import iterm2 lazily so this module is importable without the dep."""
    try:
        import iterm2  # runtime import is intentional
        return iterm2
    except ImportError:
        sys.stderr.write(
            "iterm2: Python lib not installed.\n"
            "  python3 -m pip install --user iterm2\n"
            "  then in iTerm2: Settings -> General -> Magic -> Enable Python API\n"
        )
        sys.exit(2)


async def _connect(iterm2_mod):
    try:
        return await iterm2_mod.Connection.async_create()
    except (ConnectionRefusedError, OSError) as exc:
        sys.stderr.write(f"iterm2: cannot connect ({exc}); is iTerm2 running with Python API enabled?\n")
        sys.exit(2)


async def _find_session(conn, iterm2_mod, session_id: str):
    app = await iterm2_mod.async_get_app(conn)
    for window in app.windows:
        for tab in window.tabs:
            for sess in tab.sessions:
                if sess.session_id == session_id:
                    return sess
    return None


async def cmd_list(conn, iterm2_mod) -> int:
    app = await iterm2_mod.async_get_app(conn)
    for window in app.windows:
        for tab in window.tabs:
            for sess in tab.sessions:
                try:
                    cwd = await sess.async_get_variable("path") or ""
                except Exception:
                    cwd = ""
                title = (sess.name or "").replace("|", "/")
                print(f"{sess.session_id}|{cwd}|{title}")
    return 0


async def cmd_spawn(conn, iterm2_mod, cwd: str, cmd: str) -> int:
    profile = iterm2_mod.LocalWriteOnlyProfile()
    profile.set_working_directory(cwd)
    profile.set_use_custom_command("Yes")
    profile.set_command(f"/bin/sh -c {_shlex_quote(cmd)}")
    window = await iterm2_mod.Window.async_create(conn, profile_customizations=profile)
    if window is None or not window.tabs:
        sys.stderr.write("iterm2: failed to create window\n")
        return 1
    sess = window.tabs[0].sessions[0]
    print(sess.session_id)
    return 0


async def cmd_send(conn, iterm2_mod, session_id: str, text: str) -> int:
    sess = await _find_session(conn, iterm2_mod, session_id)
    if sess is None:
        return 3
    try:
        await sess.async_send_text(text)
    except Exception as exc:
        sys.stderr.write(f"iterm2: send failed ({exc})\n")
        return 1
    return 0


async def cmd_enter(conn, iterm2_mod, session_id: str) -> int:
    return await cmd_send(conn, iterm2_mod, session_id, "\n")


async def cmd_capture(conn, iterm2_mod, session_id: str) -> int:
    sess = await _find_session(conn, iterm2_mod, session_id)
    if sess is None:
        return 3
    try:
        contents = await sess.async_get_contents()
    except Exception as exc:
        sys.stderr.write(f"iterm2: capture failed ({exc})\n")
        return 1
    for line_no in range(contents.number_of_lines):
        sys.stdout.write(contents.line(line_no).string + "\n")
    return 0


async def cmd_kill(conn, iterm2_mod, session_id: str) -> int:
    sess = await _find_session(conn, iterm2_mod, session_id)
    if sess is None:
        # Per contract: killing a gone pane is success.
        return 0
    try:
        await sess.async_close()
    except Exception:
        pass
    return 0


async def cmd_activate(conn, iterm2_mod, session_id: str) -> int:
    sess = await _find_session(conn, iterm2_mod, session_id)
    if sess is None:
        return 3
    try:
        await sess.async_activate()
    except Exception as exc:
        sys.stderr.write(f"iterm2: activate failed ({exc})\n")
        return 1
    return 0


async def cmd_set_title(conn, iterm2_mod, session_id: str, tag: str) -> int:
    sess = await _find_session(conn, iterm2_mod, session_id)
    if sess is None:
        return 3
    try:
        await sess.async_set_name(tag)
    except Exception as exc:
        sys.stderr.write(f"iterm2: set_title failed ({exc})\n")
        return 1
    return 0


async def cmd_health(conn, iterm2_mod) -> int:
    app = await iterm2_mod.async_get_app(conn)
    n_tabs = sum(len(window.tabs) for window in app.windows)
    print(f"iterm2 helper OK ({len(app.windows)} window(s), {n_tabs} tab(s))")
    return 0


def _shlex_quote(s: str) -> str:
    """Minimal shell quoter; avoids importing shlex just for this."""
    if not s or any(ch in s for ch in " \t\n\"'\\$`!*?[]{}<>|&;()#~"):
        return "'" + s.replace("'", "'\\''") + "'"
    return s


async def main_async(argv: list[str]) -> int:
    if not argv:
        sys.stderr.write(
            "usage: iterm2_helper.py {spawn <cwd> <cmd>|list|send <id> <text>|enter <id>"
            "|capture <id>|kill <id>|activate <id>|set_title <id> <tag>|health}\n"
        )
        return 2

    iterm2_mod = _require_iterm2()
    conn = await _connect(iterm2_mod)

    try:
        op = argv[0]
        if op == "list":
            return await cmd_list(conn, iterm2_mod)
        if op == "spawn":
            if len(argv) < 3:
                sys.stderr.write("usage: iterm2_helper.py spawn <cwd> <cmd>\n")
                return 2
            return await cmd_spawn(conn, iterm2_mod, argv[1], argv[2])
        if op == "send":
            if len(argv) < 3:
                sys.stderr.write("usage: iterm2_helper.py send <id> <text>\n")
                return 2
            return await cmd_send(conn, iterm2_mod, argv[1], argv[2])
        if op == "enter":
            if len(argv) < 2:
                sys.stderr.write("usage: iterm2_helper.py enter <id>\n")
                return 2
            return await cmd_enter(conn, iterm2_mod, argv[1])
        if op == "capture":
            if len(argv) < 2:
                sys.stderr.write("usage: iterm2_helper.py capture <id>\n")
                return 2
            return await cmd_capture(conn, iterm2_mod, argv[1])
        if op == "kill":
            if len(argv) < 2:
                sys.stderr.write("usage: iterm2_helper.py kill <id>\n")
                return 2
            return await cmd_kill(conn, iterm2_mod, argv[1])
        if op == "activate":
            if len(argv) < 2:
                sys.stderr.write("usage: iterm2_helper.py activate <id>\n")
                return 2
            return await cmd_activate(conn, iterm2_mod, argv[1])
        if op == "set_title":
            if len(argv) < 3:
                sys.stderr.write("usage: iterm2_helper.py set_title <id> <tag>\n")
                return 2
            return await cmd_set_title(conn, iterm2_mod, argv[1], argv[2])
        if op == "health":
            return await cmd_health(conn, iterm2_mod)
        sys.stderr.write(f"iterm2: unknown op: {op}\n")
        return 2
    finally:
        close = getattr(conn, "async_close", None)
        if close is not None:
            try:
                await close()
            except Exception:
                pass


def main() -> None:
    sys.exit(asyncio.run(main_async(sys.argv[1:])))


if __name__ == "__main__":
    main()
