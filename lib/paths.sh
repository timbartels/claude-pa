# lib/paths.sh — claude-pa config + path resolution for bash callers.
#
# Sourced by bin/pa.sh and any shell hook script that needs config values.
# Idempotent: sourcing twice in the same shell is a no-op past the first
# successful load.
#
# Inputs (env, optional):
#   XDG_CONFIG_HOME    overrides ~/.config root
#   XDG_DATA_HOME      overrides ~/.local/share root
#   PA_CONFIG          overrides the resolved config path entirely (dev shell)
#   PA_DATA_DIR        overrides the resolved data dir entirely (dev shell)
#
# Outputs (exported on success):
#   PA_CONFIG          absolute path to the active config file
#   PA_DATA_DIR        $XDG_DATA_HOME/claude-pa (or override)
#   PA_STATE_DIR       $PA_DATA_DIR/state
#   PA_CACHE_DIR       $PA_DATA_DIR/cache
#   PA_LOGS_DIR        $PA_DATA_DIR/logs
#   PA_VAULT, PA_PROJECTS_DIR, PA_TERMINAL_BACKEND, …  (from sourced config)
#
# Exits the caller with code 1 + actionable message if config is missing or
# required vars are unset. Callers do `source lib/paths.sh` — there is no
# function to call.

# Guard against re-sourcing in the same shell.
if [[ "${_PA_PATHS_LOADED:-0}" == "1" ]]; then
  return 0
fi

# Resolve config + data roots. Env overrides win for dev-shell scenarios
# (see scripts/dev-shell.sh and the `pa dev on` toggle).
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_DATA_HOME:=$HOME/.local/share}"
: "${PA_CONFIG:=$XDG_CONFIG_HOME/claude-pa/config.sh}"
: "${PA_DATA_DIR:=$XDG_DATA_HOME/claude-pa}"

PA_STATE_DIR="$PA_DATA_DIR/state"
PA_CACHE_DIR="$PA_DATA_DIR/cache"
PA_LOGS_DIR="$PA_DATA_DIR/logs"

# Config file must exist. Without it we cannot proceed — there's no useful
# fallback (we'd guess vault path, terminal backend, …).
if [[ ! -f "$PA_CONFIG" ]]; then
  printf 'pa: config missing at %s — run `pa init` first.\n' "$PA_CONFIG" >&2
  exit 1
fi

# Source config. The file is bash by design (only ever written by the
# wizard or the user; preset files use a stricter format — see
# CONTRIBUTING.md). Failures here surface as bash errors with line numbers.
# shellcheck disable=SC1090
source "$PA_CONFIG"

# Required vars must be set and point at extant directories.
_pa_require_dir() {
  local name="$1" value="${2:-}"
  if [[ -z "$value" ]]; then
    printf 'pa: %s is unset in %s — run `pa init` to repair.\n' "$name" "$PA_CONFIG" >&2
    exit 1
  fi
  if [[ ! -d "$value" ]]; then
    printf 'pa: %s=%s does not exist or is not a directory.\n' "$name" "$value" >&2
    exit 1
  fi
}

_pa_require_dir PA_VAULT "${PA_VAULT:-}"
_pa_require_dir PA_PROJECTS_DIR "${PA_PROJECTS_DIR:-}"

# Auto-detect terminal backend when the user left it on `auto`. Detection
# logic lives in lib/_backend_detect.sh so the wizard + doctor + this
# runtime path share one implementation.
if [[ "${PA_TERMINAL_BACKEND:-auto}" == "auto" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/_backend_detect.sh"
  PA_TERMINAL_BACKEND=$(_pa_resolve_backend)
fi

case "$PA_TERMINAL_BACKEND" in
  wezterm|kitty|iterm2|tmux) ;;
  *)
    printf 'pa: PA_TERMINAL_BACKEND=%s is not one of {wezterm,kitty,iterm2,tmux}.\n' "$PA_TERMINAL_BACKEND" >&2
    exit 1
    ;;
esac

# Apply config defaults for optional vars so consumers can read them under
# `set -u` without guarding every access.
: "${PA_MAIN_TITLE:=MAIN}"
: "${PA_DAILY_DIR:=Daily}"
: "${PA_DAILY_TEMPLATE_PATH:=_templates/Daily Note.md}"
: "${PA_WORK_SECTION:=Work}"
: "${PA_PERSONAL_SECTION:=Personal}"
: "${PA_FEATURE_NOTE_DIR:=PROJECTS}"
: "${PA_STATUS_VALUES:=brainstorming,planned,in-progress,shipped}"
: "${PA_STATUS_SHIPPED:=shipped}"
: "${PA_SPAWN_PROMPT_TEMPLATE:=}"
: "${PA_DASHBOARD_INTERVAL:=2}"
: "${PA_WORK_ORGS:=}"
: "${PA_DEBUG:=0}"

# Create runtime dirs lazily; 700 because state may contain prompt text +
# daily-note excerpts (see Phase 7 privacy hardening).
mkdir -p -- "$PA_STATE_DIR" "$PA_CACHE_DIR" "$PA_LOGS_DIR"
chmod 700 "$PA_DATA_DIR" "$PA_STATE_DIR" "$PA_CACHE_DIR" "$PA_LOGS_DIR" 2>/dev/null || true

export PA_CONFIG PA_DATA_DIR PA_STATE_DIR PA_CACHE_DIR PA_LOGS_DIR
export PA_VAULT PA_PROJECTS_DIR PA_TERMINAL_BACKEND PA_MAIN_TITLE
export PA_DAILY_DIR PA_DAILY_TEMPLATE_PATH PA_WORK_SECTION PA_PERSONAL_SECTION
export PA_FEATURE_NOTE_DIR PA_STATUS_VALUES PA_STATUS_SHIPPED
export PA_SPAWN_PROMPT_TEMPLATE PA_DASHBOARD_INTERVAL PA_WORK_ORGS PA_DEBUG

_PA_PATHS_LOADED=1
export _PA_PATHS_LOADED
