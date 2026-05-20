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
