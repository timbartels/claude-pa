# lib/wizard.sh — implementations of `pa init`, `pa doctor`, `pa uninstall`.
#
# Sourced by bin/pa when one of those subcommands is invoked. Not sourced
# for the bare-invocation / `pa dev …` paths.
#
# Inherits from bin/pa: die / note / warn / _pa_resolve_safe /
# _pa_validate_plugin_dir / RED / YELLOW / CYAN / RESET / CONFIG_DIR /
# DATA_DIR. Does not depend on lib/paths.sh (which requires $PA_CONFIG to
# already exist — exactly what `pa init` is creating). Does load
# lib/_backend_detect.sh because that helper is pre-config-safe (reads
# env only) and is the single source of truth for backend detection,
# shared with paths.sh's runtime resolution and pa_doctor's health check.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_backend_detect.sh"

# ─── Shared constants ──────────────────────────────────────────────────────

_PA_REQUIRED_KEYS=(PA_VAULT PA_PROJECTS_DIR)
_PA_OPTIONAL_KEYS=(
  PA_TERMINAL_BACKEND
  PA_MAIN_TITLE
  PA_DAILY_DIR
  PA_DAILY_TEMPLATE_PATH
  PA_WORK_SECTION
  PA_PERSONAL_SECTION
  PA_FEATURE_NOTE_DIR
  PA_STATUS_VALUES
  PA_STATUS_SHIPPED
  PA_SPAWN_PROMPT_TEMPLATE
  PA_DASHBOARD_INTERVAL
  PA_DEBUG
)
_PA_ALL_KEYS=("${_PA_REQUIRED_KEYS[@]}" "${_PA_OPTIONAL_KEYS[@]}")

# ─── Helpers ───────────────────────────────────────────────────────────────

# Vault-org defaults previously lived here as an in-bash constant
# table with a lookup helper. Both removed in Phase 7 of the pa init
# refactor — presets/default/config.env is now the single source of
# truth, consumed via _pa_load_preset/_pa_preset_value_for. The CI
# guard at tests/ci/check-no-deprecated-symbols.sh fails the build if
# the deprecated symbol names are reintroduced.

# Reject values that could only be malicious in the user's config (which
# IS sourced as bash). Mirrors the strict preset parser's intent without
# the regex contortion since user config is single-author.
_pa_safe_value() {
  local value="$1"
  case "$value" in
    *'$('*|*'`'*|*'${'*) return 1 ;;
  esac
  return 0
}

# Validate a path-typed input: not empty, no shell metachars, expand $HOME.
_pa_validate_path() {
  local input="$1" name="$2"
  if [[ -z "$input" ]]; then
    printf '%s cannot be empty\n' "$name" >&2
    return 1
  fi
  if ! _pa_safe_value "$input"; then
    printf '%s contains forbidden shell metacharacter\n' "$name" >&2
    return 1
  fi
  printf '%s' "${input/#~/$HOME}"
}

