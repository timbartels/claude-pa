"""Shared fixtures for pytest suites.

Each fixture yields a path or environment isolated to a tempdir so tests
never touch the user's real config or vault. All tests run with the
plugin's `lib/` on PYTHONPATH (pyproject.toml configures that).
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest


@pytest.fixture
def fake_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> dict[str, Path]:
    """Build a minimal claude-pa environment inside ``tmp_path``.

    Returns a mapping of named locations for tests to seed extra content.
    Sets PA_CONFIG and PA_DATA_DIR so ``pa.paths.load_config`` picks them
    up. Caller may further override config keys by editing ``config.sh``
    after this fixture runs (re-call ``load_config`` to refresh).
    """
    vault = tmp_path / "vault"
    daily = vault / "Daily"
    projects = tmp_path / "projects"
    templates = vault / "_templates"
    feature_root = vault / "PROJECTS"
    data = tmp_path / "data"
    state = data / "state"

    for p in (daily, templates, feature_root, projects, state):
        p.mkdir(parents=True, exist_ok=True)
    (templates / "Daily Note.md").write_text("# {{date}}\n## Work\n## Personal\n")

    config = tmp_path / "config.sh"
    config.write_text(
        f"PA_VAULT={vault}\n"
        f"PA_PROJECTS_DIR={projects}\n"
        f"PA_TERMINAL_BACKEND=tmux\n"
        f"PA_MAIN_TITLE=MAIN\n"
    )

    monkeypatch.setenv("PA_CONFIG", str(config))
    monkeypatch.setenv("PA_DATA_DIR", str(data))
    monkeypatch.delenv("PA_VAULT", raising=False)
    monkeypatch.delenv("PA_PROJECTS_DIR", raising=False)

    return {
        "vault": vault,
        "daily": daily,
        "templates": templates,
        "feature_root": feature_root,
        "projects": projects,
        "data": data,
        "state": state,
        "config": config,
    }


@pytest.fixture
def seed_state(fake_env: dict[str, Path]):
    """Helper to drop a state JSON file under $PA_DATA_DIR/state/."""

    def _seed(repo: str, **fields) -> Path:
        path = fake_env["state"] / f"{repo}.json"
        defaults = {
            "repo": repo,
            "pane_id": "%7",
            "cwd": str(fake_env["projects"] / repo),
            "last_update": "2026-05-21T08:00:00",
            "last_event": "Stop",
            "idle": True,
            "events": [],
        }
        defaults.update(fields)
        path.write_text(json.dumps(defaults, indent=2))
        return path

    return _seed
