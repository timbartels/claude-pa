#!/usr/bin/env bats
# tests/bats/terminal-tmux.bats — smoke tests for lib/terminal/tmux.sh.
#
# Run with: bats tests/bats/terminal-tmux.bats
# Requires: bats-core 1.10+ (brew install bats-core / apt install bats),
#           tmux >= 3.0.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/terminal/tmux.sh"
  export PA_TEST_SESSION="pa-test-$$"
  # Ensure a tmux server exists with a known session for predictable state.
  tmux new-session -d -s "$PA_TEST_SESSION" 2>/dev/null || true
}

teardown() {
  # Kill the test session and any panes we spawned. Other sessions untouched.
  tmux kill-session -t "$PA_TEST_SESSION" 2>/dev/null || true
}

@test "terminal_health prints version and exits 0" {
  run terminal_health
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^tmux\  ]]
}

@test "terminal_list returns one line per pane in pane_id|cwd|title format" {
  run terminal_list
  [ "$status" -eq 0 ]
  # Each line should match %N|<path>|<name>
  while IFS= read -r line; do
    [[ "$line" =~ ^%[0-9]+\|/.+\|.+ ]]
  done <<<"$output"
}

@test "terminal_spawn returns a valid pane id and the pane appears in list" {
  run terminal_spawn /tmp "sleep 30"
  [ "$status" -eq 0 ]
  pane="$output"
  [[ "$pane" =~ ^%[0-9]+$ ]]
  # Pane shows up in list
  run terminal_list
  [[ "$output" == *"$pane|"* ]]
  # Cleanup
  terminal_kill "$pane"
}

@test "terminal_kill is idempotent (killing dead pane is success)" {
  pane=$(terminal_spawn /tmp "sleep 30")
  run terminal_kill "$pane"
  [ "$status" -eq 0 ]
  run terminal_kill "$pane"
  [ "$status" -eq 0 ]
}

@test "terminal_send rejects malformed pane id with exit 3" {
  run terminal_send "not-a-pane" "hello"
  [ "$status" -eq 3 ]
}

@test "terminal_capture on a gone pane exits 3" {
  pane=$(terminal_spawn /tmp "sleep 30")
  terminal_kill "$pane"
  run terminal_capture "$pane"
  [ "$status" -eq 3 ]
}

@test "terminal_send + terminal_enter accept a live pane" {
  pane=$(terminal_spawn /tmp "cat")  # cat keeps the pane alive, accepts stdin
  sleep 0.2
  run terminal_send "$pane" "hello world"
  [ "$status" -eq 0 ]
  run terminal_enter "$pane"
  [ "$status" -eq 0 ]
  terminal_kill "$pane"
}

@test "terminal_set_title renames the window of the target pane" {
  pane=$(terminal_spawn /tmp "sleep 30")
  run terminal_set_title "$pane" "pa-bats-tag"
  [ "$status" -eq 0 ]
  # Confirm via tmux directly
  win_name=$(tmux display-message -p -t "$pane" '#{window_name}')
  [ "$win_name" = "pa-bats-tag" ]
  terminal_kill "$pane"
}

@test "terminal_activate succeeds on a live pane" {
  pane=$(terminal_spawn /tmp "sleep 30")
  run terminal_activate "$pane"
  [ "$status" -eq 0 ]
  terminal_kill "$pane"
}
