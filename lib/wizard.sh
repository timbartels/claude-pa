# lib/wizard.sh — implementations of `pa init`, `pa doctor`, `pa uninstall`.
#
# Sourced by bin/pa when one of those subcommands is invoked. Not sourced
# for the bare-invocation / `pa dev …` paths.
#
# Inherits from bin/pa: die / note / warn / _pa_resolve_safe /
# _pa_validate_plugin_dir / RED / YELLOW / CYAN / RESET / CONFIG_DIR /
# DATA_DIR. Does not depend on lib/paths.sh (which requires $PA_CONFIG to
# already exist — exactly what `pa init` is creating).

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

_PA_DEFAULTS_PA_TERMINAL_BACKEND=auto
_PA_DEFAULTS_PA_MAIN_TITLE=MAIN
_PA_DEFAULTS_PA_DAILY_DIR=Daily
_PA_DEFAULTS_PA_DAILY_TEMPLATE_PATH="_templates/Daily Note.md"
_PA_DEFAULTS_PA_WORK_SECTION=Work
_PA_DEFAULTS_PA_PERSONAL_SECTION=Personal
_PA_DEFAULTS_PA_FEATURE_NOTE_DIR=PROJECTS
_PA_DEFAULTS_PA_STATUS_VALUES="brainstorming,planned,in-progress,shipped"
_PA_DEFAULTS_PA_STATUS_SHIPPED=shipped
_PA_DEFAULTS_PA_SPAWN_PROMPT_TEMPLATE=""
_PA_DEFAULTS_PA_DASHBOARD_INTERVAL=2
_PA_DEFAULTS_PA_DEBUG=0

# ─── Helpers ───────────────────────────────────────────────────────────────

# Lookup the default for KEY. Returns empty string if no default exists
# (PA_VAULT / PA_PROJECTS_DIR — both required, no built-in fallback).
_pa_default_for() {
  local var="_PA_DEFAULTS_$1"
  printf '%s' "${!var:-}"
}

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
  local non_interactive=0 print_settings=0 preset_override="" set_pairs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive) non_interactive=1; shift ;;
      --print-settings)  print_settings=1; shift ;;
      --preset)          preset_override="${2:-}"; shift 2 ;;
      --preset=*)        preset_override="${1#--preset=}"; shift ;;
      --set)             set_pairs+=("${2:-}"); shift 2 ;;
      --set=*)           set_pairs+=("${1#--set=}"); shift ;;
      -h|--help)
        cat >&2 <<'USAGE'