# Locate the plugin root that this launcher belongs to. Same logic as the
# bare-launch path in bin/pa — follow symlinks and walk up from bin/.
_pa_plugin_root_for_wizard() {
  if [[ -n "${PA_PLUGIN_ROOT_OVERRIDE:-}" ]]; then
    printf '%s' "$PA_PLUGIN_ROOT_OVERRIDE"
    return 0
  fi
  if [[ -f "$DEV_MARKER" ]]; then
    cat "$DEV_MARKER"
    return 0
  fi
  local script="$0" target
  while [[ -L "$script" ]]; do
    target=$(readlink "$script")
    if [[ "$target" = /* ]]; then
      script="$target"
    else
      script="$(cd "$(dirname "$script")" && pwd)/$target"
    fi
  done
  (cd "$(dirname "$script")/.." && pwd)
}

# Render an allow-rules JSON snippet for ~/.claude/settings.json based on
# the configured terminal backend. Only the rules PA actually needs.
_pa_emit_settings_snippet() {
  local backend="$1" data_dir="$2" vault="$3"
  local pa_sh_path="$4"

  local backend_rule=""
  case "$backend" in
    wezterm) backend_rule='"Bash(wezterm:*)"' ;;
    kitty)   backend_rule='"Bash(kitten:*)", "Bash(kitty:*)"' ;;
    tmux)    backend_rule='"Bash(tmux:*)"' ;;
    iterm2)  backend_rule='"Bash(osascript:*)"' ;;
  esac

  cat <<JSON
{
  "permissions": {
    "allow": [
      "Bash($pa_sh_path:*)",
      ${backend_rule:+$backend_rule,}
      "Read($data_dir/**)",
      "Read($vault/**)",
      "Write($data_dir/**)",
      "Edit($vault/**)"
    ]
  }
}
JSON
}

# ─── pa init ───────────────────────────────────────────────────────────────

# Resolve the homedir the auto-detect scanners walk. PA_INIT_HOMEDIR_OVERRIDE
# lets bats redirect the scan into a temp directory without touching $HOME.
_pa_init_homedir() {
  printf '%s' "${PA_INIT_HOMEDIR_OVERRIDE:-$HOME}"
}

# Scan the conventional Obsidian vault locations for any subdir containing
# a `.obsidian/` marker. Prints zero, one, or many absolute paths (one per
# line). Symlinks resolved via realpath so a single iCloud vault doesn't
# appear twice when the user also symlinks it under ~/Obsidian. Every
# candidate flows through _pa_resolve_safe (inherited from bin/pa) so a
# rogue symlink escaping $HOME is rejected.
#
# Honours PA_INIT_NO_TCC_PROMPT=1 to short-circuit the iCloud scan in CI
# (where macOS TCC prompts would block the test runner).
_pa_detect_vault() {
  local home roots root candidate canonical
  home=$(_pa_init_homedir)
  roots=()

  # iCloud first — most common Obsidian setup on macOS. Skip if the env
  # short-circuit is set (CI) or the directory simply doesn't exist
  # (non-macOS, or no Obsidian iCloud sync configured).
  local icloud="$home/Library/Mobile Documents/iCloud~md~obsidian/Documents"
  if [[ -d "$icloud" && "${PA_INIT_NO_TCC_PROMPT:-0}" != "1" ]]; then
    note "scanning iCloud for Obsidian vaults — macOS may prompt for permission"
    roots+=("$icloud")
  fi

  [[ -d "$home/Documents" ]] && roots+=("$home/Documents")
  [[ -d "$home/Obsidian" ]] && roots+=("$home/Obsidian")

  declare -A seen=()
  for root in "${roots[@]+"${roots[@]}"}"; do
    # /bin/ls because the user may have shell-aliased `ls` and the alias
    # has been observed to fail on iCloud-backed paths.
    while IFS= read -r candidate; do
      [[ -d "$root/$candidate/.obsidian" ]] || continue
      canonical=$(_pa_resolve_safe "$root/$candidate" 2>/dev/null) || continue
      # Dedup by canonical path — iCloud + ~/Obsidian symlinks to the same
      # vault are the common case.
      [[ -n "${seen[$canonical]:-}" ]] && continue
      seen[$canonical]=1
      printf '%s\n' "$canonical"
    done < <(/bin/ls -1 "$root" 2>/dev/null || true)
  done
}

# Walk a short fixed list of conventional projects-dir locations, return
# the first one that exists. Output passes through _pa_resolve_safe so a
# symlinked candidate escaping $HOME is rejected.
_pa_detect_projects_dir() {
  local home candidate canonical
  home=$(_pa_init_homedir)
  for candidate in Projects projects code dev src; do
    if [[ -d "$home/$candidate" ]]; then
      canonical=$(_pa_resolve_safe "$home/$candidate" 2>/dev/null) || continue
      printf '%s\n' "$canonical"
      return 0
    fi
  done
  return 1
}

# Thin wrapper around lib/_backend_detect.sh:_pa_resolve_backend. Lives
# here so callers in this file (pa_init, pa_doctor) can reference a
# wizard-local name and the actual logic stays in one place.
_pa_detect_backend() {
  _pa_resolve_backend
}

# Render the confirm block — one labeled assignment per line in the fixed
# source taxonomy (--set / env / preset:NAME / shell / default /
# auto-detect). User answers y / n only — no per-field edit DSL.
#
# Reads (globally): _pa_val_<KEY> resolved values and _pa_src_<KEY>
# source-label strings, both written by the key-walk loop in pa_init.
# Returns: 0 on accept, 1 on reject. Other exit codes propagate from
# `read` failures (EOF → die).
_pa_confirm_block() {
  local key var src_var
  printf '\n%sdetected configuration:%s\n' "$CYAN" "$RESET" >&2
  for key in "${_PA_ALL_KEYS[@]}"; do
    var="_pa_val_$key"
    src_var="_pa_src_$key"
    printf '  %-30s = %-40s  %s\n' \
      "$key" \
      "\"${!var:-}\"" \
      "${!src_var:-(default)}" >&2
  done
  printf '\n' >&2

  printf 'write config? [Y/n]: ' >&2
  local choice
  if ! IFS= read -r choice; then
    die "pa init: stdin closed" 1
  fi
  case "${choice:-y}" in
    y|Y|yes) return 0 ;;
    *)
      printf '\n%sno config written.%s re-run with:\n' "$YELLOW" "$RESET" >&2
      printf '  pa init --wizard               # walk every field\n' >&2
      printf '  pa init --set PA_VAULT=...     # override single field\n' >&2
      return 1
      ;;
  esac
}

# Acquire a flock on $CONFIG_DIR/.init.lock so two pa init runs can't
# race on the same config file. Falls back to a mkdir-as-lock when
# /usr/bin/flock isn't available (macOS without coreutils). The lock is
# released by the EXIT trap set up in pa_init.
_pa_acquire_init_lock() {
  install -d -m 700 -- "$CONFIG_DIR"
  local lock="$CONFIG_DIR/.init.lock"
  if command -v flock >/dev/null 2>&1; then
    exec {_PA_INIT_LOCK_FD}>"$lock"
    if ! flock -n "$_PA_INIT_LOCK_FD"; then
      warn "another pa init in progress (holding $lock)"
      return 1
    fi
    return 0
  fi
  # mkdir-as-lock fallback. Atomic on POSIX filesystems.
  if ! mkdir "$lock" 2>/dev/null; then
    warn "another pa init in progress (holding $lock)"
    return 1
  fi
  _PA_INIT_LOCK_DIR="$lock"
  return 0
}

_pa_release_init_lock() {
  if [[ -n "${_PA_INIT_LOCK_FD:-}" ]]; then
    eval "exec ${_PA_INIT_LOCK_FD}>&-"
    unset _PA_INIT_LOCK_FD
  fi
  if [[ -n "${_PA_INIT_LOCK_DIR:-}" && -d "$_PA_INIT_LOCK_DIR" ]]; then
    rmdir "$_PA_INIT_LOCK_DIR" 2>/dev/null || true
    unset _PA_INIT_LOCK_DIR
  fi
}

# Write the resolved key-value pairs to $CONFIG_DIR/config.sh atomically.
# Same-directory mktemp so the final mv is a rename (atomic on POSIX);
# chmod 600 before mv so the file is never world-readable. Caller is
# expected to have set the EXIT trap that calls _pa_init_cleanup.
_pa_atomic_write_config() {
  local config_file="$CONFIG_DIR/config.sh"
  install -d -m 700 -- "$CONFIG_DIR"
  install -d -m 700 -- "$DATA_DIR" "$DATA_DIR/state" "$DATA_DIR/cache" "$DATA_DIR/logs"

  _PA_INIT_TMPCFG=$(mktemp "$CONFIG_DIR/.config.sh.XXXXXX")
  {
    printf '# ~/.config/claude-pa/config.sh — generated by `pa init` on %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# Edit by hand or re-run `pa init` to regenerate.\n\n'
    local key var raw escaped
    for key in "${_PA_ALL_KEYS[@]}"; do
      var="_pa_val_$key"
      raw="${!var:-}"
      escaped="${raw//\\/\\\\}"
      escaped="${escaped//\"/\\\"}"
      printf '%s="%s"\n' "$key" "$escaped"
    done
  } > "$_PA_INIT_TMPCFG"
  chmod 600 "$_PA_INIT_TMPCFG"
  mv -- "$_PA_INIT_TMPCFG" "$config_file"
  unset _PA_INIT_TMPCFG
}

# Cleanup hook for the EXIT/INT/TERM trap set by pa_init. Removes any
# in-flight tmpfile and releases the init lock.
_pa_init_cleanup() {
  if [[ -n "${_PA_INIT_TMPCFG:-}" && -f "${_PA_INIT_TMPCFG}" ]]; then
    rm -f -- "$_PA_INIT_TMPCFG"
  fi
  _pa_release_init_lock
}

# Post-write hook that offers to symlink ~/.local/bin/pa at the plugin's
# bin/pa. The launcher is the user's entry point; the marketplace install
# drops it into the plugin cache only, so a fresh install otherwise leaves
# `pa` unreachable from the user's $PATH.
#
# Args:
#   $1  plugin_root         absolute path to the plugin install
#   $2  force_symlink       1 to repoint an existing symlink, 0 to refuse
#   $3  non_interactive     1 skips the offer (no prompts, print a note)
#
# Returns 0 always — the offer is best-effort; failures are warnings, not
# fatal. Refuses to clobber a regular file regardless of $force_symlink
# (rename-and-replace is too destructive for a flag).
_pa_offer_launcher_symlink() {
  local plugin_root="$1" force="$2" non_interactive="$3"
  local plugin_pa="$plugin_root/bin/pa"
  local target="$HOME/.local/bin/pa"

  # State 1: pa already on $PATH and resolves to us — no-op.
  local current
  if current=$(command -v pa 2>/dev/null); then
    local current_real plugin_real
    current_real=$(_pa_resolve_safe "$current" 2>/dev/null) || current_real="$current"
    plugin_real=$(_pa_resolve_safe "$plugin_pa" 2>/dev/null) || plugin_real="$plugin_pa"
    if [[ "$current_real" == "$plugin_real" ]]; then
      return 0
    fi
    # State 2: pa resolves elsewhere — warn but never shadow.
    warn "\`pa\` already on \$PATH at $current (not the plugin's bin/pa)"
    warn "leaving alone — remove or repoint manually if you want this install to win"
    return 0
  fi

  # State 3: pa not on $PATH at all. Offer to create the symlink.

  # Nix detection: if ~/.local/bin is already a symlink into /nix/store,
  # the directory is home-manager-managed. Don't fight that — print a
  # note and return.
  if [[ -L "$HOME/.local/bin" ]]; then
    local link_target
    link_target=$(readlink "$HOME/.local/bin")
    if [[ "$link_target" == /nix/store/* ]]; then
      note "~/.local/bin is Nix-managed — install pa via home-manager instead"
      return 0
    fi
  fi
  if [[ -L "$target" ]]; then
    local t
    t=$(readlink "$target" 2>/dev/null)
    if [[ "$t" == /nix/store/* ]]; then
      note "~/.local/bin/pa is Nix-managed — install via home-manager instead"
      return 0
    fi
  fi

  # If target exists as a regular file: refuse to clobber. Files at that
  # path are the user's intentional tool; print a manual command.
  if [[ -e "$target" && ! -L "$target" ]]; then
    warn "~/.local/bin/pa is a regular file — refusing to clobber"
    printf '  to install manually: ln -s %q ~/.local/bin/pa\n' "$plugin_pa" >&2
    return 0
  fi

  # If target exists as a symlink pointing elsewhere: --force-symlink
  # repoints; otherwise print the manual command.
  if [[ -L "$target" ]]; then
    local t
    t=$(readlink "$target" 2>/dev/null)
    if [[ "$t" == "$plugin_pa" ]]; then
      return 0  # already correct
    fi
    if [[ "$force" -eq 1 ]]; then
      ln -sfn -- "$plugin_pa" "$target" \
        || { warn "could not repoint $target"; return 0; }
      note "repointed ~/.local/bin/pa -> $plugin_pa"
    else
      warn "~/.local/bin/pa is a symlink to $t"
      printf '  to repoint: pa init --force-symlink (or: ln -sfn %q ~/.local/bin/pa)\n' "$plugin_pa" >&2
      return 0
    fi
  else
    # Target does not exist. Offer to create it.
    if [[ "$non_interactive" -eq 1 ]]; then
      note "skipping launcher symlink offer (--non-interactive)"
      note "to enable \`pa\` on \$PATH: ln -s $plugin_pa ~/.local/bin/pa"
      return 0
    fi
    printf '\n%sinstall ~/.local/bin/pa -> %s ?%s [Y/n]: ' \
      "$CYAN" "$plugin_pa" "$RESET" >&2
    local ans
    if ! IFS= read -r ans; then
      return 0
    fi
    case "${ans:-y}" in
      n|N|no) note "skipped — run \`pa init --force-symlink\` or symlink manually later"; return 0 ;;
    esac

    install -d -m 700 -- "$HOME/.local/bin"
    # Same-dir tmp + mv -n closes the TOCTOU window described in the
    # plan's deepen-plan security findings.
    local tmp
    tmp=$(mktemp -u "$HOME/.local/bin/.pa.XXXXXX")
    if ! ln -s -- "$plugin_pa" "$tmp"; then
      warn "could not create ~/.local/bin/pa (ln failed)"
      return 0
    fi
    if ! mv -n -- "$tmp" "$target"; then
      rm -f -- "$tmp"
      warn "could not install ~/.local/bin/pa (target appeared during install)"
      return 0
    fi
    note "installed ~/.local/bin/pa -> $plugin_pa"
  fi

  # Check $PATH membership — never auto-edit shell rc files. Print the
  # exact export line if ~/.local/bin is missing from $PATH.
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)
      printf '\n%s~/.local/bin is not on $PATH.%s add to your shell rc:\n' \
        "$YELLOW" "$RESET" >&2
      printf '  export PATH="$HOME/.local/bin:$PATH"\n' >&2
      ;;
  esac
  return 0
}

# Read a value with default, validating with the provided validator function.
_pa_prompt() {
  local var="$1" prompt="$2" default="$3"
  local validator="${4:-}"
  local input result

  while :; do
    if [[ -n "$default" ]]; then
      printf '%s [%s]: ' "$prompt" "$default" >&2
    else
      printf '%s: ' "$prompt" >&2
    fi
    if ! IFS= read -r input; then
      printf '\n' >&2
      die "pa init: stdin closed" 1
    fi
    input="${input:-$default}"

    if [[ -n "$validator" ]]; then
      if result=$($validator "$input" "$var" 2>&1); then
        printf '%s' "$result"
        return 0
      else
        printf '%s\n' "$result" >&2
        continue
      fi
    fi
    printf '%s' "$input"
    return 0
  done
}

# Load preset values into globals named `_pa_pv_<KEY>`. Bash 3.2 compatible
# (no associative arrays). Clears any previous load first.
_pa_load_preset() {
  local plugin_root="$1" preset_name="$2"
  # Clear any prior preset state.
  local key
  for key in "${_PA_ALL_KEYS[@]}"; do
    unset "_pa_pv_$key"
  done
  [[ -z "$preset_name" ]] && return 0

  local preset_dir="$plugin_root/presets/$preset_name"
  if [[ ! -d "$preset_dir" ]]; then
    warn "preset '$preset_name' not found at $preset_dir — starting fresh"
    return 0
  fi

  local line val
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Z_]+)=(.+)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    # shlex.quote may have wrapped the value in single quotes; strip them.
    if [[ "$val" =~ ^\'(.*)\'$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    eval "_pa_pv_$key=\$val"
  done < <(PYTHONPATH="$plugin_root/lib" python3 -m pa.preset_loader "$preset_dir")
}

# Read the preset-loaded value for KEY (or empty string if unset).
_pa_preset_value_for() {
  local var="_pa_pv_$1"
  printf '%s' "${!var:-}"
}

# List preset names available under $plugin_root/presets/.
_pa_list_presets() {
  local plugin_root="$1" entry name
  for entry in "$plugin_root"/presets/*/; do
    [[ -d "$entry" ]] || continue
    name=$(basename "$entry")
    [[ "$name" == "LICENSE" ]] && continue
    [[ -f "$entry/config.env" ]] || continue
    printf '%s\n' "$name"
  done
}

# Substitute {{KEY}} placeholders in $1 (file path) using all currently
# exported PA_* values. Writes to $1 in place.
_pa_substitute_skill() {
  local file="$1" key val
  [[ -f "$file" ]] || return 0
  local tmp
  tmp=$(mktemp)
  cp "$file" "$tmp"
  for key in "${_PA_ALL_KEYS[@]}"; do
    val="${!key:-}"
    # sed-safe escape: backslash, ampersand, forward-slash
    local escaped="${val//\\/\\\\}"
    escaped="${escaped//&/\\&}"
    escaped="${escaped//\//\\/}"
    sed -i.bak "s/{{$key}}/$escaped/g" "$tmp"
  done
  mv "$tmp" "$file"
  rm -f "$tmp.bak"
}

pa_init() {
  local non_interactive=0 print_settings=0 wizard=0 force_symlink=0
  local preset_override="" set_pairs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive) non_interactive=1; shift ;;
      --print-settings)  print_settings=1; shift ;;
      --wizard)          wizard=1; shift ;;
      --force-symlink)   force_symlink=1; shift ;;
      --preset)          preset_override="${2:-}"; shift 2 ;;
      --preset=*)        preset_override="${1#--preset=}"; shift ;;
      --set)             set_pairs+=("${2:-}"); shift 2 ;;
      --set=*)           set_pairs+=("${1#--set=}"); shift ;;
      -h|--help)
        cat >&2 <<'USAGE'
