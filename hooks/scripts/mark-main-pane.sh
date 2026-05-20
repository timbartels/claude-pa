#!/usr/bin/env bash
# SessionStart hook: when the session opens inside the configured vault,
# tag the active pane with $PA_MAIN_TITLE so it's visually distinct from
# project panes. Project panes get their repo name via pa.sh spawn/focus.
#
# Skips silently if: not in the vault, no detectable pane, or the active
# terminal backend can't reach its mux server.

set -euo pipefail

_self="$(cd "$(dirname "$0")" && pwd)"
_plugin_root="$(cd "$_self/../.." && pwd)"
PA_LIB="$_plugin_root/lib"

# shellcheck source=../../lib/paths.sh
source "$PA_LIB/paths.sh"

cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

# Only fire when inside the configured vault root.
case "$cwd" in
  "$PA_VAULT"|"$PA_VAULT"/*) ;;
  *) exit 0 ;;
esac

# Detect the active pane id per backend. The state-update hook uses the
# same mapping; keep them in sync.
case "$PA_TERMINAL_BACKEND" in
  wezterm) pane="${WEZTERM_PANE:-}" ;;
  tmux)    pane="${TMUX_PANE:-}" ;;
  iterm2)  pane="${ITERM_SESSION_ID:-}" ;;
  kitty)   pane="${KITTY_WINDOW_ID:-}" ;;
  *)       pane="" ;;
esac

if [[ -z "$pane" ]]; then
  exit 0
fi

# shellcheck source=/dev/null
source "$PA_LIB/terminal/${PA_TERMINAL_BACKEND}.sh"

terminal_set_title "$pane" "$PA_MAIN_TITLE" >/dev/null 2>&1 || true
