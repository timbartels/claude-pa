#!/usr/bin/env bats
# tests/bats/pa-init.bats — covers `pa init` wizard flows.

setup() {
  PA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export PA_ROOT
  export TMPHOME="$(mktemp -d)"
  export XDG_CONFIG_HOME="$TMPHOME/xdg-config"
  export XDG_DATA_HOME="$TMPHOME/xdg-data"
  mkdir -p "$TMPHOME/vault" "$TMPHOME/projects"
  # Unset PA_* env that may leak from a developer's parent shell so the
  # XDG_CONFIG_HOME we just set actually wins inside pa init + paths.sh.
  unset PA_CONFIG PA_DATA_DIR PA_STATE_DIR PA_CACHE_DIR PA_LOGS_DIR \
    PA_VAULT PA_PROJECTS_DIR PA_TERMINAL_BACKEND PA_MAIN_TITLE \
    PA_DAILY_DIR PA_DAILY_TEMPLATE_PATH PA_WORK_SECTION PA_PERSONAL_SECTION \
    PA_FEATURE_NOTE_DIR PA_STATUS_VALUES PA_STATUS_SHIPPED \
    PA_SPAWN_PROMPT_TEMPLATE PA_DASHBOARD_INTERVAL PA_DEBUG \
    _PA_PATHS_LOADED
}

teardown() {
  rm -rf "$TMPHOME"
  # Restore the skill template; pa init mutates it during substitution.
  git -C "$PA_ROOT" checkout -- skills/personal-assistant/SKILL.md 2>/dev/null || true
}

@test "pa init --non-interactive with obsidian-ce preset writes config + preset marker" {
  run "$PA_ROOT/bin/pa" init --non-interactive --preset obsidian-ce \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects" \
    --set "PA_TERMINAL_BACKEND=tmux"
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/claude-pa/config.sh" ]
  [ -f "$XDG_CONFIG_HOME/claude-pa/preset" ]
  [ "$(cat "$XDG_CONFIG_HOME/claude-pa/preset")" = "obsidian-ce" ]
}

@test "pa init writes a config that sources cleanly via lib/paths.sh" {
  "$PA_ROOT/bin/pa" init --non-interactive --preset obsidian-ce \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects" \
    --set "PA_TERMINAL_BACKEND=tmux" >/dev/null
  export PA_CONFIG="$XDG_CONFIG_HOME/claude-pa/config.sh"
  export PA_DATA_DIR="$XDG_DATA_HOME/claude-pa"
  run bash -c "source $PA_ROOT/lib/paths.sh && echo \"\$PA_VAULT|\$PA_TERMINAL_BACKEND\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"|tmux" ]]
}

@test "pa init --print-settings emits JSON snippet and writes no config" {
  run "$PA_ROOT/bin/pa" init --print-settings --non-interactive --preset obsidian-ce \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects"
  [ "$status" -eq 0 ]
  # Snippet must parse as JSON
  echo "$output" | python3 -m json.tool >/dev/null
  # Config file must not have been written
  [ ! -f "$XDG_CONFIG_HOME/claude-pa/config.sh" ]
}

@test "pa init --print-settings resolves PA_TERMINAL_BACKEND=auto to a concrete Bash rule" {
  # Bug: default preset ships PA_TERMINAL_BACKEND=auto. Pre-fix the
  # snippet emitter's case statement didn't handle "auto", emitting an
  # empty backend allow line. Now _pa_emit_settings_snippet resolves
  # auto -> {wezterm|kitty|iterm2|tmux} before the case match.
  run "$PA_ROOT/bin/pa" init --print-settings --non-interactive --preset default \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects"
  [ "$status" -eq 0 ]
  # At least one backend Bash rule must be present beyond the bare pa.sh.
  backend_count=$(echo "$output" | grep -cE '"Bash\((wezterm|kitten|kitty|tmux|osascript):\*\)"')
  [ "$backend_count" -gt 0 ]
}

