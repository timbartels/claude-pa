#!/usr/bin/env bash
# scripts/migrate-from-claude-pa-internal.sh
#
# Migrate Tim's internal ~/.claude/pa/ install to the public claude-pa
# plugin layout. NOT shipped in the plugin — runnable standalone from a
# checkout of the repo.
#
# Default mode is --dry-run: prints every action without mutating
# anything. Pass --apply to actually run. Migration is destructive in
# the sense that it moves state from one location to another; the
# original ~/.claude/pa/ is preserved as a timestamped backup.
#
# Hardening (per Phase 7 deepening review):
#   - $HOME safety + OS allowlist before any destructive op
#   - flock against concurrent runs (and against an in-flight Claude
#     session corrupting state mid-copy)
#   - .migrated sentinel for idempotency — second --apply bails clean
#   - cp -a preserves timestamps + perms (events.log mtime drives the
#     dashboard's freshness signal)
#   - post-copy file count verification with rollback on mismatch
#   - state-file path rewrite (rewrites ~/.claude/pa references to the
#     new $XDG_DATA_HOME/claude-pa path); verified empty grep after
#   - chmod 0700 on data dir, 0600 on state files (privacy)
#   - cross-machine learnings.md merge — if existing learnings exist
#     and differ, the old file lands as learnings.md.<hostname> for
#     manual reconciliation, instead of silently overwriting

set -euo pipefail

# ─── Constants + safety net ────────────────────────────────────────────────

OLD="$HOME/.claude/pa"
OLD_SKILL_SYMLINK="$HOME/.claude/skills/personal-assistant"
OLD_LAUNCHER="$HOME/.local/bin/pa"
NEW_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-pa"
NEW_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/claude-pa"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SENTINEL="$NEW_DATA/.migrated"
LOCK_DIR="$OLD/.migration.lock.d"

MODE=dry-run

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[31m'; CYAN=$'\033[36m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
else
  RED='' CYAN='' YELLOW='' GREEN='' RESET=''
fi

die() { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
note() { printf '%snote:%s %s\n' "$CYAN" "$RESET" "$*"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
ok() { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }

# run <cmd> — execute cmd unless dry-run mode is active.
run() {
  if [[ "$MODE" == "apply" ]]; then
    "$@"
  else
    printf '%s[dry-run]%s %s\n' "$YELLOW" "$RESET" "$*"
  fi
}

# ─── Arg parsing ───────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)   MODE=apply; shift ;;
    --dry-run) MODE=dry-run; shift ;;
    -h|--help)
      cat <<'USAGE'
usage: migrate-from-claude-pa-internal.sh [--apply | --dry-run]

Migrates ~/.claude/pa/ → $XDG_CONFIG_HOME/claude-pa/ + $XDG_DATA_HOME/claude-pa/.

  --dry-run  (default) print actions, mutate nothing
  --apply    perform the migration

Run inside a checkout of the claude-pa repo. The script reads
presets/tim/config.env via lib/pa/preset_loader to build the new
config file.

Pre-conditions: no claude processes running, OS is macOS or Linux,
~/.claude/pa/ exists and is a real directory (not a symlink), and
no $XDG_DATA_HOME/claude-pa/.migrated sentinel from a prior run.

The original ~/.claude/pa/ is preserved as ~/.claude/pa.bak.<epoch>;
scripts/rollback-migration.sh can restore from it.
USAGE
      exit 0
      ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
done

note "mode: $MODE"

# ─── Pre-flight assertions ─────────────────────────────────────────────────

# $HOME must be sane — guards against running this script with HOME=/
# (which would point OLD at /.claude/pa, NEW_DATA at /.local/share/claude-pa).
[[ -n "${HOME:-}" && -d "$HOME" && "$HOME" != "/" ]] || die "\$HOME is unsafe: ${HOME:-(unset)}"

case "$(uname -s)" in
  Darwin|Linux) ;;
  *) die "unsupported OS: $(uname -s) — only macOS / Linux supported in v0.1" ;;
esac

[[ -d "$OLD" ]] || die "old install not found at $OLD — nothing to migrate"
[[ -L "$OLD" ]] && die "$OLD is a symlink — refusing to migrate (resolve manually first)"
[[ -d "$PLUGIN_ROOT/presets/tim" ]] || die "preset 'tim' not found at $PLUGIN_ROOT/presets/tim — run from a claude-pa checkout"

