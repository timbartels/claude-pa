#!/usr/bin/env bash
# validate-preset.sh — preset structural + lint check.
#
# Usage:
#   tests/ci/validate-preset.sh <preset-dir>
#   tests/ci/validate-preset.sh --all      # validate every preset under presets/
#
# Exits 0 on success, 1 on the first failure (prints the specific violation
# to stderr). CI runs this against every preset/ directory on PRs that
# touch presets/. The strict loader (lib/pa/preset_loader.py) is the
# primary security mitigation; this script is defence-in-depth and
# catches structural / documentation gaps before the maintainer reviews.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail() {
  printf 'preset validation failed: %s\n' "$1" >&2
  exit 1
}

validate_one() {
  local dir="$1" name
  name=$(basename "$dir")

  [[ -d "$dir" ]] || fail "$dir: not a directory"

  for required in config.env SKILL.md daily-template.md README.md; do
    [[ -f "$dir/$required" ]] || fail "$dir/$required: missing required file"
  done

  # Loader must parse config.env without rejecting anything.
  if ! PYTHONPATH="$REPO_ROOT/lib" python3 -m pa.preset_loader "$dir" >/dev/null; then
    fail "$dir/config.env: loader rejected this file (see error above)"
  fi

  # README must declare target audience + dependencies. Heuristic: keyword
  # presence. Cheap but catches the empty-README case.
  if ! grep -qi 'target audience\|audience\|built for' "$dir/README.md"; then
    fail "$dir/README.md: must declare target audience (look for a 'Target audience' or 'Built for' section)"
  fi
  if ! grep -qiE 'dependenc|required\b|deps' "$dir/README.md"; then
    fail "$dir/README.md: must list required / optional dependencies"
  fi

  # SKILL.md: refuse fenced shell blocks that contain network / eval
  # commands. The strict loader can't protect against this — SKILL.md is
  # markdown read by Claude, so embedded instructions matter. Flag the
  # obvious supply-chain shapes; the maintainer reviews everything else.
  #
  # BSD awk lacks \b — use plain alternation against tokens that already
  # contain a leading non-word character ("| bash", "| sh") or are unlikely
  # to appear inside an identifier (curl/wget/eval/source as words).
  if awk '
    /^```bash/  { in_block = 1; next }
    /^```sh/    { in_block = 1; next }
    /^```/      { in_block = 0; next }
    in_block && /curl|wget|eval|source|\| *bash|\| *sh/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$dir/SKILL.md"; then
    fail "$dir/SKILL.md: embedded shell block contains curl/wget/eval/source/pipe-to-shell — supply-chain risk, refuse merge"
  fi

  printf '%s: OK\n' "$dir"
}

main() {
  if [[ $# -lt 1 ]]; then
    echo "usage: $0 <preset-dir> | --all" >&2
    exit 2
  fi

  if [[ "$1" == "--all" ]]; then
    local any=0
    shopt -s nullglob
    for preset in "$REPO_ROOT"/presets/*/; do
      [[ -d "$preset" ]] || continue
      [[ "$(basename "$preset")" == "LICENSE" ]] && continue
      validate_one "${preset%/}"
      any=1
    done
    shopt -u nullglob
    if [[ $any -eq 0 ]]; then
      echo "no presets found under $REPO_ROOT/presets/" >&2
      exit 1
    fi
  else
    validate_one "$1"
  fi
}

main "$@"
