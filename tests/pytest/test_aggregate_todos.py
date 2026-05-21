"""Tests for pa.aggregate_todos.main."""

from __future__ import annotations

import json
import sys

import pytest

import pa.aggregate_todos as mod


def test_empty_state_dir(fake_env, capsys):
    # state dir exists from fake_env but empty — should print the friendly empty msg
    mod.main()
    out = capsys.readouterr().out
    assert "no tasks reported yet" in out


def test_aggregates_in_priority_order(fake_env, seed_state, capsys):
    seed_state(
        "bar",
        todos=[
            {"content": "shipped item", "status": "completed"},
        ],
    )
    seed_state(
        "foo",
        todos=[
            {"content": "pending item", "status": "pending"},
            {"content": "active item", "status": "in_progress", "activeForm": "Doing active"},
        ],
    )

    mod.main()
    out = capsys.readouterr().out.splitlines()
    # Header + 3 rows
    assert out[0].startswith("STATE")
    assert "Doing active" in out[1]  # in_progress sorts first
    assert "pending item" in out[2]
    assert "shipped item" in out[3]


def test_skips_session_files(fake_env, seed_state, capsys):
    # vault-session-* files should be ignored
    (fake_env["state"] / "vault-session-2026-05-21.json").write_text(
        '{"date":"2026-05-21","morning_done":true}'
    )
    seed_state("foo", todos=[{"content": "real todo", "status": "pending"}])
    mod.main()
    out = capsys.readouterr().out
    assert "real todo" in out
    assert "morning_done" not in out