usage: pa init [<mode-flag>] [--preset <name>] [--set KEY=VALUE]...
               [--non-interactive] [--print-settings] [--force-symlink]

  Modes (mutually exclusive except --wizard + --preset):
    (default)         Auto-detect vault + projects-dir + backend,
                      confirm, write. Implicitly interactive.
    --wizard          Walk every field with the default chain.
    --preset <name>   Preset-only path. NAME validated against
                      presets/<name>/. Combine with --wizard to
                      override individual fields interactively.

  Modifiers:
    --set KEY=VALUE   Override a single value (repeatable).
    --non-interactive Read every value from $PA_INIT_<KEY> + --set;
                      auto-promoted when stdin is not a TTY.
    --print-settings  Emit settings.json snippet only; write no
                      config. Still runs full detection — auto-detect
                      failure exits 2.
    --force-symlink   Re-point an existing ~/.local/bin/pa symlink at
                      the plugin's bin/pa. Refuses to clobber regular
                      files regardless of flag.

  Value resolution order (highest precedence wins):
    1. --set KEY=VALUE        (cmdline)
    2. $PA_INIT_<KEY>         (env)
    3. preset (--preset NAME, or "default" in auto-detect mode)
    4. value in current shell ($PA_VAULT etc. already exported)
    5. auto-detect (default mode only)
    6. presets/default/config.env (final fallback)

