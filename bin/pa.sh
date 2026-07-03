#!/usr/bin/env bash
# pa.sh — claude-pa dispatcher. Single entry point for every PA helper.
#
# Usage:
#   pa.sh send <prompt> <pane-id> [<pane-id>...]
#   pa.sh focus <pane-id> [<title-substring>]
#   pa.sh spawn <repo> <initial-prompt>
#   pa.sh tick                          # tick daily-note [[link]] checkboxes for shipped feature notes
#   pa.sh status                        # one-line per active feature note: title, status, repo(s)
#   pa.sh peek <repo>                   # show detailed live state for one project Claude
#   pa.sh peek-all                      # one-line per project Claude that has reported state
#   pa.sh ask <pane|repo> <prompt> [timeout]  # submit prompt, wait for idle, print reply
#   pa.sh tell <pane|repo> <prompt>     # fire-and-forget: submit, don't wait
#   pa.sh snap --project <name> <screen-name>  # adb screencap → vault project/manual/screenshots/<name>.png
#   pa.sh shutdown                      # EOD: save each project pane's buffer to vault, close it; keeps main + dashboard
#   pa.sh drift                         # warn when the plugin cache drifted from the marketplace clone
#   pa.sh dashboard [interval]          # idempotently spawn (or focus) the live dashboard (wezterm only)
#   pa.sh watch [interval]              # live dashboard in current pane
#   pa.sh todos                         # flatten TodoWrite across all panes, prioritized
#   pa.sh broadcast <prompt>            # submit <prompt> to every project pane
#   pa.sh pr-status [<org>] <repo:branch>...  # one line per spec
#   pa.sh kill <repo>                   # kill the pane for <repo>
#   pa.sh restart <repo> [<prompt>]     # kill + respawn pane; default prompt from $PA_SPAWN_PROMPT_TEMPLATE
#   pa.sh resume                        # after terminal crash: respawn dead-pane state files with `claude --continue`
#   pa.sh session-touch [--morning-done] [--agenda-asked] [--note <text>]
#   pa.sh session-state                 # print today's vault-session state JSON (or {})
#   pa.sh session-resumable             # exit 0 if morning already done today
#   pa.sh help                          # this header

set -euo pipefail

# Self-locate. $(dirname "$0") instead of $CLAUDE_PLUGIN_ROOT because bin/-PATH
# invocations from Claude Code don't guarantee the env var (only hook/MCP do).
# Resolve $0 through symlinks so users can put `~/.local/bin/pa` or
# `~/.claude/pa/bin/pa.sh` as a symlink to the plugin install and still
# locate $PA_LIB correctly inside the plugin (the symlink chain points
# back into the cache dir).
_pa_real="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$0")"
PA_BIN="$(cd "$(dirname "$_pa_real")" && pwd)"
PA_PLUGIN_ROOT="$(cd "$PA_BIN/.." && pwd)"
PA_LIB="$PA_PLUGIN_ROOT/lib"

# shellcheck source=../lib/paths.sh
source "$PA_LIB/paths.sh"

# shellcheck source=/dev/null
source "$PA_LIB/terminal/${PA_TERMINAL_BACKEND}.sh"

case "$(uname -s)" in
  Darwin) # shellcheck source=../lib/window-raise/macos.sh
          source "$PA_LIB/window-raise/macos.sh" ;;
  Linux)  # shellcheck source=../lib/window-raise/linux.sh
          source "$PA_LIB/window-raise/linux.sh" ;;
  *)      window_raise() { return 1; } ;;
esac

# Inline-Python helpers and `python3 -m pa.<module>` calls resolve from lib/.
export PYTHONPATH="$PA_LIB${PYTHONPATH:+:$PYTHONPATH}"

cmd="${1:-}"
shift || true

