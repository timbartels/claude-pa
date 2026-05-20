"""SessionStart hook: auto-load matching vault feature notes into project Claude context.

Skips when the session is started inside the vault itself (orchestrator conv).
Matches feature notes whose ``tags:`` frontmatter contains the current
project name (derived from git remote basename, falling back to CWD
basename) and whose ``status:`` is not the configured "shipped" value.
Pulled from today's daily note wikilinks.

Reads vault root, feature-note dir, daily dir, and shipped-status value
from the user's ``$PA_CONFIG`` via :func:`pa.paths.load_config`. The hook
shim at ``hooks/scripts/load-vault-context.py`` is a thin entry-point that
calls :func:`main`.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import date
from pathlib import Path

from pa.paths import Config, ConfigError, load_config


def _resolve_project_name(cwd: Path) -> str:
    project = cwd.name
    if not (cwd / ".git").exists():
        return project
    try:
        remote = subprocess.check_output(
            ["git", "-C", str(cwd), "remote", "get-url", "origin"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return project
    if not remote:
        return project
    return Path(remote.rstrip("/").removesuffix(".git")).name


def _daily_block_for(daily_lines: list[str], link_path: str) -> list[str]:
    """Return the parent checkbox line for ``link_path`` plus its indented children."""
    block: list[str] = []
    for idx, line in enumerate(daily_lines):
        if f"[[{link_path}" not in line:
            continue
        if not re.match(r"^\s*- \[[ x]\]", line):
            continue
        block.append(line)
        parent_indent = len(line) - len(line.lstrip())
        for follow in daily_lines[idx + 1 :]:
            if not follow.strip():
                break
            follow_indent = len(follow) - len(follow.lstrip())
            if follow_indent <= parent_indent:
                break
            block.append(follow)
    return block


def _build_context(cfg: Config, cwd: Path) -> str | None:
    """Return the context string to emit, or ``None`` if there's nothing to add."""
    project = _resolve_project_name(cwd)
    today = date.today().isoformat()
    daily = cfg.daily_path / f"{today}.md"
    if not daily.exists():
        return None

    daily_text = daily.read_text(encoding="utf-8")
    feature_dir_re = re.escape(cfg.feature_note_dir)
    links = sorted(set(re.findall(r"\[\[(" + feature_dir_re + r"/[^\]|]+)", daily_text)))
    if not links:
        return None

    matched: list[tuple[Path, str, str]] = []
    for link in links:
        note = cfg.vault / f"{link.strip()}.md"
        if not note.exists():
            continue
        body = note.read_text(encoding="utf-8")
        fm_match = re.match(r"---\n(.*?)\n---\n", body, re.DOTALL)
        if not fm_match:
            continue
        fm = fm_match.group(1)
        tags_match = re.search(r"^tags:\s*\[(.*?)\]", fm, re.MULTILINE)
        status_match = re.search(r"^status:\s*(\S+)", fm, re.MULTILINE)
        tags = (
            [t.strip() for t in tags_match.group(1).split(",")] if tags_match else []
        )
        if project not in tags:
            continue
        status = status_match.group(1).lower() if status_match else ""
        if status == cfg.status_shipped.lower():
            continue
        matched.append((note, body, status))

    if not matched:
        return None

    daily_lines = daily_text.splitlines()
    parts = [
        f"Vault context auto-loaded for project '{project}' "
        f"(daily note {today}):\n"
    ]
    for note, body, status in matched:
        link_path = str(note.relative_to(cfg.vault)).removesuffix(".md")
        today_block = _daily_block_for(daily_lines, link_path)
        intent_section = ""
        if today_block:
            intent_section = (
                "### Today's intent (from daily note)\n\n"
                + "\n".join(today_block)
                + "\n\n"
            )
        parts.append(
            f"\n---\n## {note.stem} (status: {status or 'unknown'})\n\n"
            f"{intent_section}### Feature note\n\n{body}\n"
        )
    return "".join(parts)


def main() -> None:
    try:
        cfg = load_config()
    except ConfigError as exc:
        # Config-less environment shouldn't crash the parent session. Emit
        # nothing and let the rest of the SessionStart pipeline continue.
        print(f"pa.vault_context: {exc}", file=sys.stderr)
        sys.exit(0)

    cwd = Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()).resolve()

    # Skip when we're inside the vault itself — that's the orchestrator
    # conversation, which has its own SKILL-driven context.
    try:
        cwd.relative_to(cfg.vault.resolve())
        sys.exit(0)
    except ValueError:
        pass

    context = _build_context(cfg, cwd)
    if context is None:
        sys.exit(0)

    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart",
                    "additionalContext": context,
                }
            }
        )
    )


if __name__ == "__main__":
    main()
