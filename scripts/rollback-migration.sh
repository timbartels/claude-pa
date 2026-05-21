#!/usr/bin/env bash
# scripts/rollback-migration.sh
#
# Restore ~/.claude/pa/ + ~/.claude/skills/personal-assistant symlink +
# ~/.local/bin/pa launcher from the most recent pa.bak.<epoch> backup
# created by migrate-from-claude-pa-internal.sh.
#
# Optionally removes the new $XDG_CONFIG_HOME/claude-pa + $XDG_DATA_HOME/
# claude-pa locations so the next Claude session sees only the old
# layout.

set -euo pipefail

OLD="$HOME/.claude/pa"
OLD_SKILL_SYMLINK="$HOME/.claude/skills/personal-assistant"
OLD_LAUNCHER="$HOME/.local/bin/pa"
NEW_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-pa"
NEW_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/claude-pa"

force=0
backup_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force) force=1; shift ;;
    -h|--help)
      cat <<'USAGE'
usage: rollback-migration.sh [--force] [<backup-path>]

Restores ~/.claude/pa/ from a pa.bak.<epoch> backup. If <backup-path>
is omitted, picks the newest pa.bak.* directory under ~/.claude/.

--force skips the confirmation prompt and the "remove new locations"
prompt (it removes them).

Pre-conditions: no claude processes running.
USAGE
      exit 0
      ;;
    -*) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
    *) backup_arg="$1"; shift ;;
  esac
done

# No Claude sessions while we shuffle state.
if pgrep -fl '^/[^[:space:]]*/?claude([[:space:]]|$)' >/dev/null 2>&1; then
  printf 'claude process detected — quit every Claude Code session first\n' >&2
  exit 1
fi

# Pick a backup.
if [[ -n "$backup_arg" ]]; then
  backup="$backup_arg"
else
  backup=$(find "$HOME/.claude" -maxdepth 1 -type d -name "pa.bak.*" 2>/dev/null \
            | sort | tail -1)
fi
if [[ -z "$backup" || ! -d "$backup" ]]; then
  printf 'no backup directory found under %s/.claude/pa.bak.*\n' "$HOME" >&2
  exit 1
fi
printf 'rollback source: %s\n' "$backup"

if [[ $force -eq 0 ]]; then
  printf 'restore %s → %s and remove the new XDG locations? [y/N]: ' "$backup" "$OLD"
  read -r choice
  case "${choice:-n}" in
    y|Y|yes) ;;
    *) printf 'cancelled\n'; exit 0 ;;
  esac
fi

# Remove any partial new install first.
if [[ -d "$OLD" ]]; then
  printf 'removing current %s\n' "$OLD"
  rm -rf "$OLD"
fi

printf 'restoring %s → %s\n' "$backup" "$OLD"
cp -a "$backup" "$OLD"

# Restore the symlink, if the backup recorded a target.
if [[ -f "$OLD/.symlink-target" ]]; then
  target=$(cat "$OLD/.symlink-target")
  if [[ -n "$target" ]]; then
    mkdir -p "$(dirname "$OLD_SKILL_SYMLINK")"
    rm -f "$OLD_SKILL_SYMLINK"
    ln -s "$target" "$OLD_SKILL_SYMLINK"
    printf 'restored symlink %s → %s\n' "$OLD_SKILL_SYMLINK" "$target"
  fi
  rm "$OLD/.symlink-target"
fi

# Restore the launcher (either a real file or a symlink target).
if [[ -f "$OLD/.launcher-target" ]]; then
  target=$(cat "$OLD/.launcher-target")
  mkdir -p "$(dirname "$OLD_LAUNCHER")"
  rm -f "$OLD_LAUNCHER"
  ln -s "$target" "$OLD_LAUNCHER"
  printf 'restored launcher symlink %s → %s\n' "$OLD_LAUNCHER" "$target"
  rm "$OLD/.launcher-target"
elif [[ -f "$OLD/.launcher" ]]; then
  mkdir -p "$(dirname "$OLD_LAUNCHER")"
  cp -a "$OLD/.launcher" "$OLD_LAUNCHER"
  printf 'restored launcher %s\n' "$OLD_LAUNCHER"
  rm "$OLD/.launcher"
fi

# Remove the migration lock if leftover.
rm -rf "$OLD/.migration.lock.d" "$OLD/.migration.lock"

# Optionally remove the new XDG locations.
remove_new=0
if [[ $force -eq 1 ]]; then
  remove_new=1
elif [[ -d "$NEW_CFG" || -d "$NEW_DATA" ]]; then
  printf 'remove new locations %s + %s ? [y/N]: ' "$NEW_CFG" "$NEW_DATA"
  read -r choice
  case "${choice:-n}" in y|Y|yes) remove_new=1 ;; esac
fi
if [[ $remove_new -eq 1 ]]; then
  rm -rf "$NEW_CFG" "$NEW_DATA"
  printf 'removed %s + %s\n' "$NEW_CFG" "$NEW_DATA"
fi

printf '\nrollback complete\n'
printf 'old install at: %s\n' "$OLD"
printf 'next: restart claude. The plugin install (if registered) is harmless\n'
printf '      — just don'\''t enable it until you decide to retry the migration.\n'
