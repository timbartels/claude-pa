"""Tests for pa.state_update.main hook entry point."""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

import pa.state_update as mod


def _run_hook(event: dict, cwd: Path) -> None:
    """Invoke main() with simulated stdin + CWD."""
    old_stdin = sys.stdin
    old_cwd = os.getcwd()
    sys.stdin = io.StringIO(json.dumps(event))
    try:
        os.chdir(cwd)
        mod.main()
    finally:
        sys.stdin = old_stdin
        os.chdir(old_cwd)


def test_session_start_writes_state(fake_env):
    repo = fake_env["projects"] / "myrepo"
    repo.mkdir()
    subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True)

    _run_hook({"hook_event_name": "SessionStart"}, repo)
    state_file = fake_env["state"] / "myrepo.json"
    assert state_file.exists()
    state = json.loads(state_file.read_text())
    assert state["repo"] == "myrepo"
    assert state["last_event"] == "SessionStart"
    assert state["idle"] is False
    assert state["session_started"]


def test_user_prompt_captures_slash_command(fake_env):
    repo = fake_env["projects"] / "myrepo"
    repo.mkdir()
    _run_hook(
        {
            "hook_event_name": "UserPromptSubmit",
            "prompt": "/workflows:plan add login",
        },
        repo,
    )
    state = json.loads((fake_env["state"] / "myrepo.json").read_text())
    assert state["last_prompt"].startswith("/workflows:plan")
    assert state["current_workflow"] == "workflows:plan"


def test_pre_tool_use_captures_todos(fake_env):
    repo = fake_env["projects"] / "myrepo"
    repo.mkdir()
    _run_hook(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "TodoWrite",
            "tool_input": {
                "todos": [
                    {"content": "do", "status": "pending"},
                    {
                        "content": "doing",
                        "status": "in_progress",
                        "activeForm": "Doing the thing",
                    },
                ]
            },
        },
        repo,
    )
    state = json.loads((fake_env["state"] / "myrepo.json").read_text())
    assert state["last_tool"] == "TodoWrite"
    assert len(state["todos"]) == 2
    assert state["todos"][1]["activeForm"] == "Doing the thing"


def test_session_end_unlinks_state(fake_env):
    repo = fake_env["projects"] / "myrepo"
    repo.mkdir()
    # First create some state
    _run_hook({"hook_event_name": "SessionStart"}, repo)
    state_file = fake_env["state"] / "myrepo.json"
    assert state_file.exists()
    # Then SessionEnd removes it
    _run_hook({"hook_event_name": "SessionEnd"}, repo)
    assert not state_file.exists()


def test_vault_cwd_skips_write(fake_env):
    # CWD inside vault → orchestrator session; must not write state
    _run_hook({"hook_event_name": "UserPromptSubmit", "prompt": "hi"}, fake_env["vault"])
    # No per-repo file should appear
    json_files = [
        p for p in fake_env["state"].glob("*.json")
        if not p.name.startswith("vault-session-")
    ]
    assert json_files == []