Side effect: writes the resolved preset's SKILL.md (with {{PA_*}}
placeholders substituted) into the plugin's
skills/personal-assistant/SKILL.md. If you point pa at a dev checkout
(`pa dev on`), that file is in your git working tree — discard with
`git checkout -- skills/personal-assistant/SKILL.md` after testing.
USAGE
        return 0
        ;;
      *) die "pa init: unknown flag $1 (run \`pa init --help\`)" 2 ;;
    esac
  done

  # TTY auto-promotion — matches gh auth login. Stdin not a TTY ⇒ we
  # cannot prompt, so behave like --non-interactive even without the flag.
  if [[ ! -t 0 ]]; then
    non_interactive=1
  fi

  local plugin_root
  plugin_root=$(_pa_plugin_root_for_wizard)
  [[ -d "$plugin_root" ]] || die "pa init: plugin root not found at $plugin_root" 1

  # Validate --preset NAME before any other work. The chooser path
  # (interactive --wizard with no explicit preset) does its own
  # availability listing below.
  if [[ -n "$preset_override" ]]; then
    if [[ ! -f "$plugin_root/presets/$preset_override/config.env" ]]; then
      printf 'pa init: preset %q not found at %s/presets/%s\n' \
        "$preset_override" "$plugin_root" "$preset_override" >&2
      printf 'available presets:\n' >&2
      _pa_list_presets "$plugin_root" | sed 's/^/  /' >&2
      return 2
    fi
  fi

  # Mode selection — flags collapse onto three named modes for the rest
  # of the function. --wizard + --preset is allowed (preset preloads,
  # wizard prompts every field). Bare --preset is preset-only mode;
  # bare (no flags) is auto-detect mode.
  local mode
  if [[ $wizard -eq 1 ]]; then
    mode=wizard
  elif [[ -n "$preset_override" ]]; then
    mode=preset
  else
    mode=auto
  fi

  # Acquire init lock + register cleanup trap. Lock release + tmpfile
  # cleanup happen via _pa_init_cleanup. SIGINT exits 130 (POSIX
  # convention) with no partial write.
  if ! _pa_acquire_init_lock; then
    return 1
  fi
  trap '_pa_init_cleanup' EXIT
  trap '_pa_init_cleanup; exit 130' INT TERM

  local config_file="$CONFIG_DIR/config.sh"

  # Existing-config detection — interactive only. CI / --non-interactive
  # always overwrites; user opted in by passing the flag. --wizard does
  # NOT bypass this prompt (idempotence preserved across modes).
  if [[ -f "$config_file" && $non_interactive -eq 0 && $print_settings -eq 0 ]]; then
    note "existing config at $config_file"
    printf 'choose: [k]eep + tweak / [r]eplace / [c]ancel [k]: ' >&2
    local choice
    if ! IFS= read -r choice; then
      die "pa init: stdin closed" 1
    fi
    case "${choice:-k}" in
      c|C) note "cancelled"; return 0 ;;
      r|R) : ;;
      *)
        # shellcheck disable=SC1090
        source "$config_file"
        ;;
    esac
  fi

  # Preset selection per mode.
  local preset=""
  case "$mode" in
    auto)
      preset="default"
      ;;
    preset)
      preset="$preset_override"
      ;;
    wizard)
      if [[ -n "$preset_override" ]]; then
        preset="$preset_override"
      elif [[ $non_interactive -eq 0 ]]; then
        # Interactive --wizard with no preset — keep today's numbered
        # chooser so existing users see no UX change in this branch.
        note "available presets:"
        local i=0 names=() p
        while IFS= read -r p; do
          i=$((i + 1))
          names+=("$p")
          printf '  %d) %s\n' "$i" "$p" >&2
        done < <(_pa_list_presets "$plugin_root")
        i=$((i + 1))
        printf '  %d) start fresh (no preset)\n' "$i" >&2

        printf 'pick [1]: ' >&2
        local pick
        IFS= read -r pick
        pick="${pick:-1}"
        if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick > 0 && pick <= ${#names[@]} )); then
          preset="${names[$((pick - 1))]}"
        fi
      fi
      ;;
  esac

  _pa_load_preset "$plugin_root" "$preset"

  # Walk each key. Resolved values stored as _pa_val_<KEY>, sources as
  # _pa_src_<KEY>. Both are bash 3.2 friendly (indirect expansion).
  local key val src pair env_key candidates_buf candidate i pick
  for key in "${_PA_ALL_KEYS[@]}"; do
    val=""
    src=""

    # 1. --set
    for pair in "${set_pairs[@]+"${set_pairs[@]}"}"; do
      if [[ "$pair" =~ ^${key}=(.*)$ ]]; then
        val="${BASH_REMATCH[1]}"; src="(--set)"; break
      fi
    done

    # 2. $PA_INIT_<KEY> env
    if [[ -z "$val" ]]; then
      env_key="PA_INIT_$key"
      if [[ -n "${!env_key:-}" ]]; then
        val="${!env_key}"; src="(env)"
      fi
    fi

    # 3. preset
    if [[ -z "$val" ]]; then
      val=$(_pa_preset_value_for "$key")
      [[ -n "$val" ]] && src="(preset:$preset)"
    fi

    # 4. current shell
    if [[ -z "$val" ]]; then
      val="${!key:-}"
      [[ -n "$val" ]] && src="(shell)"
    fi

    # 5. auto-detect (default mode only, for the three keys we can detect)
    if [[ -z "$val" && "$mode" == "auto" ]]; then
      case "$key" in
        PA_VAULT)
          candidates_buf=()
          while IFS= read -r candidate; do
            [[ -n "$candidate" ]] && candidates_buf+=("$candidate")
          done < <(_pa_detect_vault)
          case "${#candidates_buf[@]}" in
            0) ;;
            1) val="${candidates_buf[0]}"; src="(auto-detect)" ;;
            *)
              if [[ $non_interactive -eq 1 ]]; then
                : # leave val empty — required-key check will fail explicitly
              else
                printf '\n%smultiple vaults detected:%s\n' "$CYAN" "$RESET" >&2
                i=0
                for candidate in "${candidates_buf[@]}"; do
                  i=$((i+1))
                  printf '  %d) %s\n' "$i" "$candidate" >&2
                done
                printf 'pick [1]: ' >&2
                if ! IFS= read -r pick; then
                  die "pa init: stdin closed" 1
                fi
                pick="${pick:-1}"
                if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick > 0 && pick <= ${#candidates_buf[@]} )); then
                  val="${candidates_buf[$((pick-1))]}"; src="(auto-detect)"
                fi
              fi
              ;;
          esac
          ;;
        PA_PROJECTS_DIR)
          if val=$(_pa_detect_projects_dir 2>/dev/null); then
            src="(auto-detect)"
          else
            val=""
          fi
          ;;
        PA_TERMINAL_BACKEND)
          val=$(_pa_detect_backend); src="(auto-detect)"
          ;;
      esac
    fi

    # 6. wizard-mode prompts every field
    if [[ "$mode" == "wizard" && $non_interactive -eq 0 ]]; then
      case "$key" in
        PA_VAULT|PA_PROJECTS_DIR)
          val=$(_pa_prompt "$key" "$key (absolute path)" "$val" _pa_validate_path)
          ;;
        *)
          val=$(_pa_prompt "$key" "$key" "$val")
          ;;
      esac
      [[ -z "$src" ]] && src="(prompted)"
    fi

    # 7. auto-mode inline prompt when still empty (required keys only)
    if [[ "$mode" == "auto" && $non_interactive -eq 0 && -z "$val" ]]; then
      case "$key" in
        PA_VAULT|PA_PROJECTS_DIR)
          val=$(_pa_prompt "$key" "$key (absolute path)" "" _pa_validate_path)
          src="(prompted)"
          ;;
      esac
    fi

    eval "_pa_val_$key=\$val"
    eval "_pa_src_$key=\$src"
  done

  # Required-key check — fail loudly under --non-interactive when
  # auto-detect could not resolve and no --set provided.
  for key in "${_PA_REQUIRED_KEYS[@]}"; do
    local var="_pa_val_$key"
    if [[ -z "${!var:-}" ]]; then
      die "pa init: $key not detected and no --set value provided — pass --set $key=<path>" 2
    fi
    if [[ ! -d "${!var}" ]]; then
      die "pa init: $key=${!var} is not a directory" 2
    fi
  done

  # Auto-mode confirm block — user reviews labelled-source values, y/n.
  if [[ "$mode" == "auto" && $non_interactive -eq 0 && $print_settings -eq 0 ]]; then
    if ! _pa_confirm_block; then
      return 0
    fi
  fi

  # Pipe every resolved value through pa.paths.validate_assignments
  # regardless of mode. Closes the --non-interactive validation-bypass
  # gap flagged by the deepen-plan security review.
  #
  # Wrap each value in double quotes — the strict parser's bare-char
  # class excludes spaces, pipes, em-dashes, etc., so any non-trivial
  # value (vault titles with Unicode, daily-template paths with spaces,
  # spawn templates with pipes) must be quoted. Values that contain a
  # literal " or \ are rejected (correctly) by the parser since the
  # strict config format can't represent them anyway.
  local validate_input="" validate_stderr
  for key in "${_PA_ALL_KEYS[@]}"; do
    local vv="_pa_val_$key" sv="_pa_src_$key"
    [[ -z "${!vv:-}" ]] && continue
    validate_input+="${key}=\"${!vv}\"	# ${!sv:-(default)}"$'\n'
  done
  validate_stderr=$(mktemp)
  if ! printf '%s' "$validate_input" \
       | PYTHONPATH="$plugin_root/lib" python3 -m pa.paths validate-assignments \
         >/dev/null 2>"$validate_stderr"; then
    warn "validation failed:"
    cat "$validate_stderr" >&2
    rm -f "$validate_stderr"
    die "pa init: refusing to write invalid config" 2
  fi
  rm -f "$validate_stderr"

  # Export resolved values so the SKILL.md substitution can read by name.
  for key in "${_PA_ALL_KEYS[@]}"; do
    local var="_pa_val_$key"
    eval "export $key=\"\${$var}\""
  done

  # --print-settings short-circuits before the write.
  if [[ $print_settings -eq 1 ]]; then
    _pa_emit_settings_snippet \
      "${PA_TERMINAL_BACKEND:-auto}" \
      "$DATA_DIR" \
      "$PA_VAULT" \
      "$plugin_root/bin/pa.sh"
    return 0
  fi

  # Atomic write — see _pa_atomic_write_config for the rename dance.
  _pa_atomic_write_config

  if [[ -n "$preset" ]]; then
    printf '%s\n' "$preset" > "$CONFIG_DIR/preset"
    chmod 600 "$CONFIG_DIR/preset"
  fi

  # SKILL.md substitution — non-fatal because the config is the source
  # of truth; SKILL.md regenerates on next `pa init`.
  local skill_src skill_dst
  if [[ -n "$preset" && -f "$plugin_root/presets/$preset/SKILL.md" ]]; then
    skill_src="$plugin_root/presets/$preset/SKILL.md"
  else
    skill_src="$plugin_root/skills/personal-assistant/SKILL.md"
  fi
  skill_dst="$plugin_root/skills/personal-assistant/SKILL.md"
  if [[ "$skill_src" != "$skill_dst" ]]; then
    cp "$skill_src" "$skill_dst" 2>/dev/null \
      || warn "SKILL.md copy from $skill_src failed — config still written"
  fi
  _pa_substitute_skill "$skill_dst" 2>/dev/null \
    || warn "SKILL.md substitution failed — config still written"

  # Offer to install ~/.local/bin/pa launcher symlink (post-write — by
  # this point the config is durable). Skipped under --non-interactive.
  _pa_offer_launcher_symlink "$plugin_root" "$force_symlink" "$non_interactive"

  note "wrote $config_file"
  [[ -n "$preset" ]] && note "preset: $preset (recorded at $CONFIG_DIR/preset)"
  note "data dir: $DATA_DIR"
  note "skill: $skill_dst"
  printf '\n%spaste into ~/.claude/settings.json (under "permissions.allow"):%s\n' "$CYAN" "$RESET" >&2
  _pa_emit_settings_snippet \
    "${PA_TERMINAL_BACKEND:-auto}" \
    "$DATA_DIR" \
    "$PA_VAULT" \
    "$plugin_root/bin/pa.sh"
}

