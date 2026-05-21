"""Config + path resolution for claude-pa Python callers.

Mirrors lib/paths.sh for bash callers. Loads $PA_CONFIG (a key=value file
written by the wizard) without subprocessing bash, so unit tests can import
and mock without spawning a shell.

The config file's format is the intersection of valid bash and a strict
allowlist: one ``KEY="value"`` assignment per line, no command substitution,
no shell expansion beyond ``$HOME`` / ``~``. The file IS executed as bash by
lib/paths.sh — but that's a separate code path; this module never executes
it. Both paths must accept the same files for users to have a consistent
experience.

Environment overrides (resolved before parsing the file):
    PA_CONFIG       absolute path to the config file
    PA_DATA_DIR     absolute path to the data root (state/cache/logs live underneath)
    XDG_CONFIG_HOME / XDG_DATA_HOME  standard XDG vars

Typical usage::

    from pa.paths import load_config
    cfg = load_config()
    cfg.vault                # PA_VAULT
    cfg.state_dir            # PA_DATA_DIR/state
"""

from __future__ import annotations

import os
import re
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path


class ConfigError(Exception):
    """Raised when the config file is missing, malformed, or fails validation."""


# One assignment per line. Optional leading `export`, key is uppercase
# ASCII + digits + underscore, value is either bare (no whitespace, no
# shell metacharacters) or double-quoted. Comments and blanks ignored
# elsewhere. Matches lib/paths.sh's assumption that the file is the
# intersection of valid bash and a strict allowlist.
_ASSIGNMENT_RE = re.compile(
    r"""
    ^\s*
    (?:export\s+)?
    (?P<key>[A-Z][A-Z0-9_]*)
    \s*=\s*
    (?:
        "(?P<dquoted>[^"\\$`]*(?:\$[A-Za-z_][A-Za-z0-9_]*[^"\\$`]*)*)"
      | '(?P<squoted>[^']*)'
      | (?P<bare>[^\s;|&<>(){}#`$]*)
    )
    \s*(?:\#.*)?$
    """,
    re.VERBOSE,
)

# Variables we are willing to read from the config file. Anything else
# raises — protects against typos and against config files growing
# unexpected keys that callers silently ignore.
_ALLOWED_KEYS = frozenset(
    {
        "PA_VAULT",
        "PA_PROJECTS_DIR",
        "PA_TERMINAL_BACKEND",
        "PA_MAIN_TITLE",
        "PA_DAILY_DIR",
        "PA_DAILY_TEMPLATE_PATH",
        "PA_WORK_SECTION",
        "PA_PERSONAL_SECTION",
        "PA_FEATURE_NOTE_DIR",
        "PA_STATUS_VALUES",
        "PA_STATUS_SHIPPED",
        "PA_SPAWN_PROMPT_TEMPLATE",
        "PA_DASHBOARD_INTERVAL",
        "PA_DEBUG",
    }
)

_VALID_BACKENDS = frozenset({"auto", "wezterm", "kitty", "iterm2", "tmux"})

# Shared security primitives — used both here (defence-in-depth on the
# bash-sourced user config) and by lib/pa/preset_loader.py (primary check
# on third-party preset files). Single source of truth.
#
# Forbidden substrings (regex-independent check; catches escapes that
# would only be dangerous in a shell context):
#   $(   command substitution
#   ${   brace-form variable expansion (we don't implement it)
#   `    backtick command substitution
#   \    escape sequences
_FORBIDDEN_SUBSTRINGS: tuple[str, ...] = (
    "$(",
    "${",
    "`",
    "\\",
)

# Strict bare-value character class — used by preset_loader's regex and
# by validate_assignments. Letters, digits, underscore, plus a small set
# of structural characters that paths and placeholders need.
_STRICT_BARE_CHARS = r"[\w./:,=+@~{}-]"
_STRICT_BARE_BODY = (
    rf"{_STRICT_BARE_CHARS}*"
    rf"(?:\$[A-Za-z_][A-Za-z0-9_]*{_STRICT_BARE_CHARS}*)*"
)
# Strict double-quoted body — anything except structural characters that
# would break out of the quoted form.
_STRICT_DQUOTED_CHARS = r"[^\"\\$`]"
_STRICT_DQUOTED_BODY = (
    rf"{_STRICT_DQUOTED_CHARS}*"
    rf"(?:\$[A-Za-z_][A-Za-z0-9_]*{_STRICT_DQUOTED_CHARS}*)*"
)
# Strict assignment regex — the canonical form for preset files and for
# validate_assignments (wizard input). Tighter than _ASSIGNMENT_RE above,
# which exists for parsing the bash-written user config and so must
# accept single quotes / a wider bare class.
_STRICT_ASSIGNMENT_RE = re.compile(
    r"""
    ^\s*
    (?:export\s+)?
    (?P<key>[A-Z][A-Z0-9_]*)
    \s*=\s*
    (?:
        "(?P<dquoted>""" + _STRICT_DQUOTED_BODY + r""")"
      | (?P<bare>""" + _STRICT_BARE_BODY + r""")
    )
    \s*(?:\#.*)?$
    """,
    re.VERBOSE,
)