@test "pa init --print-settings emits bare Bash(pa.sh:*) rule (no absolute path)" {
  # The plugin runtime auto-adds <plugin>/bin to the Bash tool's PATH, so
  # the dispatcher allow rule is stable as a bare command. Absolute-path
  # rules would churn on every reinstall + `pa dev on` toggle.
  run "$PA_ROOT/bin/pa" init --print-settings --non-interactive --preset obsidian-ce \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"Bash(pa.sh:*)"'* ]]
  [[ "$output" != *'Bash(/'* ]]   # no absolute-path Bash rule
}

@test "pa init --non-interactive exits 2 when required vars are missing" {
  # Vault path doesn't exist — required-var validation fires
  run "$PA_ROOT/bin/pa" init --non-interactive \
    --set "PA_VAULT=/nonexistent/$$" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a directory"* ]] || [[ "$output" == *"is required"* ]]
}

@test "pa init rejects value with command substitution metachar" {
  # With the validate_assignments funnel in place, --non-interactive
  # mode now rejects $(...) values uniformly with the interactive path.
  # Pre-refactor this slipped through; post-refactor it exits 2.
  run "$PA_ROOT/bin/pa" init --non-interactive --preset obsidian-ce \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects" \
    --set 'PA_MAIN_TITLE=$(whoami)'
  [ "$status" -eq 2 ]
  [[ "$output" == *"validation failed"* ]] || [[ "$output" == *"refusing to write"* ]]
}

# ─── Phase 3-7 additions ───────────────────────────────────────────────────

@test "pa init --preset NOSUCH exits 2 with available list" {
  run "$PA_ROOT/bin/pa" init --non-interactive --preset NOSUCH \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects"
  [ "$status" -eq 2 ]
  [[ "$output" == *"preset"* ]] && [[ "$output" == *"NOSUCH"* ]]
  [[ "$output" == *"available presets"* ]]
  [[ "$output" == *"obsidian-ce"* ]]
  [[ "$output" == *"default"* ]]
}

@test "pa init writes config with mode 600" {
  "$PA_ROOT/bin/pa" init --non-interactive --preset obsidian-ce \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects" \
    --set "PA_TERMINAL_BACKEND=tmux" >/dev/null
  local mode
  # BSD stat (macOS) and GNU stat take different flags; handle both.
  if mode=$(stat -f '%Lp' "$XDG_CONFIG_HOME/claude-pa/config.sh" 2>/dev/null); then :
  else mode=$(stat -c '%a' "$XDG_CONFIG_HOME/claude-pa/config.sh")
  fi
  [ "$mode" = "600" ]
}

@test "pa init --preset default --non-interactive writes config sourcing cleanly" {
  run "$PA_ROOT/bin/pa" init --non-interactive --preset default \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects" \
    --set "PA_TERMINAL_BACKEND=tmux"
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/claude-pa/config.sh" ]
  # Default preset's status taxonomy includes in-review (obsidian-ce's does too)
  grep -q "in-review" "$XDG_CONFIG_HOME/claude-pa/config.sh"
}

@test "pa init --non-interactive without --set PA_VAULT exits 2 with explicit error" {
  # Use --preset default (which intentionally omits PA_VAULT) so the
  # required-key check actually fires. obsidian-ce preset bakes its own
  # PA_VAULT, so this scenario can't be tested against obsidian-ce.
  run "$PA_ROOT/bin/pa" init --non-interactive --preset default \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects"
  [ "$status" -eq 2 ]
  [[ "$output" == *"PA_VAULT"* ]]
}

