#!/usr/bin/env bats
# tests/bats/pa-doctor.bats — covers `pa doctor` health checks.

setup() {
  PA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export PA_ROOT
  export TMPHOME="$(mktemp -d)"
  export XDG_CONFIG_HOME="$TMPHOME/xdg-config"
  export XDG_DATA_HOME="$TMPHOME/xdg-data"
  mkdir -p "$TMPHOME/vault/_templates" "$TMPHOME/projects"
  touch "$TMPHOME/vault/_templates/Daily Note.md"
}

teardown() {
  rm -rf "$TMPHOME"
  git -C "$PA_ROOT" checkout -- skills/personal-assistant/SKILL.md 2>/dev/null || true
}

_init_clean() {
  "$PA_ROOT/bin/pa" init --non-interactive --preset tim \
    --set "PA_VAULT=$TMPHOME/vault" \
    --set "PA_PROJECTS_DIR=$TMPHOME/projects" \
    --set "PA_TERMINAL_BACKEND=tmux" >/dev/null
}

@test "pa doctor without config fails fast" {
  run "$PA_ROOT/bin/pa" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"config missing"* ]] || [[ "$output" == *"missing — run"* ]]
}

@test "pa doctor on clean install reports no FAIL checks (besides system bash)" {
  _init_clean
  run "$PA_ROOT/bin/pa" doctor
  # exit may be 1 if /bin/bash is 3.2 on the runner — that's a documented
  # legitimate failure (`bash >= 4`). Allow either 0 (everything green) or
  # exactly one bash-version failure.
  if [ "$status" -ne 0 ]; then
    [[ "$output" == *"bash >= 4"* ]] || [[ "$output" == *"bash"* ]]
  fi
  [[ "$output" == *"✓ Claude Code version"* ]] || [[ "$output" == *"Claude Code version"* ]]
  [[ "$output" == *"✓ config.sh"* ]] || [[ "$output" == *"config.sh"* ]]
}

@test "pa doctor --json emits parseable structured output" {
  _init_clean
  run "$PA_ROOT/bin/pa" doctor --json
  # Status may be 1 on bash 3.2 systems; either way stdout must be JSON.
  echo "$output" | python3 -m json.tool >/dev/null
}

@test "pa doctor --json reports ok=false when config is missing" {
  run "$PA_ROOT/bin/pa" doctor --json
  [ "$status" -eq 1 ]
  ok=$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])')
  [ "$ok" = "False" ]
}

@test "pa doctor catches a deleted PA_VAULT" {
  _init_clean
  rm -rf "$TMPHOME/vault"
  run "$PA_ROOT/bin/pa" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"PA_VAULT directory"* ]]
  [[ "$output" == *"not a directory"* ]] || [[ "$output" == *"✗"* ]]
}
