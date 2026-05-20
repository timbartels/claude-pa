# lib/window-raise/linux.sh — bring a Linux window to the foreground.
#
# Tries `wmctrl` first (X11; matches title substring with -a), falls back to
# `xdotool search --name | windowactivate`. Wayland has no portable
# implementation; this file errors with exit 2 and documents per-compositor
# alternatives in comments.
#
# Implements the contract in lib/window-raise/_interface.sh.

window_raise() {
  local needle="${1:-}"
  [[ -n "$needle" ]] || { printf 'window_raise: empty title substring\n' >&2; return 1; }

  # Wayland: no portable cross-compositor raise. Document compositor-specific
  # paths in the user's docs/TROUBLESHOOTING.md (Hyprland: hyprctl dispatch
  # focuswindow; Sway: swaymsg [con_id=...] focus; KDE/KWin: kdotool or kwin
  # script). v0.1 returns "unsupported" instead of pretending to work.
  if [[ -n "${WAYLAND_DISPLAY:-}" ]] && [[ -z "${DISPLAY:-}" ]]; then
    printf 'window_raise: Wayland without X11 — install xwayland or a compositor-specific helper (see docs/TROUBLESHOOTING.md)\n' >&2
    return 2
  fi

  # X11 path 1: wmctrl
  if command -v wmctrl >/dev/null 2>&1; then
    if wmctrl -l | grep -F -- "$needle" >/dev/null; then
      wmctrl -a "$needle" && return 0
    fi
    return 1
  fi

  # X11 path 2: xdotool
  if command -v xdotool >/dev/null 2>&1; then
    local win
    win=$(xdotool search --name "$needle" 2>/dev/null | head -1)
    [[ -n "$win" ]] || return 1
    xdotool windowactivate "$win" && return 0
    return 1
  fi

  printf 'window_raise: install wmctrl or xdotool for window-raise on X11\n' >&2
  return 2
}
