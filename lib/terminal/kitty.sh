# lib/terminal/kitty.sh — Kitty native backend.
#
# Implements the contract in lib/terminal/_interface.sh against Kitty's
# remote-control protocol (`kitten @` aliases legacy `kitty @`).
#
# Prerequisite: kitty.conf must enable remote control. Recommended config:
#
#   allow_remote_control yes
#   listen_on unix:/tmp/kitty-{kitty_pid}
#
# Without `listen_on`, remote control only works from inside a kitty window
# (i.e., $KITTY_LISTEN_ON is set by kitty for child processes).
# `pa doctor` checks this.
#
# Pane id format: numeric kitty window-id.

# Internal: pick the modern kitten binary, fall back to legacy `kitty @`.
_pa_kitty_cmd() {
  if command -v kitten >/dev/null 2>&1; then
    kitten @ "$@"
  elif command -v kitty >/dev/null 2>&1; then
    kitty @ "$@"
  else
    printf 'kitty: binary not on PATH\n' >&2
    return 2
  fi
}

# Internal: ensure remote control reachable. Returns 0/2.
_pa_kitty_ensure() {
  if ! command -v kitten >/dev/null 2>&1 && ! command -v kitty >/dev/null 2>&1; then
    printf 'kitty: binary not on PATH\n' >&2
    return 2
  fi
  if _pa_kitty_cmd ls >/dev/null 2>&1; then
    return 0
  fi
  printf 'kitty: remote control unreachable (set allow_remote_control + listen_on in kitty.conf, and start kitty)\n' >&2
  return 2
}

# Internal: validate pane_id format AND existence.
_pa_kitty_pane_exists() {
  local pane="$1"
  [[ "$pane" =~ ^[0-9]+$ ]] || { printf 'kitty: bad pane id: %s\n' "$pane" >&2; return 3; }
  _pa_kitty_ensure || return 2
  _pa_kitty_cmd ls \
    | jq -e --argjson p "$pane" '[.[].tabs[].windows[].id] | any(. == $p)' >/dev/null \
    || return 3
  return 0
}

terminal_spawn() {
  local cwd="$1" cmd="$2"
  _pa_kitty_ensure || return 2
  [[ -d "$cwd" ]] || { printf 'kitty: cwd not a directory: %s\n' "$cwd" >&2; return 1; }
  # --type=os-window opens a new OS window; --cwd sets working dir.
  # `launch` returns the numeric window-id on stdout when not detached.
  # shellcheck disable=SC2086  # word-split cmd intentional
  _pa_kitty_cmd launch --type=os-window --cwd="$cwd" -- /bin/sh -c "$cmd"
}

terminal_list() {
  _pa_kitty_ensure || return 2
  _pa_kitty_cmd ls \
    | jq -r '.[].tabs[].windows[] | "\(.id)|\(.cwd)|\(.title)"'
}

terminal_send() {
  local pane="$1" text="$2"
  _pa_kitty_pane_exists "$pane" || return $?
  printf '%s' "$text" | _pa_kitty_cmd send-text --match "id:$pane" --stdin
}

terminal_enter() {
  local pane="$1"
  _pa_kitty_pane_exists "$pane" || return $?
  # send-key takes named keys (Return = Enter).
  _pa_kitty_cmd send-key --match "id:$pane" Return
}

terminal_capture() {
  local pane="$1"
  _pa_kitty_pane_exists "$pane" || return $?
  _pa_kitty_cmd get-text --match "id:$pane"
}

terminal_kill() {
  local pane="$1"
  _pa_kitty_ensure || return 2
  _pa_kitty_cmd close-window --match "id:$pane" 2>/dev/null || true
  return 0
}

terminal_activate() {
  local pane="$1"
  _pa_kitty_pane_exists "$pane" || return $?
  _pa_kitty_cmd focus-window --match "id:$pane"
}

terminal_set_title() {
  local pane="$1" tag="$2"
  _pa_kitty_pane_exists "$pane" || return $?
  # Tab title is the user-visible tag for window groups; window title
  # changes flicker. Set both for safety.
  _pa_kitty_cmd set-tab-title --match "id:$pane" "$tag" 2>/dev/null || true
  _pa_kitty_cmd set-window-title --match "id:$pane" "$tag"
}

terminal_health() {
  _pa_kitty_ensure || return 2
  if command -v kitten >/dev/null 2>&1; then
    kitten --version
  else
    kitty --version
  fi
}