# ─── pa doctor ─────────────────────────────────────────────────────────────

# Buffer for --json output mode. Each check appends one entry; the JSON
# emit happens once at the end.
_PA_DOCTOR_JSON=0
_PA_DOCTOR_CHECKS=()

# Escape a string for inclusion in a JSON value. Bash 3.2 compatible.
_pa_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

_pa_check() {
  local label="$1" status="$2" detail="${3:-}"
  if [[ "$_PA_DOCTOR_JSON" -eq 1 ]]; then
    local lbl det
    lbl=$(_pa_json_escape "$label")
    det=$(_pa_json_escape "$detail")
    _PA_DOCTOR_CHECKS+=("{\"label\":\"$lbl\",\"status\":\"$status\",\"detail\":\"$det\"}")
    return 0
  fi
  case "$status" in
    OK)   printf '  %s✓%s %s%s\n' "$(_pa_green)" "$RESET" "$label" "${detail:+ — $detail}" ;;
    WARN) printf '  %s~%s %s%s\n' "$YELLOW" "$RESET" "$label" "${detail:+ — $detail}" ;;
    FAIL) printf '  %s✗%s %s%s\n' "$RED" "$RESET" "$label" "${detail:+ — $detail}" ;;
  esac
}

_pa_green() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then printf '\033[32m'; else printf ''; fi
}