@test "pa init re-run merges existing config: Enter through every field keeps current" {
  # First run: write a baseline config.
  "$PA_ROOT/bin/pa" init --non-interactive --preset obsidian-ce \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects" \
    --set "PA_TERMINAL_BACKEND=tmux" \
    --set "PA_MAIN_TITLE=BASELINE-TITLE" >/dev/null
  before=$(cat "$XDG_CONFIG_HOME/claude-pa/config.sh")

  # Re-run interactively with PA_INIT_FORCE_INTERACTIVE=1 + a stream of
  # 20 newlines (more than enough for the 14-field walk). Each Enter
  # accepts the current shell value as the default.
  run env PA_INIT_FORCE_INTERACTIVE=1 \
    bash -c "yes '' | head -20 | '$PA_ROOT/bin/pa' init"
  [ "$status" -eq 0 ]

  after=$(cat "$XDG_CONFIG_HOME/claude-pa/config.sh")
  # Strip the date-stamped header (line 1 changes between writes) for
  # the equality check.
  before_body=$(echo "$before" | tail -n +2)
  after_body=$(echo "$after" | tail -n +2)
  [ "$before_body" = "$after_body" ]
}

@test "pa init re-run merges existing config: typed value overrides one field" {
  "$PA_ROOT/bin/pa" init --non-interactive --preset obsidian-ce \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects" \
    --set "PA_TERMINAL_BACKEND=tmux" \
    --set "PA_MAIN_TITLE=BEFORE" >/dev/null

  # PA_VAULT (1st prompt), PA_PROJECTS_DIR (2nd), PA_TERMINAL_BACKEND
  # (3rd), PA_MAIN_TITLE (4th). Keep first three, override 4th, keep rest.
  run env PA_INIT_FORCE_INTERACTIVE=1 \
    bash -c "printf '\n\n\nAFTER\n\n\n\n\n\n\n\n\n\n\n' | '$PA_ROOT/bin/pa' init"
  [ "$status" -eq 0 ]

  source "$XDG_CONFIG_HOME/claude-pa/config.sh"
  [ "$PA_VAULT" = "$TMPHOME/vault" ]
  [ "$PA_MAIN_TITLE" = "AFTER" ]
}

@test "pa init --non-interactive on existing config still overwrites without prompts" {
  "$PA_ROOT/bin/pa" init --non-interactive --preset obsidian-ce \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects" \
    --set "PA_TERMINAL_BACKEND=tmux" >/dev/null
  run "$PA_ROOT/bin/pa" init --non-interactive --preset obsidian-ce \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects" \
    --set "PA_TERMINAL_BACKEND=tmux"
  [ "$status" -eq 0 ]
}

@test "pa init --wizard --non-interactive with obsidian-ce preset matches v1 baseline" {
  # --wizard wired on top of the existing --non-interactive path. Same
  # result as bare --non-interactive (which now defaults to auto mode
  # but with --set the auto-detect doesn't run for required keys).
  run "$PA_ROOT/bin/pa" init --wizard --non-interactive --preset obsidian-ce \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects" \
    --set "PA_TERMINAL_BACKEND=tmux"
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/claude-pa/config.sh" ]
}

@test "pa init auto-detect: upward walk from CWD finds .obsidian ancestor" {
  # Build a fake vault under $TMPHOME and run pa init from a subdir of it.
  # PA_INIT_CWD_OVERRIDE simulates the user `cd`-ing into the vault before
  # invoking pa init — the upward walker should match before the broad
  # scan even starts.
  mkdir -p "$TMPHOME/Notes/MyVault/.obsidian" "$TMPHOME/Notes/MyVault/Daily" \
           "$TMPHOME/Notes/MyVault/sub/dir"
  run env PA_INIT_HOMEDIR_OVERRIDE="$TMPHOME" \
          PA_INIT_CWD_OVERRIDE="$TMPHOME/Notes/MyVault/sub/dir" \
          PA_INIT_NO_TCC_PROMPT=1 \
          PA_ALLOW_EXTERNAL=1 \
    "$PA_ROOT/bin/pa" init --non-interactive \
      --set "PA_PROJECTS_DIR=$TMPHOME/projects" \
      --set "PA_TERMINAL_BACKEND=tmux"
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/claude-pa/config.sh" ]
  grep -q "PA_VAULT=.*Notes/MyVault" "$XDG_CONFIG_HOME/claude-pa/config.sh"
}