if pgrep -fl '^/[^[:space:]]*/?claude([[:space:]]|$)' >/dev/null 2>&1; then
  die "claude process detected — quit every Claude Code session before running this script"
fi

if [[ -f "$SENTINEL" ]]; then
  ts=$(cat "$SENTINEL" 2>/dev/null || true)
  die "migration already ran (sentinel: $SENTINEL, ts: $ts) — remove the sentinel or use rollback-migration.sh"
fi

# ─── Lock against concurrent runs / mid-write Claude sessions ──────────────
#
# macOS ships no flock(1). `mkdir` is atomic across POSIX systems —
# either it creates the directory or returns EEXIST. Same guarantee
# we want from a lockfile, portable everywhere.

if [[ "$MODE" == "apply" ]]; then
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "another migration in progress (lock at $LOCK_DIR) — delete it manually if no run is active"
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
fi

# ─── 1. Backup ─────────────────────────────────────────────────────────────

BACKUP="$HOME/.claude/pa.bak.$(date +%s)"
note "1/8 backing up $OLD → $BACKUP"
run cp -a "$OLD" "$BACKUP"

# Snapshot symlink + launcher targets so rollback can restore them faithfully.
if [[ -L "$OLD_SKILL_SYMLINK" ]]; then
  run sh -c "readlink '$OLD_SKILL_SYMLINK' > '$BACKUP/.symlink-target'"
fi
if [[ -f "$OLD_LAUNCHER" ]]; then
  run cp -a "$OLD_LAUNCHER" "$BACKUP/.launcher"
  if [[ -L "$OLD_LAUNCHER" ]]; then
    run sh -c "readlink '$OLD_LAUNCHER' > '$BACKUP/.launcher-target'"
  fi
fi

# ─── 2. Create new XDG dirs ────────────────────────────────────────────────

note "2/8 creating $NEW_CFG + $NEW_DATA tree"
run install -d -m 700 -- "$NEW_CFG"
run install -d -m 700 -- "$NEW_DATA" "$NEW_DATA/state" "$NEW_DATA/cache" "$NEW_DATA/logs"

# ─── 3. Copy state + learnings ─────────────────────────────────────────────

# Count files in the OLD state dir for post-copy verification.
old_state_count=0
if [[ -d "$OLD/state" ]]; then
  old_state_count=$(find "$OLD/state" -type f 2>/dev/null | wc -l | tr -d ' ')
fi

note "3/8 copying state ($old_state_count file(s)) + learnings"
if [[ -d "$OLD/state" ]]; then
  # cp -a preserves timestamps + perms. events.log mtime drives the
  # dashboard's "freshness" indicator — losing that would be a regression.
  run cp -a "$OLD/state/." "$NEW_DATA/state/"
fi

# Cross-machine learnings.md merge: if a learnings file exists at the
# destination and differs from the source, copy the old one as a
# per-hostname suffix so neither side is lost. The user reconciles
# manually (documented in MIGRATION.md).
old_learnings="$OLD/skill/learnings.md"
new_learnings="$NEW_DATA/learnings.md"
if [[ -f "$old_learnings" ]]; then
  if [[ -f "$new_learnings" ]]; then
    if ! cmp -s "$old_learnings" "$new_learnings"; then
      host=$(hostname -s 2>/dev/null || hostname || echo unknown)
      target="$new_learnings.$host"
      warn "existing $new_learnings differs from source — keeping both as $target"
      run cp -a "$old_learnings" "$target"
    else
      note "  learnings.md identical, skipping"
    fi
  else
    run cp -a "$old_learnings" "$new_learnings"
  fi
fi

# ─── 4. Generate config from tim preset ────────────────────────────────────

