"""Extract Claude's reply from a pane buffer.

Reads the pane via the active terminal backend's ``terminal_capture``
function (routed through the backend's shell library), then locates the
most recent prompt line that contains ``<prompt-prefix>`` and prints
everything between that line and the next prompt marker.

Entry point: ``python3 -m pa.extract_reply <pane-id> <prompt-prefix>``.
"""

from __future__ import annotations

import shlex
import subprocess
import sys
from pathlib import Path

from pa.paths import ConfigError, load_config

PROMPT_MARKER = "❯"


def _capture_via_backend(pane: str, backend: str) -> list[str]:
    """Source the backend shell lib and call ``terminal_capture <pane>``."""
    lib_terminal = Path(__file__).resolve().parents[1] / "terminal"
    backend_sh = lib_terminal / f"{backend}.sh"
    if not backend_sh.exists():
        raise FileNotFoundError(f"backend lib not found: {backend_sh}")
    cmd = f"source {shlex.quote(str(backend_sh))} && terminal_capture {shlex.quote(pane)}"
    res = subprocess.run(
        ["bash", "-c", cmd],
        capture_output=True,
        text=True,
        check=False,
    )
    if res.returncode != 0:
        raise RuntimeError(
            f"terminal_capture {pane} exited {res.returncode}: {res.stderr.strip()}"
        )
    return res.stdout.splitlines()


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit("usage: python3 -m pa.extract_reply <pane-id> <prompt-prefix>")

    pane = sys.argv[1]
    prompt = sys.argv[2].strip()[:60]

    try:
        cfg = load_config()
    except ConfigError as exc:
        sys.exit(f"pa.extract_reply: {exc}")

    try:
        buf = _capture_via_backend(pane, cfg.terminal_backend)
    except (FileNotFoundError, RuntimeError) as exc:
        sys.exit(f"pa.extract_reply: {exc}")

    start = None
    for i in range(len(buf) - 1, -1, -1):
        line = buf[i]
        if prompt in line and line.strip().startswith(PROMPT_MARKER):
            start = i + 1
            break

    if start is None:
        print("\n".join(buf[-30:]))
        return

    end = len(buf)
    for j in range(start, len(buf)):
        if buf[j].strip().startswith(PROMPT_MARKER):
            end = j
            break

    reply = "\n".join(buf[start:end]).strip()
    print(reply or "[no reply captured]")


if __name__ == "__main__":
    main()