pa_doctor() {
  local verbose=0
  _PA_DOCTOR_JSON=0
  _PA_DOCTOR_CHECKS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose) verbose=1; shift ;;
      --json)       _PA_DOCTOR_JSON=1; shift ;;
      -h|--help)
        cat >&2 <<'USAGE'
usage: pa doctor [--verbose] [--json]

Checks the claude-pa install: CC version, config file, terminal backend,
required paths, dependencies, and settings.json allow rules. Exits 0 if
everything is green, 1 if any check fails (warnings still pass).

--json emits a structured payload: {"ok": bool, "checks": [...]}.
USAGE
        return 0
        ;;
      *) die "pa doctor: unknown flag $1" 2 ;;
    esac
  done

  local fails=0

  if [[ "$_PA_DOCTOR_JSON" -ne 1 ]]; then
    printf '%spa doctor%s\n' "$CYAN" "$RESET"
  fi

  # 1. Claude Code version >= 2.1.141
  if command -v claude >/dev/null 2>&1; then
    local ver
    ver=$(claude --version 2>/dev/null | head -1 || true)
    if [[ -n "$ver" ]]; then
      local num
      num=$(printf '%s' "$ver" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
      if [[ -n "$num" ]]; then
        # Compare against floor 2.1.141
        if printf '%s\n2.1.141\n' "$num" | sort -V | head -1 | grep -qx "2.1.141"; then
          _pa_check "Claude Code version" OK "$ver"
        else
          _pa_check "Claude Code version" FAIL "$ver < required 2.1.141"
          fails=$((fails + 1))
        fi
      else
        _pa_check "Claude Code version" WARN "could not parse: $ver"
      fi
    else
      _pa_check "Claude Code version" FAIL "claude --version returned nothing"
      fails=$((fails + 1))
    fi
  else
    _pa_check "Claude Code version" FAIL "claude binary not on PATH"
    fails=$((fails + 1))
  fi

  # 2. Config file present + parseable
  local config_file="$CONFIG_DIR/config.sh"
  if [[ -f "$config_file" ]]; then
    if bash -n "$config_file" 2>/dev/null; then
      _pa_check "config.sh present + parseable" OK "$config_file"
    else
      _pa_check "config.sh present + parseable" FAIL "syntax error in $config_file"
      fails=$((fails + 1))
    fi
    # shellcheck disable=SC1090
    source "$config_file"
  else
    _pa_check "config.sh present + parseable" FAIL "$config_file missing — run \`pa init\`"
    fails=$((fails + 1))
    if [[ "$_PA_DOCTOR_JSON" -eq 1 ]]; then
      local joined; joined=$(IFS=,; printf '%s' "${_PA_DOCTOR_CHECKS[*]}")
      printf '{"ok":false,"fails":%d,"checks":[%s]}\n' "$fails" "$joined"
    fi
    return 1
  fi

  # 3. Terminal backend reachable
  local plugin_root
  plugin_root=$(_pa_plugin_root_for_wizard)
  local backend="${PA_TERMINAL_BACKEND:-auto}"
  if [[ "$backend" == "auto" ]]; then
    backend=$(_pa_resolve_backend)
  fi
  local backend_lib="$plugin_root/lib/terminal/$backend.sh"
  if [[ -f "$backend_lib" ]]; then
    if ( # shellcheck disable=SC1090
         source "$backend_lib"
         terminal_health >/dev/null 2>&1
       ); then
      _pa_check "terminal backend reachable" OK "$backend"
    else
      _pa_check "terminal backend reachable" FAIL "$backend backend can't reach its mux server"
      fails=$((fails + 1))
    fi
  else
    _pa_check "terminal backend reachable" FAIL "no lib for $backend at $backend_lib"
    fails=$((fails + 1))
  fi

  # 4. Paths exist
  local path_fail=0
  for var in PA_VAULT PA_PROJECTS_DIR; do
    if [[ -d "${!var:-}" ]]; then
      _pa_check "$var directory" OK "${!var}"
    else
      _pa_check "$var directory" FAIL "${!var:-(unset)} not a directory"
      fails=$((fails + 1))
      path_fail=1
    fi
  done
  if [[ $path_fail -eq 0 ]]; then
    local tpl="$PA_VAULT/${PA_DAILY_TEMPLATE_PATH:-_templates/Daily Note.md}"
    if [[ -f "$tpl" ]]; then
      _pa_check "daily template" OK "$tpl"
    else
      _pa_check "daily template" WARN "$tpl missing (first morning will need it)"
    fi
  fi

  # 5. Required deps
  local dep_var
  for dep in gh python3 jq; do
    if command -v "$dep" >/dev/null 2>&1; then
      _pa_check "$dep present" OK "$(command -v "$dep")"
    else
      case "$dep" in
        gh) _pa_check "$dep present" WARN "missing — PR enrichment skipped" ;;
        *)  _pa_check "$dep present" FAIL "missing"; fails=$((fails + 1)) ;;
      esac
    fi
  done

  # Python version >= 3.9
  if command -v python3 >/dev/null 2>&1; then
    local py
    py=$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')
    if printf '%s\n3.9\n' "$py" | sort -V | head -1 | grep -qx "3.9"; then
      _pa_check "python3 >= 3.9" OK "$py"
    else
      _pa_check "python3 >= 3.9" FAIL "$py < 3.9"
      fails=$((fails + 1))
    fi
  fi

  # Bash 4+
  local bash_ver="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
  if (( BASH_VERSINFO[0] >= 4 )); then
    _pa_check "bash >= 4" OK "$bash_ver"
  else
    _pa_check "bash >= 4" FAIL "$bash_ver (run \`brew install bash\` on macOS)"
    fails=$((fails + 1))
  fi

  # Backend-specific deps
  case "$backend" in
    tmux)
      if command -v tmux >/dev/null 2>&1; then
        local tv
        tv=$(tmux -V | awk '{print $2}')
        _pa_check "tmux >= 3.0" OK "$tv"
      else
        _pa_check "tmux >= 3.0" FAIL "missing"
        fails=$((fails + 1))
      fi
      ;;
    wezterm) command -v wezterm >/dev/null 2>&1 || { _pa_check "wezterm on PATH" FAIL "missing"; fails=$((fails + 1)); } ;;
    kitty)   command -v kitten >/dev/null 2>&1 || command -v kitty >/dev/null 2>&1 || { _pa_check "kitten / kitty on PATH" FAIL "missing"; fails=$((fails + 1)); } ;;
  esac

  # 6. settings.json allow rules — warn only, never fail
  local sj="$HOME/.claude/settings.json"
  if [[ -f "$sj" ]] && grep -q "$plugin_root/bin/pa.sh" "$sj" 2>/dev/null; then
    _pa_check "settings.json allow rule for pa.sh" OK
  else
    _pa_check "settings.json allow rule for pa.sh" WARN "not detected (run \`pa init --print-settings\` for the snippet)"
  fi

  # ─── JSON mode emits structured payload + exits early ────────────────
  if [[ "$_PA_DOCTOR_JSON" -eq 1 ]]; then
    local joined ok=true
    if (( fails > 0 )); then ok=false; fi
    joined=$(IFS=,; printf '%s' "${_PA_DOCTOR_CHECKS[*]}")
    printf '{"ok":%s,"fails":%d,"checks":[%s]}\n' "$ok" "$fails" "$joined"
    if (( fails == 0 )); then return 0; else return 1; fi
  fi

  # ─── Verbose dump ────────────────────────────────────────────────────
  if [[ $verbose -eq 1 ]]; then
    printf '\n%s--- diagnostic dump ---%s\n' "$CYAN" "$RESET"
    printf 'plugin_root: %s\n' "$plugin_root"
    printf 'config_dir:  %s\n' "$CONFIG_DIR"
    printf 'data_dir:    %s\n' "$DATA_DIR"
    printf 'backend:     %s\n' "$backend"
    printf 'TERM_PROGRAM=%s TMUX=%s KITTY_WINDOW_ID=%s\n' \
      "${TERM_PROGRAM:-}" "${TMUX:-}" "${KITTY_WINDOW_ID:-}"
    printf 'PA_VAULT=%s\n' "${PA_VAULT:-}"
    printf 'PA_PROJECTS_DIR=%s\n' "${PA_PROJECTS_DIR:-}"
    printf 'os: %s %s\n' "$(uname -s)" "$(uname -r)"
  fi

  printf '\n'
  if (( fails == 0 )); then
    printf '%sall checks passed%s\n' "$(_pa_green)" "$RESET"
    return 0
  fi
  printf '%s%d check(s) failed%s — fix the ✗ items above\n' "$RED" "$fails" "$RESET"
  return 1
}

