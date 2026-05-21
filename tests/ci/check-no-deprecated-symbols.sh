#!/usr/bin/env bash
# check-no-deprecated-symbols.sh — CI guard against reintroducing
# wizard symbols that were removed in Phase 7 of the pa init refactor.
#
# The wizard used to keep three drifting stores of optional-key defaults
# (lib/wizard.sh _PA_DEFAULTS_*, lib/pa/paths.py _DEFAULTS, lib/paths.sh
# `:=` fallbacks). Phase 7 consolidated wizard-time defaults into
# presets/default/config.env. _PA_DEFAULTS_* and _pa_default_for were
# deleted; this script ensures they don't sneak back in.
#
# Exits 0 if clean, 1 (with file:line hits printed) if any deprecated
# symbol is found in lib/, bin/, hooks/, or commands/.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

DEPRECATED=(
  '_pa_default_for'
  '_PA_DEFAULTS_'
)

found=0
for sym in "${DEPRECATED[@]}"; do
  # Use --include to limit the search to source dirs we care about. Skip
  # tests/ (snapshot tests may legitimately reference the deprecated
  # names in comments) and docs/ (the plan and brainstorm do too).
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    if [[ $found -eq 0 ]]; then
      printf 'deprecated symbols reintroduced:\n' >&2
      found=1
    fi
    printf '  %s\n' "$hit" >&2
  done < <(
    grep -rn -- "$sym" \
      "$REPO_ROOT/lib" "$REPO_ROOT/bin" "$REPO_ROOT/hooks" "$REPO_ROOT/commands" \
      2>/dev/null \
      | grep -v "$(basename "$0")" || true
  )
done

if [[ $found -eq 1 ]]; then
  printf '\nthese symbols were removed in Phase 7 of the pa init refactor.\n' >&2
  printf 'use _pa_preset_value_for "default" / load_preset() instead.\n' >&2
  exit 1
fi
printf 'no deprecated symbols found.\n'
