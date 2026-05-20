# lib/window-raise/macos.sh — bring a macOS window to the foreground.
#
# Uses AppleScript via osascript. Walks System Events for a window whose
# title contains <title-substring> and performs AXRaise on it.
#
# <title-substring> is passed as an osascript argv (`on run argv`), NOT
# interpolated into the script body. This blocks AppleScript injection
# via crafted repo names like `name"; do shell script "..."`.
#
# Implements the contract in lib/window-raise/_interface.sh.

window_raise() {
  local needle="${1:-}"
  [[ -n "$needle" ]] || { printf 'window_raise: empty title substring\n' >&2; return 1; }
  command -v osascript >/dev/null 2>&1 \
    || { printf 'window_raise: osascript missing (non-macOS?)\n' >&2; return 2; }

  local verdict
  verdict=$(osascript - "$needle" <<'APPLE' 2>/dev/null
on run argv
  set needle to item 1 of argv
  tell application "System Events"
    repeat with p in (every process whose visible is true)
      repeat with w in windows of p
        try
          if name of w contains needle then
            set frontmost of p to true
            perform action "AXRaise" of w
            return "raised"
          end if
        end try
      end repeat
    end repeat
  end tell
  return "no match"
end run
APPLE
)
  [[ "$verdict" == "raised" ]] && return 0
  return 1
}