_DEFAULTS = {
    "PA_TERMINAL_BACKEND": "auto",
    "PA_MAIN_TITLE": "MAIN",
    "PA_DAILY_DIR": "Daily",
    "PA_DAILY_TEMPLATE_PATH": "_templates/Daily Note.md",
    "PA_WORK_SECTION": "Work",
    "PA_PERSONAL_SECTION": "Personal",
    "PA_FEATURE_NOTE_DIR": "PROJECTS",
    "PA_STATUS_VALUES": "brainstorming,planned,in-progress,shipped",
    "PA_STATUS_SHIPPED": "shipped",
    "PA_SPAWN_PROMPT_TEMPLATE": "",
    "PA_DASHBOARD_INTERVAL": "2",
    "PA_DEBUG": "0",
}


@dataclass(frozen=True)
class Config:
    """Resolved configuration. All paths absolute. All values validated."""

    config_path: Path
    data_dir: Path
    vault: Path
    projects_dir: Path
    terminal_backend: str
    main_title: str
    daily_dir: str
    daily_template_path: str
    work_section: str
    personal_section: str
    feature_note_dir: str
    status_values: tuple[str, ...]
    status_shipped: str
    spawn_prompt_template: str
    dashboard_interval: int
    debug: bool
    raw: dict[str, str] = field(default_factory=dict, repr=False)

    @property
    def state_dir(self) -> Path:
        return self.data_dir / "state"

    @property
    def cache_dir(self) -> Path:
        return self.data_dir / "cache"

    @property
    def logs_dir(self) -> Path:
        return self.data_dir / "logs"

    @property
    def daily_template(self) -> Path:
        return self.vault / self.daily_template_path

    @property
    def daily_path(self) -> Path:
        return self.vault / self.daily_dir

    @property
    def feature_notes_root(self) -> Path:
        return self.vault / self.feature_note_dir


def _xdg(name: str, default_suffix: str) -> Path:
    explicit = os.environ.get(name)
    if explicit:
        return Path(explicit)
    return Path.home() / default_suffix


def _default_config_path() -> Path:
    explicit = os.environ.get("PA_CONFIG")
    if explicit:
        return Path(explicit)
    return _xdg("XDG_CONFIG_HOME", ".config") / "claude-pa" / "config.sh"


def _default_data_dir() -> Path:
    explicit = os.environ.get("PA_DATA_DIR")
    if explicit:
        return Path(explicit)
    return _xdg("XDG_DATA_HOME", ".local/share") / "claude-pa"


def _expand(value: str) -> str:
    """Expand ``~`` and a small whitelist of env vars. No subprocess, no globbing."""
    # ``os.path.expandvars`` is fine here because we have already parsed the
    # value out of the file with a regex that rejects backticks and command
    # substitution. The remaining $VAR refs are inert lookups.
    return os.path.expanduser(os.path.expandvars(value))


def _parse_file(path: Path) -> dict[str, str]:
    raw: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise ConfigError(
            f"pa: config missing at {path} — run `pa init` first."
        ) from exc

    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        match = _ASSIGNMENT_RE.match(line)
        if not match:
            raise ConfigError(
                f"pa: {path}:{lineno}: cannot parse line "
                f"(expected KEY=VALUE or KEY=\"VALUE\"): {line.rstrip()!r}"
            )

        key = match.group("key")
        if key not in _ALLOWED_KEYS:
            raise ConfigError(
                f"pa: {path}:{lineno}: unknown key {key!r} "
                f"(allowed: {sorted(_ALLOWED_KEYS)})"
            )

        value = (
            match.group("dquoted")
            or match.group("squoted")
            or match.group("bare")
            or ""
        )
        for needle in _FORBIDDEN_SUBSTRINGS:
            if needle in value:
                raise ConfigError(
                    f"pa: {path}:{lineno}: value for {key} contains forbidden "
                    f"shell metacharacter {needle!r}"
                )
        raw[key] = _expand(value)

    return raw


def _autodetect_backend() -> str:
    if os.environ.get("TMUX"):
        return "tmux"
    term_program = os.environ.get("TERM_PROGRAM", "")
    if term_program == "WezTerm":
        return "wezterm"
    if term_program == "iTerm.app":
        return "iterm2"
    if os.environ.get("KITTY_WINDOW_ID"):
        return "kitty"
    return "tmux"


