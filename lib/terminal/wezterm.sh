# lib/terminal/wezterm.sh — WezTerm native backend.
#
# Implements the contract in lib/terminal/_interface.sh against WezTerm's
# `wezterm cli` (talks to the running mux server).
# Sourced by the dispatcher when PA_TERMINAL_BACKEND=wezterm.

# Internal: probe wezterm mux server. Returns 0/2.
_pa_wezterm_ensure() {
  command -v wezterm >/dev/null 2>&1 || {
    printf 'wezterm: binary not on PATH\n' >&2; return 2; }
  wezterm cli list --format json >/dev/null 2>&1 || {
    printf 'wezterm: mux server unreachable (no running wezterm GUI)\n' >&2; return 2; }
  return 0
}

# Internal: validate pane_id format (non-negative integer) AND existence.
# Returns 0 if exists, 3 if gone, 2 if backend unreachable.
_pa_wezterm_pane_exists() {
  local pane="$1"
  [[ "$pane" =~ ^[0-9]+$ ]] || { printf 'wezterm: bad pane id: %s\n' "$pane" >&2; return 3; }
  _pa_wezterm_ensure || return 2
  wezterm cli list --format json \
    | jq -e --argjson p "$pane" 'map(.pane_id == $p) | any' >/dev/null \
    || return 3
  return 0
}

terminal_spawn() {
  local cwd="$1" cmd="$2"
  _pa_wezterm_ensure || return 2
  [[ -d "$cwd" ]] || { printf 'wezterm: cwd not a directory: %s\n' "$cwd" >&2; return 1; }
  # Spawn command via shell so multi-word $cmd is handled the same as the
  # existing PA setup. wezterm prints the new pane_id on stdout.
  # shellcheck disable=SC2086  # intentional word-split of cmd
  wezterm cli spawn --new-window --cwd "$cwd" -- /bin/sh -c "$cmd"
}

terminal_list() {
  _pa_wezterm_ensure || return 2
  # cwd in wezterm's JSON is "file://<host>/<path>"; strip to the local path.
  wezterm cli list --format json \
    | jq -r '.[] | "\(.pane_id)|\(.cwd | sub("^file://[^/]*"; ""))|\(.title)"'
}

terminal_send() {
  local pane="$1" text="$2"
  _pa_wezterm_pane_exists "$pane" || return $?
  printf '%s' "$text" | wezterm cli send-text --pane-id "$pane" --no-paste
}

terminal_enter() {
  local pane="$1"
  _pa_wezterm_pane_exists "$pane" || return $?
  # WezTerm TUI submits on CR, not LF.
  printf '\r' | wezterm cli send-text --pane-id "$pane" --no-paste
}

terminal_capture() {
  local pane="$1"
  _pa_wezterm_pane_exists "$pane" || return $?
  wezterm cli get-text --pane-id "$pane"
}

terminal_kill() {
  local pane="$1"
  _pa_wezterm_ensure || return 2
  # Killing a gone pane is success per contract; suppress errors.
  wezterm cli kill-pane --pane-id "$pane" 2>/dev/null || true
  return 0
}

terminal_activate() {
  local pane="$1"
  _pa_wezterm_pane_exists "$pane" || return $?
  wezterm cli activate-pane --pane-id "$pane"
}

terminal_set_title() {
  local pane="$1" tag="$2"
  # Prefix with [PA:...] so window_raise substring-matching is unambiguous
  # against non-claude-pa terminal windows. Idempotent: re-wrapping is fine.
  [[ "$tag" == \[PA:*\] ]] || tag="[PA:${tag}]"
  _pa_wezterm_pane_exists "$pane" || return $?
  # set-tab-title applies to the tab containing the pane; wezterm has no
  # per-pane title separate from the tab.
  wezterm cli set-tab-title --pane-id "$pane" "$tag"
}

terminal_health() {
  _pa_wezterm_ensure || return 2
  wezterm --version
}
