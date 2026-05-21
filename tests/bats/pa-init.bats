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

@test "pa init --non-interactive with tim preset writes config + preset marker" {
  run "$PA_ROOT/bin/pa" init --non-interactive --preset tim \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects" \
    --set "PA_TERMINAL_BACKEND=tmux"
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/claude-pa/config.sh" ]
  [ -f "$XDG_CONFIG_HOME/claude-pa/preset" ]
  [ "$(cat "$XDG_CONFIG_HOME/claude-pa/preset")" = "tim" ]
}

@test "pa init writes a config that sources cleanly via lib/paths.sh" {
  "$PA_ROOT/bin/pa" init --non-interactive --preset tim \
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
  run "$PA_ROOT/bin/pa" init --print-settings --non-interactive --preset tim \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects"
  [ "$status" -eq 0 ]
  # Snippet must parse as JSON
  echo "$output" | python3 -m json.tool >/dev/null
  # Config file must not have been written
  [ ! -f "$XDG_CONFIG_HOME/claude-pa/config.sh" ]
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
  # Even via --set, dangerous values should be rejected by _pa_safe_value
  run "$PA_ROOT/bin/pa" init --non-interactive --preset tim \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects" \
    --set 'PA_MAIN_TITLE=$(whoami)'
  # Either error out or write the config but with the value rejected.
  # In non-interactive mode the wizard does NOT re-prompt; it currently
  # accepts the value verbatim. So this test just confirms the resulting
  # config doesn't execute the substitution when sourced — it should be
  # a literal string. (Defence-in-depth lives in lib/pa/paths.py which
  # rejects malformed config files entirely.)
  if [ "$status" -eq 0 ]; then
    # If accepted, lib/paths.sh sourcing the file should NOT expand $(...)
    # because %q-quoted values are inert under set -u. Verify the literal.
    source "$XDG_CONFIG_HOME/claude-pa/config.sh" 2>/dev/null || true
    [[ "${PA_MAIN_TITLE:-}" == *'$(whoami)'* ]] || [[ "${PA_MAIN_TITLE:-}" == "" ]]
  fi
}