def load_config(
    config_path: Path | str | None = None,
    data_dir: Path | str | None = None,
) -> Config:
    """Parse the config file and return a validated :class:`Config`.

    Args:
        config_path: Override the resolved config file. Defaults to
            $PA_CONFIG or $XDG_CONFIG_HOME/claude-pa/config.sh.
        data_dir: Override the data root. Defaults to $PA_DATA_DIR or
            $XDG_DATA_HOME/claude-pa.

    Raises:
        ConfigError: missing file, malformed line, unknown key, missing
            required var, invalid value, or required path that doesn't exist.
    """
    cfg_path = Path(config_path) if config_path else _default_config_path()
    data_root = Path(data_dir) if data_dir else _default_data_dir()

    raw = _parse_file(cfg_path)

    merged = {**_DEFAULTS, **raw}

    for required in ("PA_VAULT", "PA_PROJECTS_DIR"):
        if not merged.get(required):
            raise ConfigError(
                f"pa: {required} is unset in {cfg_path} — run `pa init` to repair."
            )

    vault = Path(merged["PA_VAULT"])
    projects = Path(merged["PA_PROJECTS_DIR"])
    for name, p in (("PA_VAULT", vault), ("PA_PROJECTS_DIR", projects)):
        if not p.is_dir():
            raise ConfigError(
                f"pa: {name}={p} does not exist or is not a directory."
            )

    backend = merged["PA_TERMINAL_BACKEND"]
    if backend not in _VALID_BACKENDS:
        raise ConfigError(
            f"pa: PA_TERMINAL_BACKEND={backend!r} is not one of "
            f"{sorted(_VALID_BACKENDS)}."
        )
    if backend == "auto":
        backend = _autodetect_backend()

    try:
        dashboard_interval = int(merged["PA_DASHBOARD_INTERVAL"])
    except ValueError as exc:
        raise ConfigError(
            f"pa: PA_DASHBOARD_INTERVAL={merged['PA_DASHBOARD_INTERVAL']!r} "
            "must be an integer."
        ) from exc
    if dashboard_interval < 1:
        raise ConfigError("pa: PA_DASHBOARD_INTERVAL must be >= 1.")

    status_values = tuple(
        s.strip() for s in merged["PA_STATUS_VALUES"].split(",") if s.strip()
    )
    if not status_values:
        raise ConfigError("pa: PA_STATUS_VALUES must list at least one status.")
    if merged["PA_STATUS_SHIPPED"] not in status_values:
        raise ConfigError(
            f"pa: PA_STATUS_SHIPPED={merged['PA_STATUS_SHIPPED']!r} is not "
            f"in PA_STATUS_VALUES={list(status_values)}."
        )

    return Config(
        config_path=cfg_path,
        data_dir=data_root,
        vault=vault,
        projects_dir=projects,
        terminal_backend=backend,
        main_title=merged["PA_MAIN_TITLE"],
        daily_dir=merged["PA_DAILY_DIR"],
        daily_template_path=merged["PA_DAILY_TEMPLATE_PATH"],
        work_section=merged["PA_WORK_SECTION"],
        personal_section=merged["PA_PERSONAL_SECTION"],
        feature_note_dir=merged["PA_FEATURE_NOTE_DIR"],
        status_values=status_values,
        status_shipped=merged["PA_STATUS_SHIPPED"],
        spawn_prompt_template=merged["PA_SPAWN_PROMPT_TEMPLATE"],
        dashboard_interval=dashboard_interval,
        debug=merged["PA_DEBUG"] not in ("0", "", "false", "False"),
        raw=raw,
    )


def ensure_runtime_dirs(cfg: Config) -> None:
    """Create state/cache/logs dirs with 0700 perms. Idempotent."""
    for d in (cfg.data_dir, cfg.state_dir, cfg.cache_dir, cfg.logs_dir):
        d.mkdir(parents=True, exist_ok=True)
        d.chmod(0o700)


# Source-label suffix used by the wizard to thread "where did this value
# come from" through the validator. Pattern: ``KEY=VALUE\t# (source)``.
_SOURCE_LABEL_RE = re.compile(r"^(?P<assignment>.*?)\s*\t#\s*(?P<source>\(.+\))\s*$")


