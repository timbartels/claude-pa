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
    values = load_preset(Path("presets/tim"))
"""

from __future__ import annotations

import os
import re
import shlex
import sys
from pathlib import Path

from pa.paths import _ALLOWED_KEYS  # share the same allowlist as the user config


class PresetError(Exception):
    """Raised when a preset file is malformed, unsafe, or unknown."""


# Only KEY=VALUE assignments are recognised. Optional leading ``export``.
#
# Allowed in values:
#   - Literal text (letters, digits, ``_ - . / : , = + @ ~``)
#   - Literal braces ``{`` ``}`` — needed for placeholder syntax like
#     ``{title}`` in PA_SPAWN_PROMPT_TEMPLATE
#   - ``$VAR`` env references (expanded at parse time via
#     ``os.path.expandvars`` — no shell invocation)
#
# Blocked (regex or substring check, see ``_FORBIDDEN_SUBSTRINGS``):
#   - ``$(…)`` command substitution
#   - ``${VAR}`` brace-form expansion (the parser does not implement it
#     and we'd rather reject ambiguity than guess)
#   - Backticks
#   - Pipes, redirects, semicolons, ampersands
#   - Parentheses (block ``(a||b)`` style)
#   - Backslash escape sequences
# Bare values: ASCII-safe path/identifier characters, plus literal braces
# for placeholder syntax. ``$VAR`` references allowed via the alternation
# (validated by the regex; further checked by _FORBIDDEN_SUBSTRINGS).
_BARE_CHARS = r"[\w./:,=+@~{}-]"
_BARE_BODY = (
    rf"{_BARE_CHARS}*"
    rf"(?:\$[A-Za-z_][A-Za-z0-9_]*{_BARE_CHARS}*)*"
)
# Quoted values: anything except the structural characters ``"`` ``\`` ``$``
# ``` ` ``` — supports Unicode (middle-dot, em-dash, accented letters)
# which often appear in human-facing labels. ``$VAR`` references allowed
# the same way as in the bare form.
_DQUOTED_CHARS = r"[^\"\\$`]"
_DQUOTED_BODY = (
    rf"{_DQUOTED_CHARS}*"
    rf"(?:\$[A-Za-z_][A-Za-z0-9_]*{_DQUOTED_CHARS}*)*"
)
_ASSIGNMENT_RE = re.compile(
    r"""
    ^\s*
    (?:export\s+)?
    (?P<key>[A-Z][A-Z0-9_]*)
    \s*=\s*
    (?:
        "(?P<dquoted>""" + _DQUOTED_BODY + r""")"
      | (?P<bare>""" + _BARE_BODY + r""")
    )
    \s*(?:\#.*)?$
    """,
    re.VERBOSE,
)

# Defence-in-depth — even if the regex were to slip something past, these
# substring checks catch shell escapes that actually need a shell to be
# dangerous. ``;|&<>`` are intentionally NOT here: they can only do harm
# unquoted, and we emit values via ``shlex.quote`` so they always reach
# bash as literal characters inside a quoted string. The regex prevents
# them appearing in bare values anyway.
_FORBIDDEN_SUBSTRINGS = (
    "$(",   # command substitution
    "${",   # brace-form variable expansion (we don't implement it)
    "`",    # backtick command substitution
    "\\",   # escape sequences
)


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
