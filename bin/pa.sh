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
#   pa.sh dashboard [interval]          # idempotently spawn (or focus) the live dashboard (wezterm only)
#   pa.sh watch [interval]              # live dashboard in current pane
#   pa.sh todos                         # flatten TodoWrite across all panes, prioritized
#   pa.sh broadcast <prompt>            # submit <prompt> to every project pane
#   pa.sh pr-status [<org>] <repo:branch>...  # one line per spec
#   pa.sh kill <repo>                   # kill the pane for <repo>
#   pa.sh restart <repo> [<prompt>]     # kill + respawn pane; default prompt from $PA_SPAWN_PROMPT_TEMPLATE
#   pa.sh session-touch [--morning-done] [--agenda-asked] [--note <text>]
#   pa.sh session-state                 # print today's vault-session state JSON (or {})
#   pa.sh session-resumable             # exit 0 if morning already done today
#   pa.sh help                          # this header

set -euo pipefail

# Self-locate. $(dirname "$0") instead of $CLAUDE_PLUGIN_ROOT because bin/-PATH
# invocations from Claude Code don't guarantee the env var (only hook/MCP do).
PA_BIN="$(cd "$(dirname "$0")" && pwd)"
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
    python3 - "$PA_VAULT" "$PA_FEATURE_NOTE_DIR" "$PA_STATUS_SHIPPED" <<'PYEOF'
import re
import sys
from pathlib import Path

vault = Path(sys.argv[1])
feature_dir = sys.argv[2]
shipped_status = sys.argv[3].lower()
projects = vault / feature_dir
if not projects.is_dir():
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
    rows.append((note.stem, s, ", ".join(repos)))

for title, status, repos in sorted(rows):
    print(f"{title}  [{status}]  {repos}")
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
    repo="${1:-}"
    if [[ -z "$repo" ]]; then
      echo "usage: pa.sh peek <repo>" >&2
      exit 2
    fi
    state="$PA_STATE_DIR/$repo.json"
    if [[ ! -f "$state" ]]; then
      echo "no state for $repo (no project Claude has reported yet)" >&2
      exit 1
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
    if [[ ! -d "$PA_STATE_DIR" ]] || ! find "$PA_STATE_DIR" -maxdepth 1 -name '*.json' -print -quit | grep -q .; then
      echo "no project state recorded yet"
      exit 0
    fi
    python3 - "$PA_STATE_DIR" <<'PYEOF'
import json
import sys
from datetime import datetime
from pathlib import Path

d = Path(sys.argv[1])
rows = []
for f in sorted(d.glob("*.json")):
    if f.name.startswith(".") or f.name.startswith("vault-session-"):
        continue
    try:
        s = json.loads(f.read_text())
    except (OSError, json.JSONDecodeError):
        continue
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
    echo "$new_pane"
    ;;

  snap)
    # Generic dispatcher requires --project explicitly. The tim preset can
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
    existing=""
    if [[ -f "$state_file" ]]; then
      candidate=$(cat "$state_file" 2>/dev/null || true)
      if [[ -n "$candidate" ]] && wezterm cli list --format json 2>/dev/null \
        | python3 -c "import json,sys; ids={str(p['pane_id']) for p in json.load(sys.stdin)}; sys.exit(0 if sys.argv[1] in ids else 1)" "$candidate" 2>/dev/null; then
        existing="$candidate"
      fi
    fi
    if [[ -n "$existing" ]]; then
      terminal_activate "$existing" >/dev/null 2>&1 || true
      echo "$existing (already running)"
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
    new_pane=$(wezterm cli split-pane --pane-id "$anchor" --right --percent 35 -- "$PA_BIN/pa.sh" watch "$interval")
    sleep 0.3
    terminal_set_title "$new_pane" "[PA:Dashboard]" >/dev/null 2>&1 || true
    echo "$new_pane" > "$state_file"
    echo "$new_pane"
    ;;

  shutdown)
    today=$(date +%Y-%m-%d)
    saved=0
    killed=0
    # Pull "$pane|$cwd|$title" via the abstraction. Skip the orchestrator
    # pane (PA_MAIN_TITLE) and the dashboard pane. Save buffers for panes
    # whose cwd is inside $PA_PROJECTS_DIR.
    while IFS='|' read -r pid cwd title; do
      [[ -z "$pid" ]] && continue
      case "$title" in
        *"$PA_MAIN_TITLE"*) continue ;;
        *"PA:Dashboard"*) continue ;;
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
    echo "shutdown: saved $saved, killed $killed, pruned $pruned stale session state(s)"
    ;;

  watch)
    interval="${1:-$PA_DASHBOARD_INTERVAL}"
    if ! [[ "$interval" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      interval="$PA_DASHBOARD_INTERVAL"
    fi
    printf '\033[?1049h\033[?25l'
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
