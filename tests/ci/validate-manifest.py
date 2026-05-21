#!/usr/bin/env python3
"""Validate the claude-pa plugin manifests + hooks + MCP wiring.

Offline structural check (no schema fetch). Runs in CI on every push +
PR. Exits 0 on green; exits 1 on the first violation with a specific
``path: detail`` message.

Files checked:
  .claude-plugin/plugin.json
  .claude-plugin/marketplace.json
  hooks/hooks.json
  .mcp.json
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

EXPECTED_HOOKS = {
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "Stop",
    "SessionEnd",
}

_SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.]+)?$")
_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")

_errors: list[str] = []


def fail(path: Path, detail: str) -> None:
    _errors.append(f"{path.relative_to(REPO_ROOT)}: {detail}")


def _load(path: Path) -> dict | None:
    if not path.exists():
        fail(path, "file missing")
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(path, f"invalid JSON: {exc}")
        return None


def _require(d: dict, key: str, path: Path, kind: type | None = None) -> object | None:
    if key not in d:
        fail(path, f"missing required key '{key}'")
        return None
    value = d[key]
    if kind is not None and not isinstance(value, kind):
        fail(path, f"key '{key}' must be {kind.__name__}, got {type(value).__name__}")
        return None
    return value


def check_plugin_json(path: Path, version_ref: dict) -> None:
    data = _load(path)
    if data is None:
        return
    name = _require(data, "name", path, str)
    if name is not None and not _NAME_RE.match(name):
        fail(path, f"name {name!r} must match {_NAME_RE.pattern}")
    _require(data, "description", path, str)
    version = _require(data, "version", path, str)
    if version is not None:
        if not _SEMVER_RE.match(version):
            fail(path, f"version {version!r} is not semver")
        version_ref["plugin"] = version
    if "userConfig" in data:
        uc = data["userConfig"]
        if not isinstance(uc, dict):
            fail(path, "userConfig must be an object")
        else:
            for k, v in uc.items():
                if not isinstance(v, dict):
                    fail(path, f"userConfig.{k} must be an object")
                    continue
                if "description" not in v or "type" not in v:
                    fail(path, f"userConfig.{k} missing description or type")


def check_marketplace_json(path: Path) -> None:
    data = _load(path)
    if data is None:
        return
    _require(data, "name", path, str)
    _require(data, "description", path, str)
    plugins = _require(data, "plugins", path, list)
    if plugins is None:
        return
    if not plugins:
        fail(path, "plugins[] is empty")
    for i, entry in enumerate(plugins):
        if not isinstance(entry, dict):
            fail(path, f"plugins[{i}] must be an object")
            continue
        _require(entry, "name", path, str)
        _require(entry, "source", path, str)


def check_hooks_json(path: Path) -> None:
    data = _load(path)
    if data is None:
        return
    hooks = _require(data, "hooks", path, dict)
    if hooks is None:
        return
    declared = set(hooks.keys())
    missing = EXPECTED_HOOKS - declared
    if missing:
        fail(path, f"missing hook events: {sorted(missing)}")
    extra = declared - EXPECTED_HOOKS
    if extra:
        fail(path, f"unknown hook events: {sorted(extra)}")
    for event, entries in hooks.items():
        if not isinstance(entries, list):
            fail(path, f"hooks.{event} must be a list")
            continue
        for j, entry in enumerate(entries):
            sub = entry.get("hooks")
            if not isinstance(sub, list) or not sub:
                fail(path, f"hooks.{event}[{j}].hooks must be a non-empty list")
                continue
            for k, h in enumerate(sub):
                if h.get("type") != "command":
                    fail(path, f"hooks.{event}[{j}].hooks[{k}].type must be 'command'")
                cmd = h.get("command", "")
                if not cmd.startswith("${CLAUDE_PLUGIN_ROOT}/"):
                    fail(
                        path,
                        f"hooks.{event}[{j}].hooks[{k}].command must start with "
                        "${CLAUDE_PLUGIN_ROOT}/ for portability",
                    )


def check_mcp_json(path: Path) -> None:
    data = _load(path)
    if data is None:
        return
    servers = _require(data, "mcpServers", path, dict)
    if servers is None:
        return
    if "claude-pa" not in servers:
        fail(path, "mcpServers must define 'claude-pa'")
        return
    server = servers["claude-pa"]
    _require(server, "command", path, str)
    args = _require(server, "args", path, list)
    if args is not None and (
        len(args) < 2 or args[0] != "-m" or not isinstance(args[1], str)
    ):
        fail(path, "args should be ['-m', 'pa.<module>']")


def main() -> int:
    version_ref: dict[str, str] = {}
    check_plugin_json(REPO_ROOT / ".claude-plugin" / "plugin.json", version_ref)
    check_marketplace_json(REPO_ROOT / ".claude-plugin" / "marketplace.json")
    check_hooks_json(REPO_ROOT / "hooks" / "hooks.json")
    check_mcp_json(REPO_ROOT / ".mcp.json")

    if _errors:
        for err in _errors:
            print(f"manifest validation failed: {err}", file=sys.stderr)
        return 1
    print("manifest validation: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