usage: pa init [--non-interactive] [--preset <name>] [--set KEY=VALUE]... [--print-settings]

  --non-interactive   Read every value from $PA_INIT_<KEY> env vars and
                      --set flags; never prompt. Exits non-zero on missing
                      required vars. Required for CI smoke tests.
  --preset <name>     Preload defaults from presets/<name>/.
  --set KEY=VALUE     Override a single value (repeatable). Wins over the
                      preset's default.
  --print-settings    Emit only the settings.json allow-rules snippet
                      (does not write the config file). Useful for piping
                      into `jq merge`.

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

  local plugin_root
  plugin_root=$(_pa_plugin_root_for_wizard)
  [[ -d "$plugin_root" ]] || die "pa init: plugin root not found at $plugin_root" 1

  local config_file="$CONFIG_DIR/config.sh"

  # Existing-config detection — interactive only. CI / --non-interactive
  # always overwrites; user opted in by passing the flag.
  if [[ -f "$config_file" && $non_interactive -eq 0 && $print_settings -eq 0 ]]; then
    note "existing config at $config_file"
    printf 'choose: [k]eep + tweak / [r]eplace from preset / [c]ancel [k]: ' >&2
    local choice
    IFS= read -r choice
    case "${choice:-k}" in
      c|C) note "cancelled"; return 0 ;;
      r|R) : ;;  # fall through; preset selection below handles it
      *)
        # "keep + tweak" loads existing config as the starting point.
        # shellcheck disable=SC1090
        source "$config_file"
        ;;
    esac
  fi

  # ─── Preset selection ────────────────────────────────────────────────
  local preset=""
  if [[ -n "$preset_override" ]]; then
    preset="$preset_override"
  elif [[ $non_interactive -eq 0 ]]; then
    note "available presets:"
    local i=0 names=()
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

  _pa_load_preset "$plugin_root" "$preset"

  # ─── Walk through each key ───────────────────────────────────────────
  # Resolved values stored as globals _pa_val_<KEY> (bash 3.2 friendly).
  local key val pair env_key
  for key in "${_PA_ALL_KEYS[@]}"; do
    # Precedence: --set > $PA_INIT_<KEY> env > preset > current shell > built-in default
    val=""
    for pair in "${set_pairs[@]+"${set_pairs[@]}"}"; do
      if [[ "$pair" =~ ^${key}=(.*)$ ]]; then
        val="${BASH_REMATCH[1]}"
        break
      fi
    done
    if [[ -z "$val" ]]; then
      env_key="PA_INIT_$key"
      val="${!env_key:-}"
    fi
    if [[ -z "$val" ]]; then
      val=$(_pa_preset_value_for "$key")
    fi
    if [[ -z "$val" ]]; then
      val="${!key:-}"
    fi
    if [[ -z "$val" ]]; then
      val=$(_pa_default_for "$key")
    fi

    if [[ $non_interactive -eq 0 ]]; then
      case "$key" in
        PA_VAULT|PA_PROJECTS_DIR)
          val=$(_pa_prompt "$key" "$key (absolute path)" "$val" _pa_validate_path)
          ;;
        *)
          val=$(_pa_prompt "$key" "$key" "$val")
          if ! _pa_safe_value "$val"; then
            warn "$key contains a forbidden shell metacharacter — re-prompting"
            val=$(_pa_prompt "$key" "$key" "$val")
          fi
          ;;
      esac
    fi
    eval "_pa_val_$key=\$val"
  done

  # ─── Required-var validation ─────────────────────────────────────────
  for key in "${_PA_REQUIRED_KEYS[@]}"; do
    local var="_pa_val_$key"
    if [[ -z "${!var:-}" ]]; then
      die "pa init: $key is required but unset (pass via --set or \$PA_INIT_$key env)" 2
    fi
    if [[ ! -d "${!var}" ]]; then
      die "pa init: $key=${!var} is not a directory" 2
    fi
  done

  # ─── Export so the substitution step + helpers can read by name ──────
  for key in "${_PA_ALL_KEYS[@]}"; do
    local var="_pa_val_$key"
    eval "export $key=\"\${$var}\""
  done

  # ─── Settings-snippet-only mode ──────────────────────────────────────
  if [[ $print_settings -eq 1 ]]; then
    _pa_emit_settings_snippet \
      "${PA_TERMINAL_BACKEND:-auto}" \
      "$DATA_DIR" \
      "$PA_VAULT" \
      "$plugin_root/bin/pa.sh"
    return 0
  fi

  # ─── Write config + preset marker ────────────────────────────────────
  install -d -m 700 -- "$CONFIG_DIR"
  install -d -m 700 -- "$DATA_DIR" "$DATA_DIR/state" "$DATA_DIR/cache" "$DATA_DIR/logs"

  local tmp_cfg
  tmp_cfg=$(mktemp)
  {
    printf '# ~/.config/claude-pa/config.sh — generated by `pa init` on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# Edit by hand or re-run `pa init` to regenerate.\n\n'
    local key var
    for key in "${_PA_ALL_KEYS[@]}"; do
      var="_pa_val_$key"
      printf '%s=%q\n' "$key" "${!var}"
    done
  } > "$tmp_cfg"
  install -m 600 "$tmp_cfg" "$config_file"
  rm -f "$tmp_cfg"

  if [[ -n "$preset" ]]; then
    printf '%s\n' "$preset" > "$CONFIG_DIR/preset"
    chmod 600 "$CONFIG_DIR/preset"
  fi

  # ─── Substitute SKILL.md placeholders into the plugin's skill file ───
  local skill_src skill_dst
  if [[ -n "$preset" && -f "$plugin_root/presets/$preset/SKILL.md" ]]; then
    skill_src="$plugin_root/presets/$preset/SKILL.md"
  else
    skill_src="$plugin_root/skills/personal-assistant/SKILL.md"
  fi
  skill_dst="$plugin_root/skills/personal-assistant/SKILL.md"
  if [[ "$skill_src" != "$skill_dst" ]]; then
    cp "$skill_src" "$skill_dst"
  fi
  _pa_substitute_skill "$skill_dst"

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

_pa_check() {
  local label="$1" status="$2" detail="${3:-}"
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
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose) verbose=1; shift ;;
      -h|--help)
        cat >&2 <<'USAGE'
usage: pa doctor [--verbose]

Checks the claude-pa install: CC version, config file, terminal backend,
required paths, dependencies, and settings.json allow rules. Exits 0 if
everything is green, 1 if any check fails (warnings still pass).
USAGE
        return 0
        ;;
      *) die "pa doctor: unknown flag $1" 2 ;;
    esac
  done

  local fails=0

  printf '%spa doctor%s\n' "$CYAN" "$RESET"

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
    return 1
  fi

  # 3. Terminal backend reachable
  local plugin_root
  plugin_root=$(_pa_plugin_root_for_wizard)
  local backend="${PA_TERMINAL_BACKEND:-auto}"
  if [[ "$backend" == "auto" ]]; then
    if [[ -n "${TMUX:-}" ]]; then backend=tmux
    elif [[ "${TERM_PROGRAM:-}" == "WezTerm" ]]; then backend=wezterm
    elif [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]]; then backend=iterm2
    elif [[ -n "${KITTY_WINDOW_ID:-}" ]]; then backend=kitty
    else backend=tmux
    fi
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
