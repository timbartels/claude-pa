# lib/terminal/iterm2.sh — iTerm2 native backend (macOS only).
#
# Thin shell wrapper over lib/terminal/iterm2_helper.py — the helper does
# every iTerm2 operation against the typed `iterm2` Python lib. Earlier
# versions used AppleScript heredocs for spawn/kill/activate/set_title;
# those were vulnerable to AppleScript injection via interpolated paths
# and have been removed.
#
# Prerequisites (checked by pa doctor):
#   - macOS
#   - iTerm2 >= 3.5 with "Enable Python API" turned on
#   - python3 -m pip install --user iterm2
#
# Pane id format: iTerm2 session UUID string.

_PA_ITERM2_HELPER="${PA_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}/terminal/iterm2_helper.py"

# Internal: probe basics (macOS + python3 + helper + iterm2 module).
# Heavy work — callers should rely on existence implicit in helper exit codes
# rather than pre-probing.
_pa_iterm2_ensure() {
  [[ "$(uname)" == "Darwin" ]] || { printf 'iterm2: macOS only\n' >&2; return 2; }
  command -v python3 >/dev/null 2>&1 \
    || { printf 'iterm2: python3 not found\n' >&2; return 2; }
  [[ -f "$_PA_ITERM2_HELPER" ]] \
    || { printf 'iterm2: helper missing at %s\n' "$_PA_ITERM2_HELPER" >&2; return 2; }
  return 0
}

# All terminal_* ops delegate to the Python helper. The helper enforces
# the contract exit codes (0/1/2/3) so the shell layer just passes through.

terminal_spawn() {
  local cwd="$1" cmd="$2"
  _pa_iterm2_ensure || return 2
  [[ -d "$cwd" ]] || { printf 'iterm2: cwd not a directory: %s\n' "$cwd" >&2; return 1; }
  python3 "$_PA_ITERM2_HELPER" spawn "$cwd" "$cmd"
}

terminal_list() {
  _pa_iterm2_ensure || return 2
  python3 "$_PA_ITERM2_HELPER" list
}

terminal_send() {
  local pane="$1" text="$2"
  _pa_iterm2_ensure || return 2
  python3 "$_PA_ITERM2_HELPER" send "$pane" "$text"
}

terminal_enter() {
  local pane="$1"
  _pa_iterm2_ensure || return 2
  python3 "$_PA_ITERM2_HELPER" enter "$pane"
}

terminal_capture() {
  local pane="$1"
  _pa_iterm2_ensure || return 2
  python3 "$_PA_ITERM2_HELPER" capture "$pane"
}

terminal_kill() {
  local pane="$1"
  _pa_iterm2_ensure || return 2
  python3 "$_PA_ITERM2_HELPER" kill "$pane"
}

terminal_activate() {
  local pane="$1"
  _pa_iterm2_ensure || return 2
  python3 "$_PA_ITERM2_HELPER" activate "$pane"
}

terminal_set_title() {
  local pane="$1" tag="$2"
  _pa_iterm2_ensure || return 2
  python3 "$_PA_ITERM2_HELPER" set_title "$pane" "$tag"
}

terminal_health() {
  _pa_iterm2_ensure || return 2
  python3 "$_PA_ITERM2_HELPER" health
}