case "$cmd" in
  send)
    msg="${1:-}"; shift || true
    if [[ -z "$msg" || $# -eq 0 ]]; then
      echo "usage: pa.sh send <prompt> <pane-id> [<pane-id>...]" >&2
      exit 2
    fi
    for pane in "$@"; do
      terminal_send "$pane" "$msg" || { echo "send failed on $pane" >&2; continue; }
      terminal_enter "$pane" || echo "enter failed on $pane" >&2
    done
    ;;

  focus)
    pane="${1:-}"
    tag="${2:-}"
    if [[ -z "$pane" ]]; then
      echo "usage: pa.sh focus <pane-id> [<title-substring>]" >&2
      exit 2
    fi
    # Tag tab title FIRST so window_raise has a unique substring to match
    # against (set_title wraps as [PA:$tag]). Required when focusing a
    # pane that wasn't spawned via pa.sh — e.g. a pane attached after
    # restart, or one whose title was reset by another tool.
    if [[ -n "$tag" ]]; then
      terminal_set_title "$pane" "$tag" >/dev/null 2>&1 || true
    fi
    terminal_activate "$pane" || { echo "activate failed on $pane" >&2; exit 1; }
    if [[ -n "$tag" ]]; then
      window_raise "$tag" || echo "window_raise: no window matched '$tag'" >&2
    fi
    ;;

  spawn)
    repo="${1:-}"
    prompt="${2:-}"
    if [[ -z "$repo" || -z "$prompt" ]]; then
      echo "usage: pa.sh spawn <repo> <initial-prompt>" >&2
      exit 2
    fi
    project_dir="$PA_PROJECTS_DIR/$repo"
    if [[ ! -d "$project_dir" ]]; then
      echo "spawn: $project_dir does not exist" >&2
      exit 1
    fi
    pane=$(terminal_spawn "$project_dir" "claude $(printf '%q' "$prompt")") || {
      echo "spawn failed" >&2; exit 1; }
    sleep 1
    if ! terminal_list | awk -F'|' '{print $1}' | grep -qx "$pane"; then
      echo "spawn failed: pane $pane disappeared" >&2
      exit 1
    fi
    terminal_set_title "$pane" "$repo" >/dev/null 2>&1 || true
    terminal_activate "$pane" >/dev/null 2>&1 || true
    window_raise "$repo" >/dev/null 2>&1 || true
    # Re-tile windows so the new pane lands in the user's slot (e.g.
    # macOS `relayout` script, or any equivalent in the user's $PATH).
    # Soft-fail when no tiler is installed.
    command -v relayout >/dev/null && relayout >/dev/null 2>&1 || true
    echo "$pane"
    ;;

  tick)
    today=$(date +%Y-%m-%d)
    daily="$PA_VAULT/$PA_DAILY_DIR/$today.md"
    if [[ ! -f "$daily" ]]; then
      echo "no daily note for $today" >&2
      exit 0
    fi
    python3 - "$daily" "$PA_VAULT" "$PA_FEATURE_NOTE_DIR" "$PA_STATUS_SHIPPED" <<'PYEOF'
import re
import sys
from pathlib import Path

daily_path = Path(sys.argv[1])
vault = Path(sys.argv[2])
feature_dir = sys.argv[3]
shipped_status = sys.argv[4].lower()
text = daily_path.read_text(encoding="utf-8")
lines = text.splitlines()

# Build the regex with the configured feature-note root so links like
# [[PROJECTS/foo/Bar]] (default layout) match — and so do alternate layouts.
link_re = re.compile(
    r"^(\s*)- \[ \] (.*\[\[(" + re.escape(feature_dir) + r"/[^\]|]+)(?:\|[^\]]*)?\]\].*)$"
)


def has_open_subitems(parent_idx: int, parent_indent: int) -> bool:
    for j in range(parent_idx + 1, len(lines)):
        ln = lines[j]
        if not ln.strip():
            continue
        ln_indent = len(ln) - len(ln.lstrip())
        if ln_indent <= parent_indent:
            break
        if re.match(r"^\s+- \[ \]\s+\S", ln):
            return True
    return False


changed = 0
for i, line in enumerate(lines):
    m = link_re.match(line)
    if not m:
        continue
    indent_str, rest, link = m.group(1), m.group(2), m.group(3)
    parent_indent = len(indent_str)
    note = vault / f"{link.strip()}.md"
    if not note.exists():
        continue
    body = note.read_text(encoding="utf-8")
    fm = re.match(r"---\n(.*?)\n---\n", body, re.DOTALL)
    if not fm:
        continue
    status = re.search(r"^status:\s*(\S+)", fm.group(1), re.MULTILINE)
    if not (status and status.group(1).lower() == shipped_status):
        continue
    if has_open_subitems(i, parent_indent):
        continue
    lines[i] = f"{indent_str}- [x] {rest}"
    changed += 1

if changed:
    daily_path.write_text(
        "\n".join(lines) + ("\n" if text.endswith("\n") else ""),
        encoding="utf-8",
    )
print(f"ticked {changed} task(s)")
PYEOF
    ;;

  status)
    json_mode=0
    [[ "${1:-}" == "--json" ]] && json_mode=1
    python3 - "$PA_VAULT" "$PA_FEATURE_NOTE_DIR" "$PA_STATUS_SHIPPED" "$json_mode" <<'PYEOF'
import json
import re
import sys
from pathlib import Path

