"""Tests for pa.mcp_server tool dispatch + JSON-RPC handling."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import pa.mcp_server as mod
from pa.paths import load_config


def test_tool_specs_well_formed():
    names = {t["name"] for t in mod.TOOL_SPECS}
    assert names == {
        "peek_pane",
        "list_panes",
        "aggregate_todos",
        "current_state",
        "dispatch_to_pane",
    }
    for spec in mod.TOOL_SPECS:
        assert "description" in spec
        assert spec["inputSchema"]["type"] == "object"


def test_peek_pane_returns_state(fake_env, seed_state):
    cfg = load_config()
    seed_state("foo", todos=[{"content": "x", "status": "pending"}])
    result = mod.tool_peek_pane(cfg, "foo")
    assert result["repo"] == "foo"
    assert result["todos"][0]["content"] == "x"


def test_peek_pane_missing_returns_empty(fake_env):
    cfg = load_config()
    assert mod.tool_peek_pane(cfg, "nope") == {}


def test_peek_pane_rejects_path_traversal(fake_env):
    cfg = load_config()
    with pytest.raises(ValueError, match="invalid repo"):
        mod.tool_peek_pane(cfg, "../etc")


def test_list_panes_skips_session_files(fake_env, seed_state):
    cfg = load_config()
    seed_state("foo")
    seed_state("bar")
    (fake_env["state"] / "vault-session-2026-05-21.json").write_text("{}")
    result = mod.tool_list_panes(cfg)
    repos = {entry["repo"] for entry in result}
    assert repos == {"foo", "bar"}


def test_aggregate_todos_sorts_by_status(fake_env, seed_state):
    cfg = load_config()
    seed_state(
        "foo",
        todos=[
            {"content": "later", "status": "pending"},
            {"content": "done", "status": "completed"},
            {"content": "now", "status": "in_progress", "activeForm": "Doing now"},
        ],
    )
    result = mod.tool_aggregate_todos(cfg)
    statuses = [r["status"] for r in result]
    assert statuses == ["in_progress", "pending", "completed"]
    assert result[0]["content"] == "Doing now"  # activeForm wins for in_progress


def test_current_state_dispatches(fake_env, seed_state):
    cfg = load_config()
    seed_state("foo")
    seed_state("bar")
    # No repo → list_panes
    assert isinstance(mod.tool_current_state(cfg), list)
    # With repo → peek_pane
    result = mod.tool_current_state(cfg, "foo")
    assert isinstance(result, dict)
    assert result["repo"] == "foo"


def test_handle_initialize(fake_env):
    cfg = load_config()
    reply = mod._handle(cfg, {"jsonrpc": "2.0", "id": 1, "method": "initialize"})
    assert reply["result"]["serverInfo"]["name"] == "claude-pa"
    assert reply["result"]["protocolVersion"] == "2024-11-05"


def test_handle_tools_list(fake_env):
    cfg = load_config()
    reply = mod._handle(cfg, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    assert {t["name"] for t in reply["result"]["tools"]} == {
        "peek_pane", "list_panes", "aggregate_todos", "current_state", "dispatch_to_pane",
    }


def test_handle_tools_call_peek_pane(fake_env, seed_state):
    cfg = load_config()
    seed_state("foo", pane_id="%42")
    reply = mod._handle(
        cfg,
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": "peek_pane", "arguments": {"repo": "foo"}},
        },
    )
    body = json.loads(reply["result"]["content"][0]["text"])
    assert body["pane_id"] == "%42"


def test_handle_unknown_tool(fake_env):
    cfg = load_config()
    reply = mod._handle(
        cfg,
        {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {"name": "nope", "arguments": {}},
        },
    )
    assert reply["error"]["code"] == -32601


def test_handle_initialized_notification_returns_none(fake_env):
    cfg = load_config()
    reply = mod._handle(cfg, {"jsonrpc": "2.0", "method": "notifications/initialized"})
    assert reply is None
