# lib/terminal/tmux.sh — universal fallback backend.
#
# Implements the contract in lib/terminal/_interface.sh against tmux 3.0+.
# Sourced (not executed) by the dispatcher when PA_TERMINAL_BACKEND=tmux.

# Internal: assert tmux server is running; spawn one if not. Returns 0/2.
_pa_tmux_ensure() {
  if tmux info >/dev/null 2>&1; then
    return 0
  fi
  if command -v tmux >/dev/null 2>&1; then
    tmux new-session -d -s pa-bootstrap 2>/dev/null || true
    tmux info >/dev/null 2>&1 && return 0
  fi
  printf 'tmux: backend unavailable (binary missing or server unreachable)\n' >&2
  return 2
}

# Internal: validate that pane_id matches tmux's "%N" format AND exists.
# Returns 0 if pane exists, 3 if gone, 2 if backend unreachable.
_pa_tmux_pane_exists() {
  local pane="$1"
  [[ "$pane" =~ ^%[0-9]+$ ]] || { printf 'tmux: bad pane id: %s\n' "$pane" >&2; return 3; }
  _pa_tmux_ensure || return 2
  tmux list-panes -a -F '#{pane_id}' | grep -qx -- "$pane" || return 3
  return 0
}

terminal_spawn() {
  local cwd="$1" cmd="$2"
  _pa_tmux_ensure || return 2
  [[ -d "$cwd" ]] || { printf 'tmux: cwd not a directory: %s\n' "$cwd" >&2; return 1; }
  tmux new-window -d -P -F '#{pane_id}' -c "$cwd" -- "$cmd"
}

terminal_list() {
  _pa_tmux_ensure || return 2
  tmux list-panes -a -F '#{pane_id}|#{pane_current_path}|#{window_name}' 2>/dev/null || true
}

terminal_send() {
  local pane="$1" text="$2"
  _pa_tmux_pane_exists "$pane" || return $?
  tmux send-keys -t "$pane" -l -- "$text"
}

terminal_enter() {
  local pane="$1"
  _pa_tmux_pane_exists "$pane" || return $?
  tmux send-keys -t "$pane" Enter
}

terminal_capture() {
  local pane="$1"
  _pa_tmux_pane_exists "$pane" || return $?
  tmux capture-pane -p -t "$pane"
}

terminal_kill() {
  local pane="$1"
  _pa_tmux_ensure || return 2
  # Killing a non-existent pane is success per the contract.
  tmux kill-pane -t "$pane" 2>/dev/null || true
  return 0
}

terminal_activate() {
  local pane="$1"
  _pa_tmux_pane_exists "$pane" || return $?
  # select-pane + select-window targets the pane within its window.
  # switch-client only works if a client is attached; ignore failure.
  tmux select-pane -t "$pane" && tmux select-window -t "$pane"
  tmux switch-client -t "$pane" 2>/dev/null || true
  return 0
}

terminal_set_title() {
  local pane="$1" tag="$2"
  [[ "$tag" == \[PA:*\] ]] || tag="[PA:${tag}]"
  _pa_tmux_pane_exists "$pane" || return $?
  # Rename the window containing the pane; tmux has no per-pane title.
  tmux rename-window -t "$pane" -- "$tag"
}

terminal_health() {
  _pa_tmux_ensure || return 2
  tmux -V
}