vault = Path(sys.argv[1])
feature_dir = sys.argv[2]
shipped_status = sys.argv[3].lower()
json_mode = sys.argv[4] == "1"
projects = vault / feature_dir
if not projects.is_dir():
    if json_mode:
        print("[]")
    sys.exit(0)
rows = []
for note in projects.rglob("*.md"):
    try:
        body = note.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        continue
    fm = re.match(r"---\n(.*?)\n---\n", body, re.DOTALL)
    if not fm:
        continue
    tags = re.search(r"^tags:\s*\[(.*?)\]", fm.group(1), re.MULTILINE)
    status = re.search(r"^status:\s*(\S+)", fm.group(1), re.MULTILINE)
    if not status or "feature" not in (tags.group(1) if tags else ""):
        continue
    s = status.group(1).lower()
    if s == shipped_status:
        continue
    repos = []
    if tags:
        repos = [t.strip() for t in tags.group(1).split(",") if t.strip() != "feature"]
    rows.append((note.stem, s, repos))

rows.sort()
if json_mode:
    print(json.dumps([{"title": t, "status": s, "repos": r} for t, s, r in rows]))
else:
    for title, status, repos in rows:
        print(f"{title}  [{status}]  {', '.join(repos)}")
PYEOF
    ;;

  tell)
    pane="${1:-}"
    prompt="${2:-}"
    if [[ -z "$pane" || -z "$prompt" ]]; then
      echo "usage: pa.sh tell <pane|repo> <prompt>" >&2
      exit 2
    fi
    if ! [[ "$pane" =~ ^[A-Za-z0-9_%-]+$ ]]; then
      echo "tell: bad pane/repo identifier" >&2
      exit 2
    fi
    # Resolve repo → pane_id via state file. Numeric input falls through as-is.
    if ! [[ "$pane" =~ ^[0-9]+$ ]]; then
      state="$PA_STATE_DIR/$pane.json"
      if [[ ! -f "$state" ]]; then
        echo "no state for repo '$pane'" >&2
        exit 1
      fi
      pane=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pane_id") or "")' "$state")
      [[ -n "$pane" ]] || { echo "no pane_id in state" >&2; exit 1; }
    fi
    terminal_send "$pane" "$prompt" || { echo "send failed" >&2; exit 1; }
    terminal_enter "$pane" || { echo "enter failed" >&2; exit 1; }
    echo "sent to pane $pane (fire-and-forget)"
    ;;

  ask)
    pane="${1:-}"
    prompt="${2:-}"
    timeout_s="${3:-60}"
    if [[ -z "$pane" || -z "$prompt" ]]; then
      cat >&2 <<'USAGE'
usage: pa.sh ask <pane|repo> <prompt> [<timeout-seconds>]
  for background + harness-tracked notification, invoke via Bash tool with run_in_background=true
  for fire-and-forget (no reply needed), use 'pa.sh tell'
USAGE
      exit 2
    fi
    if ! [[ "$pane" =~ ^[0-9]+$ ]]; then
      state="$PA_STATE_DIR/$pane.json"
      if [[ ! -f "$state" ]]; then
        echo "no state for repo '$pane' and not a numeric pane-id" >&2
        exit 1
      fi
      pane=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pane_id") or "")' "$state")
      [[ -n "$pane" ]] || { echo "no pane_id in state file" >&2; exit 1; }
    fi
    terminal_send "$pane" "$prompt" || { echo "send failed" >&2; exit 1; }
    terminal_enter "$pane" || { echo "enter failed" >&2; exit 1; }
    start=$(date +%s)
    while :; do
      now=$(date +%s)
      if (( now - start >= timeout_s )); then
        echo "[timeout after ${timeout_s}s — pane may still be working]" >&2
        break
      fi
      sleep 1
      idle=$(python3 -m pa.poll_pane_idle "$pane" "$start" 2>/dev/null || true)
      [[ "$idle" == "idle" ]] && break
    done
    python3 -m pa.extract_reply "$pane" "$prompt"
    ;;

  peek)
    repo="" json_mode=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) json_mode=1; shift ;;
        *)      repo="$1"; shift ;;
      esac
    done
    if [[ -z "$repo" ]]; then
      echo "usage: pa.sh peek [--json] <repo>" >&2
      exit 2
    fi
    state="$PA_STATE_DIR/$repo.json"
    if [[ ! -f "$state" ]]; then
      if [[ $json_mode -eq 1 ]]; then
        echo 'null'
      else
        echo "no state for $repo (no project Claude has reported yet)" >&2
      fi
      exit 1
    fi
    if [[ $json_mode -eq 1 ]]; then
      cat "$state"
      exit 0
    fi
    python3 - "$state" <<'PYEOF'
import json
import sys
from datetime import datetime