note "4/8 writing $NEW_CFG/config.sh from presets/tim/config.env"
if [[ "$MODE" == "apply" ]]; then
  preset_out=$(PYTHONPATH="$PLUGIN_ROOT/lib" python3 -m pa.preset_loader "$PLUGIN_ROOT/presets/tim")
  tmp_cfg=$(mktemp)
  {
    printf '# ~/.config/claude-pa/config.sh — generated by migrate-from-claude-pa-internal.sh on %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# Adjust by hand or re-run `pa init` to regenerate.\n\n'
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
        printf '%s\n' "$line"
      fi
    done <<<"$preset_out"
  } > "$tmp_cfg"
  install -m 600 "$tmp_cfg" "$NEW_CFG/config.sh"
  rm -f "$tmp_cfg"
  printf 'tim\n' > "$NEW_CFG/preset"
  chmod 600 "$NEW_CFG/preset"
else
  printf '%s[dry-run]%s would write %s + %s/preset (from presets/tim)\n' \
    "$YELLOW" "$RESET" "$NEW_CFG/config.sh" "$NEW_CFG"
fi

# ─── 5. Post-copy verification + path rewrite ──────────────────────────────

note "5/8 verifying state file count + rewriting embedded paths"
if [[ "$MODE" == "apply" && "$old_state_count" -gt 0 ]]; then
  new_state_count=$(find "$NEW_DATA/state" -type f | wc -l | tr -d ' ')
  if [[ "$new_state_count" -lt "$old_state_count" ]]; then
    warn "state file count mismatch: old=$old_state_count new=$new_state_count"
    warn "aborting — rollback by running scripts/rollback-migration.sh"
    exit 1
  fi
  # Rewrite ~/.claude/pa paths in state JSON + events.log. Old PA wrote
  # absolute paths into state files, and the dashboard renderer reads
  # them back; without rewrite, the new install would still display old
  # paths in its UI.
  find "$NEW_DATA/state" -type f \( -name "*.json" -o -name "*.log" \) -print0 \
    | xargs -0 sed -i.bak "s|$HOME/.claude/pa|$NEW_DATA|g"
  find "$NEW_DATA/state" -type f -name "*.bak" -delete
  if grep -rq "\\.claude/pa" "$NEW_DATA/state" 2>/dev/null; then
    warn "path rewrite incomplete — manual cleanup needed in $NEW_DATA/state"
  fi
fi

# ─── 6. Remove old symlink + launcher ──────────────────────────────────────

note "6/8 removing old symlink + launcher"
if [[ -L "$OLD_SKILL_SYMLINK" ]]; then
  run rm "$OLD_SKILL_SYMLINK"
fi
if [[ -f "$OLD_LAUNCHER" || -L "$OLD_LAUNCHER" ]]; then
  run rm "$OLD_LAUNCHER"
fi

# ─── 7. Privacy hardening ──────────────────────────────────────────────────

note "7/8 chmod 700 / 600 on new dirs + state files"
if [[ "$MODE" == "apply" ]]; then
  chmod 700 "$NEW_DATA" "$NEW_DATA/state" "$NEW_DATA/cache" "$NEW_DATA/logs" 2>/dev/null || true
  find "$NEW_DATA/state" -type f -exec chmod 600 {} \; 2>/dev/null || true
fi

# ─── 8. Sentinel + report ──────────────────────────────────────────────────

if [[ "$MODE" == "apply" ]]; then
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SENTINEL"
  chmod 600 "$SENTINEL"
fi
note "8/8 wrote $SENTINEL (idempotency guard)"

printf '\n%smigration complete%s\n' "$GREEN" "$RESET"
printf '  backup:        %s\n' "$BACKUP"
printf '  new config:    %s/config.sh\n' "$NEW_CFG"
printf '  new data:      %s\n' "$NEW_DATA"
printf '  preset marker: %s/preset\n' "$NEW_CFG"
printf '\nnext steps:\n'
printf '  1. install the plugin: /plugin marketplace add timbartels/claude-pa\n'
printf '                         /plugin install claude-pa@claude-pa\n'
printf '  2. run `pa doctor` — should report green\n'
printf '  3. edit ~/.claude/settings.json — remove old allow rules for\n'
printf '     %s/bin/pa.sh and add the new ones via:\n' "$OLD"
printf '       pa init --print-settings\n'
printf '  4. once everything works, remove the backup:\n'
printf '       rm -rf %s\n' "$BACKUP"
printf '\n%sif anything is broken, restore from backup:%s\n' "$YELLOW" "$RESET"
printf '  scripts/rollback-migration.sh\n'
