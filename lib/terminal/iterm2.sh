# lib/terminal/iterm2.sh — iTerm2 native backend (macOS only).
#
# Hybrid: AppleScript for spawn/activate/kill/set_title (no Python dep),
# Python iterm2 lib for list/send/capture (richer API).
# Sourced when PA_TERMINAL_BACKEND=iterm2.
#
# Prerequisites (checked by pa doctor):
#   - macOS
#   - iTerm2 >= 3.5 with "Enable Python API" turned on (Settings -> General -> Magic)
#   - python3 -m pip install --user iterm2
#
# Pane id format: UUID string (iTerm2 session_id).

_PA_ITERM2_HELPER="${PA_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/terminal/iterm2-helper.py"

# Internal: probe basics. Returns 0/2.
_pa_iterm2_ensure() {
  [[ "$(uname)" == "Darwin" ]] || { printf 'iterm2: macOS only\n' >&2; return 2; }
  command -v osascript >/dev/null 2>&1 \
    || { printf 'iterm2: osascript not found\n' >&2; return 2; }
  osascript -e 'tell application "System Events" to (name of processes) contains "iTerm2"' \
    2>/dev/null | grep -q true \
    || { printf 'iterm2: iTerm2 not running\n' >&2; return 2; }
  return 0
}

# Internal: ensure Python helper is usable (for list/send/capture).
_pa_iterm2_ensure_python() {
  _pa_iterm2_ensure || return 2
  command -v python3 >/dev/null 2>&1 \
    || { printf 'iterm2: python3 not found\n' >&2; return 2; }
  [[ -f "$_PA_ITERM2_HELPER" ]] \
    || { printf 'iterm2: helper missing at %s\n' "$_PA_ITERM2_HELPER" >&2; return 2; }
  python3 -c 'import iterm2' 2>/dev/null \
    || { printf 'iterm2: Python lib missing — run: python3 -m pip install --user iterm2\n' >&2; return 2; }
  return 0
}

_pa_iterm2_session_exists() {
  local pane="$1"
  [[ "$pane" =~ ^[0-9a-fA-F-]+$ ]] \
    || { printf 'iterm2: bad session id: %s\n' "$pane" >&2; return 3; }
  _pa_iterm2_ensure_python || return 2
  python3 "$_PA_ITERM2_HELPER" list 2>/dev/null \
    | cut -d'|' -f1 | grep -qx -- "$pane" || return 3
  return 0
}

terminal_spawn() {
  local cwd="$1" cmd="$2"
  _pa_iterm2_ensure || return 2
  [[ -d "$cwd" ]] || { printf 'iterm2: cwd not a directory: %s\n' "$cwd" >&2; return 1; }
  # AppleScript: create a new window running a shell that cd's then execs the cmd.
  # Capture the returned session id.
  local script
  script=$(cat <<APPLE
tell application "iTerm"
  set newWindow to (create window with default profile command "/bin/sh -c 'cd \"$cwd\" && $cmd'")
  return id of current session of newWindow
end tell
APPLE
)
  osascript -e "$script"
}

terminal_list() {
  _pa_iterm2_ensure_python || return 2
  python3 "$_PA_ITERM2_HELPER" list
}

terminal_send() {
  local pane="$1" text="$2"
  _pa_iterm2_session_exists "$pane" || return $?
  python3 "$_PA_ITERM2_HELPER" send "$pane" "$text"
}

terminal_enter() {
  local pane="$1"
  _pa_iterm2_session_exists "$pane" || return $?
  python3 "$_PA_ITERM2_HELPER" send "$pane" $'\n'
}

terminal_capture() {
  local pane="$1"
  _pa_iterm2_session_exists "$pane" || return $?
  python3 "$_PA_ITERM2_HELPER" capture "$pane"
}

terminal_kill() {
  local pane="$1"
  _pa_iterm2_ensure || return 2
  # AppleScript can close by session id; suppress errors (gone pane is success).
  osascript <<APPLE 2>/dev/null || true
tell application "iTerm"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if id of s is "$pane" then
          close s
          return
        end if
      end repeat
    end repeat
  end repeat
end tell
APPLE
  return 0
}

terminal_activate() {
  local pane="$1"
  _pa_iterm2_ensure || return 2
  osascript <<APPLE
tell application "iTerm"
  activate
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if id of s is "$pane" then
          select t
          tell t to select s
          return
        end if
      end repeat
    end repeat
  end repeat
  error "session not found"
end tell
APPLE
}

terminal_set_title() {
  local pane="$1" tag="$2"
  _pa_iterm2_ensure || return 2
  osascript <<APPLE
tell application "iTerm"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if id of s is "$pane" then
          set name of s to "$tag"
          return
        end if
      end repeat
    end repeat
  end repeat
end tell
APPLE
}

terminal_health() {
  _pa_iterm2_ensure || return 2
  osascript -e 'tell application "iTerm" to version'
}
