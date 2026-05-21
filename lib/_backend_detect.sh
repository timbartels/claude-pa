# shellcheck shell=bash
# lib/_backend_detect.sh — single source of truth for terminal backend detection.
#
# Sourced by lib/paths.sh (post-config runtime resolution when the user
# wrote PA_TERMINAL_BACKEND=auto), by lib/wizard.sh's pa_doctor health
# check, and by the `pa init` default-mode auto-detect path.
#
# The function emits one of four literal backend names — never the
# verbatim env-var content. Mapping presence-of-var → fixed string keeps
# attacker-controlled env values from leaking into a sourced config file.
#
# Usage:
#   source "$_pa_lib_dir/_backend_detect.sh"
#   backend=$(_pa_resolve_backend)
#
# Pin order: tmux wins when we are inside it (because everything else
# delegates anyway under tmux), then the named terminal env vars in a
# fixed precedence (wezterm → iterm2 → kitty), then tmux as the
# universal fallback so consumers always get a non-empty value.

_pa_resolve_backend() {
  if [[ -n "${TMUX:-}" ]]; then
    printf '%s\n' tmux
    return 0
  fi
  if [[ "${TERM_PROGRAM:-}" == "WezTerm" ]]; then
    printf '%s\n' wezterm
    return 0
  fi
  if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]]; then
    printf '%s\n' iterm2
    return 0
  fi
  if [[ -n "${KITTY_WINDOW_ID:-}" ]]; then
    printf '%s\n' kitty
    return 0
  fi
  printf '%s\n' tmux
}