s = json.loads(open(sys.argv[1]).read())
last = s.get("last_update", "?")
try:
    age = int((datetime.now() - datetime.fromisoformat(last)).total_seconds())
    age_s = f"{age}s ago"
except (ValueError, TypeError):
    age_s = last
print(f"{s.get('repo')}  pane={s.get('pane_id')}  idle={s.get('idle')}  last={age_s}")
print(f"  last_event: {s.get('last_event')}")
if s.get("last_tool"):
    print(f"  last_tool:  {s.get('last_tool')}")
if s.get("last_prompt"):
    print(f"  last_prompt: {s.get('last_prompt')[:120]}")
print(f"  cwd: {s.get('cwd')}")
todos = s.get("todos") or []
if todos:
    marks = {"completed": "x", "in_progress": "~", "pending": " "}
    print(f"  todos ({len(todos)}, updated {s.get('todos_updated','?')}):")
    for t in todos:
        m = marks.get(t.get("status", ""), "?")
        active = t.get("activeForm") or ""
        line = active if t.get("status") == "in_progress" and active else t.get("content", "")
        print(f"    [{m}] {line}")
print("  recent events:")
for e in s.get("events", [])[-6:]:
    print(f"    {e.get('ts','?')}  {e.get('event','?')}  {e.get('tool') or ''}")
PYEOF
    ;;

  peek-all)
    json_mode=0
    [[ "${1:-}" == "--json" ]] && json_mode=1
    if [[ ! -d "$PA_STATE_DIR" ]] || ! find "$PA_STATE_DIR" -maxdepth 1 -name '*.json' -print -quit | grep -q .; then
      if [[ $json_mode -eq 1 ]]; then
        echo "[]"
      else
        echo "no project state recorded yet"
      fi
      exit 0
    fi
    # Live pane ids for liveness-pruning of ghost state files (panes killed
    # hard never fire SessionEnd, so their state JSON lingers forever).
    # Empty string when the backend listing fails -> pruning is skipped so a
    # transient backend outage can't nuke every state file.
    live_panes=$(terminal_list 2>/dev/null | cut -d'|' -f1 | grep -v '^$' | paste -sd, -)
    python3 - "$PA_STATE_DIR" "$json_mode" "$live_panes" <<'PYEOF'
import json
import sys
from datetime import datetime
from pathlib import Path

d = Path(sys.argv[1])
json_mode = sys.argv[2] == "1"
live_raw = sys.argv[3] if len(sys.argv) > 3 else ""
live = {p for p in live_raw.split(",") if p}
states = []
rows = []
for f in sorted(d.glob("*.json")):
    if f.name.startswith(".") or f.name.startswith("vault-session-"):
        continue
    try:
        s = json.loads(f.read_text())
    except (OSError, json.JSONDecodeError):
        continue
    # Prune ghosts: pane recorded, backend listing is real, pane is gone.
    pane = s.get("pane_id")
    if live and pane and pane not in live:
        try:
            f.unlink()
        except OSError:
            pass
        continue
    states.append(s)
    last = s.get("last_update", "")
    try:
        age = int((datetime.now() - datetime.fromisoformat(last)).total_seconds())
        age_s = f"{age}s"
    except (ValueError, TypeError):
        age_s = "?"
    todos = s.get("todos") or []
    todo_summary = ""
    if todos:
        done = sum(1 for t in todos if t.get("status") == "completed")
        in_prog = next(
            (t.get("activeForm") or t.get("content") for t in todos if t.get("status") == "in_progress"),
            "",
        )
        todo_summary = f"{done}/{len(todos)}"
        if in_prog:
            todo_summary += f"  → {in_prog[:40]}"
    rows.append((
        s.get("repo", f.stem),
        "idle" if s.get("idle") else "active",
        age_s,
        s.get("last_event", "?"),
        (s.get("last_tool") or "")[:20],
        todo_summary or (s.get("last_prompt") or "")[:60],
    ))

if json_mode:
    print(json.dumps(states))
    sys.exit(0)
if not rows:
    print("no state files")
else:
    print(f"{'REPO':<32} {'STATE':<7} {'AGE':<6} {'EVENT':<18} {'TOOL':<20} TODOS / PROMPT")
    for r in rows:
        print(f"{r[0]:<32} {r[1]:<7} {r[2]:<6} {r[3]:<18} {r[4]:<20} {r[5]}")
