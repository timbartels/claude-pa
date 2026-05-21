#!/usr/bin/env bash
# scripts/smoke-test.sh — end-to-end claude-pa install simulation.
#
# Runs against a tempdir-isolated XDG + vault so it never touches the
# user's real config. Exercises every artifact a fresh marketplace
# install would create: pa init → pa doctor (--json) → hook fires →
# state file shape → pa uninstall.
#
# Used by .github/workflows/ci.yml and any contributor who wants to
# eyeball that a checkout still installs cleanly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d -t claude-pa-smoke.XXXXXX)
ORIG_SKILL=$(mktemp)
cp "$REPO_ROOT/skills/personal-assistant/SKILL.md" "$ORIG_SKILL"

cleanup() {
  rm -rf "$TMP"
  # pa init mutates the in-tree SKILL.md when substituting placeholders.
  # Restore it so subsequent runs (and `git status`) stay clean.
  cp "$ORIG_SKILL" "$REPO_ROOT/skills/personal-assistant/SKILL.md"
  rm -f "$ORIG_SKILL"
}
trap cleanup EXIT

export XDG_CONFIG_HOME="$TMP/xdg-config"
export XDG_DATA_HOME="$TMP/xdg-data"
mkdir -p "$TMP/vault/_templates" "$TMP/projects/test-repo"
touch "$TMP/vault/_templates/Daily Note.md"

step() { printf '\n=== %s ===\n' "$*"; }
fail() { printf 'smoke-test FAIL: %s\n' "$*" >&2; exit 1; }

step "1. pa init --non-interactive --preset tim"
"$REPO_ROOT/bin/pa" init --non-interactive --preset tim \
  --set "PA_VAULT=$TMP/vault" \
  --set "PA_PROJECTS_DIR=$TMP/projects" \
  --set "PA_TERMINAL_BACKEND=tmux" >/dev/null
[ -f "$XDG_CONFIG_HOME/claude-pa/config.sh" ] || fail "config.sh not written"
[ "$(cat "$XDG_CONFIG_HOME/claude-pa/preset")" = "tim" ] || fail "preset marker wrong"

step "2. pa doctor --json (config now exists)"
doctor_out=$("$REPO_ROOT/bin/pa" doctor --json || true)
echo "$doctor_out" | python3 -m json.tool >/dev/null || fail "doctor --json not parseable"

step "3. simulate hook events (SessionStart, PreToolUse + TodoWrite)"
cd "$TMP/projects/test-repo"
git init -q
echo '{"hook_event_name":"SessionStart"}' | \
  PA_CONFIG="$XDG_CONFIG_HOME/claude-pa/config.sh" PA_DATA_DIR="$XDG_DATA_HOME/claude-pa" \
  "$REPO_ROOT/hooks/scripts/pa-state-update.py"
echo '{"hook_event_name":"PreToolUse","tool_name":"TodoWrite","tool_input":{"todos":[{"content":"smoke","status":"in_progress","activeForm":"Smoking"}]}}' | \
  PA_CONFIG="$XDG_CONFIG_HOME/claude-pa/config.sh" PA_DATA_DIR="$XDG_DATA_HOME/claude-pa" \
  "$REPO_ROOT/hooks/scripts/pa-state-update.py"

state_file="$XDG_DATA_HOME/claude-pa/state/test-repo.json"
[ -f "$state_file" ] || fail "state file not created"
STATE_FILE="$state_file" python3 - <<'PYEOF'
import json, os
s = json.loads(open(os.environ["STATE_FILE"]).read())
assert s["repo"] == "test-repo", s["repo"]
assert s["last_tool"] == "TodoWrite"
assert s["todos"][0]["activeForm"] == "Smoking"
PYEOF

step "4. peek/peek-all read the state via the dispatcher"
PA_CONFIG="$XDG_CONFIG_HOME/claude-pa/config.sh" PA_DATA_DIR="$XDG_DATA_HOME/claude-pa" \
  "$REPO_ROOT/bin/pa.sh" peek test-repo --json | python3 -m json.tool >/dev/null
PA_CONFIG="$XDG_CONFIG_HOME/claude-pa/config.sh" PA_DATA_DIR="$XDG_DATA_HOME/claude-pa" \
  "$REPO_ROOT/bin/pa.sh" peek-all --json | python3 -m json.tool >/dev/null

step "5. SessionEnd unlinks the state file"
echo '{"hook_event_name":"SessionEnd"}' | \
  PA_CONFIG="$XDG_CONFIG_HOME/claude-pa/config.sh" PA_DATA_DIR="$XDG_DATA_HOME/claude-pa" \
  "$REPO_ROOT/hooks/scripts/pa-state-update.py"
[ ! -f "$state_file" ] || fail "SessionEnd did not unlink state file"

step "6. pa uninstall --force"
"$REPO_ROOT/bin/pa" uninstall --force >/dev/null
[ ! -d "$XDG_CONFIG_HOME/claude-pa" ] || fail "config dir not removed"
[ ! -d "$XDG_DATA_HOME/claude-pa" ] || fail "data dir not removed"

printf '\nsmoke-test: ALL GREEN\n'