def validate_assignments(
    lines: list[str],
) -> tuple[list[str], list[str]]:
    """Validate KEY=VALUE assignments and emit shell-quoted output.

    Reads a list of input lines, each ``KEY=VALUE`` optionally followed by
    a tab + ``# (source)`` label (e.g. ``PA_VAULT=/foo\\t# (auto-detect)``).
    Applies the same allowlist + regex + forbidden-substring + semantic
    checks used by :func:`load_config`, plus a required-key presence check
    over ``PA_VAULT`` and ``PA_PROJECTS_DIR``.

    Args:
        lines: Raw assignment lines (no trailing newlines required).

    Returns:
        A pair ``(out, errs)``:
        - ``out``: ``KEY="<shell-quoted>"`` lines (each followed by the
          original ``\\t# (source)`` label, when one was provided).
        - ``errs``: ``pa init: <KEY>: <error>`` lines, one per failed
          assignment plus one entry per missing required key.

    Raises:
        Nothing — all problems surface in ``errs``. Callers decide
        success vs failure by checking whether ``errs`` is empty.
    """
    seen: dict[str, str] = {}
    sources: dict[str, str] = {}
    out: list[str] = []
    errs: list[str] = []

    for raw_line in lines:
        line = raw_line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue

        # Split off the optional `\t# (source)` suffix so the assignment
        # parser only sees `KEY=VALUE`.
        source_label = ""
        if label_match := _SOURCE_LABEL_RE.match(line):
            line = label_match.group("assignment")
            source_label = label_match.group("source")

        match = _STRICT_ASSIGNMENT_RE.match(line)
        if not match:
            errs.append(
                f"pa init: <unparseable>: cannot parse {line.rstrip()!r}"
            )
            continue

        key = match.group("key")
        if key not in _ALLOWED_KEYS:
            errs.append(
                f"pa init: {key}: unknown key (allowed: {sorted(_ALLOWED_KEYS)})"
            )
            continue

        raw_value = match.group("dquoted")
        if raw_value is None:
            raw_value = match.group("bare") or ""

        forbidden_hit = next(
            (n for n in _FORBIDDEN_SUBSTRINGS if n in raw_value), None
        )
        if forbidden_hit is not None:
            errs.append(
                f"pa init: {key}: forbidden shell metacharacter {forbidden_hit!r}"
            )
            continue

        value = _expand(raw_value)

        # Semantic checks for keys that have a tighter contract than
        # "string that matched the strict regex".
        if key == "PA_TERMINAL_BACKEND" and value not in _VALID_BACKENDS:
            errs.append(
                f"pa init: {key}: {value!r} is not one of "
                f"{sorted(_VALID_BACKENDS)}"
            )
            continue
        if key == "PA_DASHBOARD_INTERVAL":
            try:
                ivalue = int(value)
            except ValueError:
                errs.append(
                    f"pa init: {key}: {value!r} is not an integer"
                )
                continue
            if ivalue < 1:
                errs.append(f"pa init: {key}: must be >= 1")
                continue

        seen[key] = value
        sources[key] = source_label

    # Cross-key checks deferred until all assignments are parsed, so we
    # can validate referential rules (PA_STATUS_SHIPPED ∈ PA_STATUS_VALUES).
    if "PA_STATUS_VALUES" in seen and "PA_STATUS_SHIPPED" in seen:
        status_values = tuple(
            s.strip() for s in seen["PA_STATUS_VALUES"].split(",") if s.strip()
        )
        if not status_values:
            errs.append("pa init: PA_STATUS_VALUES: must list at least one status")
        elif seen["PA_STATUS_SHIPPED"] not in status_values:
            errs.append(
                f"pa init: PA_STATUS_SHIPPED: "
                f"{seen['PA_STATUS_SHIPPED']!r} not in {list(status_values)}"
            )

    for required in ("PA_VAULT", "PA_PROJECTS_DIR"):
        if required not in seen:
            errs.append(f"pa init: {required}: missing required key")

    if errs:
        return [], errs

    # Emit shell-quoted assignments. ``shlex.quote`` makes the right
    # quoting decision; values already passed every check, so the bash
    # source has no way to interpret them as anything but literals.
    for key, value in seen.items():
        suffix = f"\t# {sources[key]}" if sources[key] else ""
        out.append(f"{key}={shlex.quote(value)}{suffix}")

    return out, errs


def _validate_assignments_cli() -> int:
    """Entry point for ``python3 -m pa.paths validate-assignments``.

    Reads stdin, calls :func:`validate_assignments`, prints output lines
    to stdout, error lines to stderr. Exits 0 on success, 2 on any
    validation failure.
    """
    lines = sys.stdin.read().splitlines()
    out, errs = validate_assignments(lines)
    for line in out:
        print(line)
    for err in errs:
        print(err, file=sys.stderr)
    return 2 if errs else 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "validate-assignments":
        sys.exit(_validate_assignments_cli())
    sys.exit("usage: python3 -m pa.paths validate-assignments < KEY=VALUE-lines")