PYEOF
    ;;

  broadcast)
    msg="${1:-}"
    if [[ -z "$msg" ]]; then
      echo "usage: pa.sh broadcast <prompt>" >&2
      exit 2
    fi
    mapfile -t panes < <(python3 - "$PA_STATE_DIR" <<'PYEOF'
import json
import sys
from pathlib import Path

d = Path(sys.argv[1])
for f in d.glob("*.json"):
    if f.name.startswith(".") or f.name.startswith("vault-session-"):
        continue
    try:
        s = json.loads(f.read_text())
    except (OSError, json.JSONDecodeError):
        continue
    pid = s.get("pane_id")
    if pid:
        print(pid)
PYEOF
)
    if [[ ${#panes[@]} -eq 0 ]]; then
      echo "no panes to broadcast to" >&2
      exit 1
    fi
    for pane in "${panes[@]}"; do
      terminal_send "$pane" "$msg" || { echo "send failed on $pane" >&2; continue; }
      terminal_enter "$pane" || echo "enter failed on $pane" >&2
    done
    ;;

  kill)
    repo="${1:-}"
    if [[ -z "$repo" ]]; then
      echo "usage: pa.sh kill <repo>" >&2
      exit 2
    fi
    state="$PA_STATE_DIR/$repo.json"
    if [[ ! -f "$state" ]]; then
      echo "no state for $repo" >&2
      exit 1
    fi
    pane=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pane_id") or "")' "$state")
    if [[ -z "$pane" ]]; then
      echo "no pane_id recorded for $repo" >&2
      exit 1
    fi
    terminal_kill "$pane"
    echo "killed pane $pane ($repo)"
    ;;

  restart)
    repo="${1:-}"
    prompt="${2:-}"
    if [[ -z "$repo" ]]; then
      echo "usage: pa.sh restart <repo> [<initial-prompt>]" >&2
      exit 2
    fi
    if [[ -z "$prompt" ]]; then
      if [[ -z "$PA_SPAWN_PROMPT_TEMPLATE" ]]; then
        echo "restart: no prompt provided and PA_SPAWN_PROMPT_TEMPLATE is empty — pass a prompt explicitly" >&2
        exit 2
      fi
      prompt="${PA_SPAWN_PROMPT_TEMPLATE//\{title\}/$repo}"
      prompt="${prompt//\{intent\}/}"
      prompt="${prompt//\{context\}/}"
    fi
    state="$PA_STATE_DIR/$repo.json"
    if [[ -f "$state" ]]; then
      pane=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pane_id") or "")' "$state")
      [[ -n "$pane" ]] && terminal_kill "$pane" >/dev/null 2>&1 || true
    fi
    project_dir="$PA_PROJECTS_DIR/$repo"
    if [[ ! -d "$project_dir" ]]; then
      echo "restart: $project_dir does not exist" >&2
      exit 1
    fi
    new_pane=$(terminal_spawn "$project_dir" "claude $(printf '%q' "$prompt")") || {
      echo "spawn failed" >&2; exit 1; }
    sleep 1
    terminal_set_title "$new_pane" "$repo" >/dev/null 2>&1 || true
    terminal_activate "$new_pane" >/dev/null 2>&1 || true
    window_raise "$repo" >/dev/null 2>&1 || true
    command -v relayout >/dev/null && relayout >/dev/null 2>&1 || true
    echo "$new_pane"
    ;;

  resume)
    # After accidental terminal close: respawn every project pane whose state
    # file survived (SessionEnd hook deletes state on clean shutdown, so a
    # surviving state file implies an unclean exit). Each respawn uses
    # `claude --continue` so the prior conversation resumes intact.
    if [[ ! -d "$PA_STATE_DIR" ]]; then
      echo "resume: no state dir ($PA_STATE_DIR)" >&2
      exit 0
    fi
    live_panes=$(terminal_list 2>/dev/null | cut -d'|' -f1)
    spawned=0
    skipped=0
    failed=0
    for state in "$PA_STATE_DIR"/*.json; do
      [[ -f "$state" ]] || continue
      base=$(basename "$state" .json)
      case "$base" in
        dashboard|vault-session-*|peon-ping) continue ;;
      esac
      repo=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("repo",""))' "$state")
      cwd=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cwd",""))' "$state")
      old_pane=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pane_id","") or "")' "$state")
      [[ -z "$repo" || -z "$cwd" ]] && continue
      if [[ -n "$old_pane" ]] && echo "$live_panes" | grep -qx "$old_pane"; then
        echo "alive: $repo (pane $old_pane)"
        skipped=$((skipped + 1))
        continue
      fi
      if [[ ! -d "$cwd" ]]; then
        echo "skip: $repo (cwd missing: $cwd)" >&2
        failed=$((failed + 1))
        continue
      fi
      echo "resume: $repo (was pane $old_pane → spawning with claude --continue)"
      new_pane=$(terminal_spawn "$cwd" "claude --continue" 2>/dev/null) || {
        echo "  spawn failed for $repo" >&2
        failed=$((failed + 1))
        continue
      }
      sleep 0.5
      terminal_set_title "$new_pane" "$repo" >/dev/null 2>&1 || true
      terminal_activate "$new_pane" >/dev/null 2>&1 || true
      spawned=$((spawned + 1))
    done
    command -v relayout >/dev/null && relayout >/dev/null 2>&1 || true
    echo "---"
    echo "resumed: $spawned, alive: $skipped, failed: $failed"
    ;;

  snap)
    # Generic dispatcher requires --project explicitly. The obsidian-ce preset can
    # alias the project name in a wrapper if it wants the prior UX.
    project=""
    name=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --project) project="${2:-}"; shift 2 ;;
        --project=*) project="${1#--project=}"; shift ;;
        -*) echo "snap: unknown flag $1" >&2; exit 2 ;;
        *) name="$1"; shift ;;
      esac
    done
    if [[ -z "$project" || -z "$name" ]]; then
      echo "usage: pa.sh snap --project <name> <screen-name>" >&2
      exit 2
    fi
    if [[ "$project" =~ [/.] || "$name" =~ [/.] ]]; then
      echo "snap: --project and <screen-name> must not contain '/' or '.'" >&2
      exit 2
    fi
    out_dir="$PA_VAULT/$PA_FEATURE_NOTE_DIR/$project/manual/screenshots"
    mkdir -p "$out_dir"
    out_path="$out_dir/$name.png"
    if ! command -v adb >/dev/null 2>&1; then
      echo "adb not found in PATH — install Android platform-tools" >&2
      exit 1
    fi
    if ! adb exec-out screencap -p > "$out_path"; then
      echo "screencap failed — is an emulator/device connected? (adb devices)" >&2
      exit 1
    fi
    if [[ ! -s "$out_path" ]]; then
      echo "screencap produced empty file — check adb devices" >&2
      rm -f "$out_path"
      exit 1
    fi
    echo "$out_path"
    ;;

  dashboard)
    interval="${1:-0.5}"
    # Dashboard split UX is wezterm-specific in v0.1 (split-pane + list-clients
    # have no portable equivalent across backends). Other backends: user opens
    # a sibling pane themselves and runs `pa watch`.
    if [[ "$PA_TERMINAL_BACKEND" != "wezterm" ]]; then
      cat >&2 <<EOF
pa: dashboard split is wezterm-only in v0.1 (active backend: $PA_TERMINAL_BACKEND).
    Open a sibling pane manually and run: pa watch $interval
EOF
      exit 0
    fi
    state_file="$PA_STATE_DIR/dashboard.pane"
    existing=""   # pane alive AND watch loop running
    stale=""      # pane alive but watch loop died (bare shell left behind)
    if [[ -f "$state_file" ]]; then
      candidate=$(cat "$state_file" 2>/dev/null || true)
      if [[ -n "$candidate" ]]; then
        # tty_name of the candidate pane ("" if the pane no longer exists)
        tty=$(wezterm cli list --format json 2>/dev/null \
          | python3 -c "import json,sys; m={str(p['pane_id']):(p.get('tty_name') or '') for p in json.load(sys.stdin)}; print(m.get(sys.argv[1],''))" "$candidate" 2>/dev/null)
        if [[ -n "$tty" ]]; then
          # Pane exists, but a surviving bash shell keeps the pane_id alive
          # after the watch loop exits — so the pane title (always "bash") and
          # mere pane existence are not proof the dashboard is running. Confirm
          # the watch loop is actually on the pane's tty before trusting it.
          if ps -t "${tty#/dev/}" -o command= 2>/dev/null | grep -q "pa.sh watch"; then
            existing="$candidate"
          else
            stale="$candidate"
          fi
        fi
      fi
    fi
    if [[ -n "$existing" ]]; then
      terminal_activate "$existing" >/dev/null 2>&1 || true
      echo "$existing (already running)"
      exit 0
    fi
    if [[ -n "$stale" ]]; then
      # Reuse the surviving pane: restart the watch loop in place rather than
      # spawning a second pane and orphaning the dead one.
      terminal_send "$stale" "$PA_BIN/pa.sh watch $interval"$'\n' >/dev/null 2>&1 || true
      sleep 0.3
      # No set_title: dashboard is a split sharing the orchestrator's tab,
      # so a tab title would clobber the main pane's [PA:...] title. The
      # watch loop self-labels its pane via OSC 2.
      terminal_activate "$stale" >/dev/null 2>&1 || true
      echo "$stale (restarted)"
      exit 0
    fi
    anchor="${WEZTERM_PANE:-}"
    if [[ -z "$anchor" ]]; then
      anchor=$(wezterm cli list-clients 2>/dev/null | awk 'NR==2 {print $NF}')
    fi
    if [[ -z "$anchor" ]]; then
      echo "could not determine anchor pane" >&2
      exit 1
    fi
    new_pane=$(wezterm cli split-pane --pane-id "$anchor" --right --percent "${PA_DASH_PERCENT:-35}" -- "$PA_BIN/pa.sh" watch "$interval")
    sleep 0.3
    # No set_title: see the stale-restart branch above. The watch loop
    # self-labels its own pane via OSC 2 without touching the tab title.
    echo "$new_pane" > "$state_file"
    echo "$new_pane"
    ;;

  shutdown)
    today=$(date +%Y-%m-%d)
    saved=0
    killed=0
    # Dashboard pane is identified by its recorded pane id, not its title —
    # the dashboard no longer sets a tab title (it's a split sharing the
    # orchestrator's tab; titling it would clobber the main pane's title).
    dashboard_pid=""
    [[ -f "$PA_STATE_DIR/dashboard.pane" ]] \
      && dashboard_pid=$(cat "$PA_STATE_DIR/dashboard.pane" 2>/dev/null || true)
    # Pull "$pane|$cwd|$title" via the abstraction. Skip the orchestrator
    # pane (PA_MAIN_TITLE) and the dashboard pane. Save buffers for panes
    # whose cwd is inside $PA_PROJECTS_DIR.
    while IFS='|' read -r pid cwd title; do
      [[ -z "$pid" ]] && continue
      [[ -n "$dashboard_pid" && "$pid" == "$dashboard_pid" ]] && continue
      case "$title" in
        *"$PA_MAIN_TITLE"*) continue ;;
      esac
      case "$cwd" in
        "$PA_PROJECTS_DIR"/*) ;;
        *) continue ;;
      esac
      repo="${cwd#"$PA_PROJECTS_DIR"/}"
      repo="${repo%%/*}"
      [[ -z "$repo" ]] && continue
      log_dir="$PA_VAULT/$PA_FEATURE_NOTE_DIR/$repo/session-logs"
      mkdir -p "$log_dir"
      log_path="$log_dir/$today-pane-$pid.log"
      if terminal_capture "$pid" > "$log_path" 2>/dev/null && [[ -s "$log_path" ]]; then
        saved=$((saved + 1))
        echo "saved $repo pane $pid → $log_path"
      else
        rm -f "$log_path"
      fi
      if terminal_kill "$pid" >/dev/null 2>&1; then
        killed=$((killed + 1))
      fi
    done < <(terminal_list)
    pruned=0
    if [[ -d "$PA_STATE_DIR" ]]; then
      for f in "$PA_STATE_DIR"/vault-session-*.json; do
        [[ -e "$f" ]] || continue
        base=$(basename "$f")
        date_part="${base#vault-session-}"
        date_part="${date_part%.json}"
        if [[ "$date_part" != "$today" ]]; then
          rm -f "$f"
          pruned=$((pruned + 1))
        fi
      done
    fi
    # Rotate a bloated events.log — it is append-only and grows unbounded
    # otherwise (2.6 MB observed after ~6 weeks).
    if [[ -f "$PA_STATE_DIR/events.log" ]]; then
      size=$(wc -c < "$PA_STATE_DIR/events.log" | tr -d ' ')
      if (( size > 1048576 )); then
        gzip -c "$PA_STATE_DIR/events.log" > "$PA_STATE_DIR/events.log.1.gz"
        : > "$PA_STATE_DIR/events.log"
        echo "rotated events.log ($((size / 1024)) KB → events.log.1.gz)"
      fi
    fi
    echo "shutdown: saved $saved, killed $killed, pruned $pruned stale session state(s)"
    # Surface plugin-cache drift while it's still recoverable (see `drift`).
    "$PA_BIN/pa.sh" drift || true
    ;;

  drift)
    # Compare the running plugin cache against the marketplace git clone.
    # Hand-edits made in the cache are regenerated away on plugin reinstall;
    # this surfaces them while they're still recoverable. Shutdown calls it,
    # and it can run standalone anytime.
    clone="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/marketplaces/claude-pa"
    cache_root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/claude-pa/claude-pa"
    if [[ ! -d "$clone" || ! -d "$cache_root" ]]; then
      echo "drift: clone or cache dir missing — skipped"
      exit 0
    fi
    cache=$(/bin/ls -td "$cache_root"/*/ 2>/dev/null | head -n 1)
    if [[ -z "$cache" ]]; then
      echo "drift: no cache version dir — skipped"
      exit 0
    fi
    drifted=$(diff -rq "$clone" "$cache" 2>/dev/null \
      | grep -vE '\.git|__pycache__|\.pyc|\.in_use|\.DS_Store' \
      | grep '^Files' || true)
    if [[ -n "$drifted" ]]; then
      echo "⚠ plugin cache drifted from marketplace clone:"
      echo "$drifted" | sed -E "s|^Files ${clone}/(.*) and .*|  \1|"
      echo "→ reconcile + commit in $clone (cache edits die on reinstall)"
      exit 1
    fi
    echo "drift: cache matches clone ✓"
    ;;

  watch)
    interval="${1:-$PA_DASHBOARD_INTERVAL}"
    if ! [[ "$interval" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      interval="$PA_DASHBOARD_INTERVAL"
    fi
    printf '\033[?1049h\033[?25l'
    # OSC 2 sets this pane's own title. wezterm honours program-emitted
    # pane titles; unlike `set-tab-title` it does NOT bleed onto sibling
    # panes sharing the tab (the dashboard is a split off the orchestrator).
    printf '\033]2;PA Dashboard\007'
    trap 'printf "\033[?25h\033[?1049l"; exit 0' INT TERM
    printf '\033[2J\033[H'
    while :; do
      printf '\033[H'
      python3 -m pa.dashboard_render
      printf '\033[J'
      sleep "$interval"
    done
    ;;

  todos)
    exec python3 -m pa.aggregate_todos
    ;;

  pr-status)
    org=""
    if [[ $# -gt 0 ]] && [[ "${1#*:}" == "$1" ]]; then
      org="$1"; shift
    fi
    if [[ $# -eq 0 ]]; then
      echo "usage: pa.sh pr-status [<org>] <repo:branch> [<repo:branch>...]" >&2
      exit 2
    fi
    for spec in "$@"; do
      repo="${spec%%:*}"
      head="${spec##*:}"
      repo_org="$org"
      if [[ -z "$repo_org" ]]; then
        repo_org=$(git -C "$PA_PROJECTS_DIR/$repo" remote get-url origin 2>/dev/null \
          | sed -E 's|.*[:/]([^/]+)/[^/]+(\.git)?$|\1|' | head -1)
      fi
      if [[ -z "$repo_org" ]]; then
        echo "$repo $head NO-ORG - - - -"
        continue
      fi
      out=$(gh pr list --repo "$repo_org/$repo" --head "$head" --state all \
            --json number,state,mergedAt,reviewDecision,mergeStateStatus 2>/dev/null || true)
      if [[ -z "$out" || "$out" == "[]" ]]; then
        echo "$repo $head NONE - - - -"
        continue
      fi
      read -r num state ci review merged < <(printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)[0]
print(d.get("number","-"),
      d.get("state","-"),
      d.get("mergeStateStatus","-") or "-",
      d.get("reviewDecision","-") or "-",
      d.get("mergedAt","-") or "-")
')
      echo "$repo $head $state $num $ci $review $merged"
    done
    ;;

  session-touch)
    today=$(date +%Y-%m-%d)
    state_file="$PA_STATE_DIR/vault-session-$today.json"
    morning_done=""
    agenda_asked=""
    note=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --morning-done) morning_done="1"; shift ;;
        --agenda-asked) agenda_asked="1"; shift ;;
        --note) note="${2:-}"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
      esac
    done
    python3 - "$state_file" "$today" "$morning_done" "$agenda_asked" "$note" <<'PYEOF'
import json
import os
import sys
import time

path, today, md, aa, note = sys.argv[1:6]
state = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as f:
            state = json.load(f)
    except (OSError, json.JSONDecodeError):
        state = {}
state["date"] = today
state["last_ts"] = int(time.time())
if md:
    state["morning_done"] = True
if aa:
    state["agenda_asked"] = True
if note:
    state["note"] = note
with open(path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
print(path)
PYEOF
    ;;

  session-state)
    today=$(date +%Y-%m-%d)
    state_file="$PA_STATE_DIR/vault-session-$today.json"
    if [[ -f "$state_file" ]]; then
      cat "$state_file"
    else
      echo "{}"
    fi
    ;;

  session-resumable)
    today=$(date +%Y-%m-%d)
    state_file="$PA_STATE_DIR/vault-session-$today.json"
    [[ -f "$state_file" ]] || exit 1
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("morning_done") else 1)' "$state_file"
    ;;

  ""|help|-h|--help)
    grep -E "^#" "$0" | sed 's/^# \?//'
    ;;

  *)
    echo "unknown command: $cmd" >&2
    echo "run: pa.sh help" >&2
    exit 2
    ;;
esac
