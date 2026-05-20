# lib/window-raise/macos.sh — bring a macOS window to the foreground.
#
# Uses AppleScript via osascript. Walks the System Events window list for
# every running process, finds the first window whose title contains
# <title-substring>, and performs AXRaise on it.
#
# Implements the contract in lib/window-raise/_interface.sh.

window_raise() {
  local needle="${1:-}"
  [[ -n "$needle" ]] || { printf 'window_raise: empty title substring\n' >&2; return 1; }
  command -v osascript >/dev/null 2>&1 \
    || { printf 'window_raise: osascript missing (non-macOS?)\n' >&2; return 2; }

  # AppleScript: scan every process's windows; raise the first match.
  # Returns "raised" on success, "no match" otherwise. Capture stdout to
  # distinguish (osascript exits 0 either way unless the script errors).
  local verdict
  verdict=$(osascript <<APPLE 2>/dev/null
tell application "System Events"
  repeat with p in (every process whose visible is true)
    repeat with w in windows of p
      try
        if name of w contains "$needle" then
          set frontmost of p to true
          perform action "AXRaise" of w
          return "raised"
        end if
      end try
    end repeat
  end repeat
  return "no match"
end tell
APPLE
)
  [[ "$verdict" == "raised" ]] && return 0
  return 1
}