# ─── pa uninstall ──────────────────────────────────────────────────────────

pa_uninstall() {
  local force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force) force=1; shift ;;
      -h|--help)
        cat >&2 <<'USAGE'
usage: pa uninstall [--force]

Removes claude-pa's config + dev marker at $XDG_CONFIG_HOME/claude-pa/
and (optionally, after a second prompt) the data dir at
$XDG_DATA_HOME/claude-pa/. Prints a reverse settings.json snippet so
you can remove the allow rules manually.

Does NOT remove the plugin install itself — run
`/plugin uninstall claude-pa` from inside a Claude session for that.
USAGE
        return 0
        ;;
      *) die "pa uninstall: unknown flag $1" 2 ;;
    esac
  done

  printf '%spa uninstall%s\n' "$CYAN" "$RESET"
  printf 'will remove:\n  %s\n' "$CONFIG_DIR"
  printf 'data dir (state + cache + logs + learnings.md) will be addressed separately.\n\n'

  if [[ $force -eq 0 ]]; then
    printf 'proceed? [y/N]: '
    local choice
    IFS= read -r choice
    case "${choice:-n}" in
      y|Y|yes) : ;;
      *) note "cancelled"; return 0 ;;
    esac
  fi

  if [[ -d "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR"
    note "removed $CONFIG_DIR"
  else
    warn "no config dir at $CONFIG_DIR"
  fi

  if [[ -d "$DATA_DIR" ]]; then
    local remove_data=0
    if [[ $force -eq 1 ]]; then
      remove_data=1
    else
      printf '\nALSO remove %s ? this deletes:\n' "$DATA_DIR"
      printf '  - %s/state/ (transient — rebuilds itself)\n' "$DATA_DIR"
      printf '  - %s/cache/ (transient)\n' "$DATA_DIR"
      printf '  - %s/logs/  (debug logs)\n' "$DATA_DIR"
      printf '  - %s/learnings.md (your accumulated patterns — IRRECOVERABLE)\n' "$DATA_DIR"
      printf '[y/N]: '
      local choice2
      IFS= read -r choice2
      case "${choice2:-n}" in
        y|Y|yes) remove_data=1 ;;
      esac
    fi
    if [[ $remove_data -eq 1 ]]; then
      rm -rf "$DATA_DIR"
      note "removed $DATA_DIR"
    else
      note "kept $DATA_DIR (you can `rm -rf` it manually later)"
    fi
  fi

  printf '\nremove these lines from ~/.claude/settings.json under "permissions.allow":\n'
  cat <<'JSON'
  "Bash(.../bin/pa.sh:*)"
  "Bash(<terminal backend, e.g. wezterm|kitten|kitty|tmux|osascript>:*)"
  "Read(<data dir>/**)"
  "Read(<vault>/**)"
  "Write(<data dir>/**)"
  "Edit(<vault>/**)"
JSON
  printf '\nrun `/plugin uninstall claude-pa` inside a Claude session to remove the plugin itself.\n'
}
