"""Strict allowlist parser for preset config files.

Preset files at ``presets/<name>/config.env`` are NEVER sourced as bash.
They live in a third-party-contributable directory and could become a
supply-chain attack vector if shell-evaluated. This loader enforces a
narrow subset of bash-compatible KEY=VALUE syntax with no command
substitution, no backticks, no shell expansion beyond ``$HOME`` / ``~``,
no semicolons / pipes / redirects, and an explicit key allowlist.

CLI form::

    python3 -m pa.preset_loader <preset-dir>

emits validated ``KEY="value"`` lines to stdout (one per resolved key).
The wizard reads this via ``eval "$(python3 -m pa.preset_loader …)"`` —
each emitted line is plain bash-safe because the parser already rejected
metacharacters in values.

Library form::

    from pa.preset_loader import load_preset
    values = load_preset(Path("presets/obsidian-ce"))
"""

from __future__ import annotations

import os
import shlex
import sys
from pathlib import Path

# Share the allowlist + strict-parser primitives with pa.paths so the
# wizard's validate_assignments and this loader can never drift apart.
# Import direction: preset_loader → paths (paths is the lower layer).
from pa.paths import (
    _ALLOWED_KEYS,
    _FORBIDDEN_SUBSTRINGS,
)
from pa.paths import (
    _STRICT_ASSIGNMENT_RE as _ASSIGNMENT_RE,
)


class PresetError(Exception):
    """Raised when a preset file is malformed, unsafe, or unknown."""


def _expand(value: str) -> str:
    """Expand ``$HOME`` / ``~`` only. No subprocess, no globbing."""
    return os.path.expanduser(os.path.expandvars(value))


def _parse_line(line: str, lineno: int, source: Path) -> tuple[str, str] | None:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return None

    match = _ASSIGNMENT_RE.match(line)
    if not match:
        raise PresetError(
            f"{source}:{lineno}: cannot parse line "
            f"(expected KEY=VALUE or KEY=\"VALUE\"): {line.rstrip()!r}"
        )

    key = match.group("key")
    if key not in _ALLOWED_KEYS:
        raise PresetError(
            f"{source}:{lineno}: unknown key {key!r} "
            f"(allowed: {sorted(_ALLOWED_KEYS)})"
        )

    raw_value = match.group("dquoted")
    if raw_value is None:
        raw_value = match.group("bare") or ""

    for needle in _FORBIDDEN_SUBSTRINGS:
        if needle in raw_value:
            raise PresetError(
                f"{source}:{lineno}: value for {key} contains forbidden "
                f"shell metacharacter {needle!r}"
            )

    return key, _expand(raw_value)


def load_preset(preset_dir: Path) -> dict[str, str]:
    """Parse ``<preset_dir>/config.env`` and return validated key/value pairs."""
    config = preset_dir / "config.env"
    if not config.is_file():
        raise PresetError(f"missing {config}")

    out: dict[str, str] = {}
    text = config.read_text(encoding="utf-8")
    for lineno, line in enumerate(text.splitlines(), start=1):
        result = _parse_line(line, lineno, config)
        if result is None:
            continue
        key, value = result
        out[key] = value
    return out


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: python3 -m pa.preset_loader <preset-dir>")
    preset_dir = Path(sys.argv[1])
    try:
        values = load_preset(preset_dir)
    except PresetError as exc:
        sys.exit(f"pa.preset_loader: {exc}")

    # Emit shell-safe assignments. ``shlex.quote`` adds the minimum quoting
    # bash needs; since values already passed the metacharacter check there
    # is nothing it could misinterpret.
    for key, value in values.items():
        print(f"{key}={shlex.quote(value)}")


if __name__ == "__main__":
    main()
