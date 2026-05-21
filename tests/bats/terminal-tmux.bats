#!/usr/bin/env bats
# tests/bats/terminal-tmux.bats — smoke tests for lib/terminal/tmux.sh.
#
# Run with: bats tests/bats/terminal-tmux.bats
# Requires: bats-core 1.10+ (brew install bats-core / apt install bats),
#           tmux >= 3.0.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/terminal/tmux.sh"
  export PA_TEST_SESSION="pa-test-$$"
  # Headless CI (GHA Ubuntu) doesn't have a writable XDG_RUNTIME_DIR by
  # default — tmux fails to create its socket and every subsequent test
  # hits "backend unavailable". Force tmux into a writable tmpdir we own,
  # and unset TMUX so we never accidentally nest into an outer session.
  export TMUX_TMPDIR="${TMUX_TMPDIR:-${TMPHOME:-${RUNNER_TEMP:-/tmp}}/tmux-bats-$$}"
  mkdir -p "$TMUX_TMPDIR"
  chmod 700 "$TMUX_TMPDIR"
  unset TMUX
  # Ensure a tmux server exists with a known session for predictable state.
  # Don't swallow the error — if tmux can't start, every downstream test
  # will fail anyway and the actual diagnostic is more useful than 13×
  # "backend unavailable" lines.
  tmux new-session -d -s "$PA_TEST_SESSION"
}

teardown() {
  # Kill the test session and any panes we spawned. Other sessions untouched.
  tmux kill-session -t "$PA_TEST_SESSION" 2>/dev/null || true
  # Also kill the server itself so subsequent tests start clean and the
  # TMUX_TMPDIR can be removed without leaving orphan sockets.
  tmux kill-server 2>/dev/null || true
  if [[ -n "${TMUX_TMPDIR:-}" && -d "$TMUX_TMPDIR" && "$TMUX_TMPDIR" == *"tmux-bats-$$"* ]]; then
    rm -rf "$TMUX_TMPDIR"
  fi
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
  # Confirm via tmux directly. terminal_set_title wraps the raw tag as
  # `[PA:<tag>]` (see lib/terminal/tmux.sh:79) so the window-raise
  # backend can recognise PA-owned panes; assert the wrapped form.
  win_name=$(tmux display-message -p -t "$pane" '#{window_name}')
  [ "$win_name" = "[PA:pa-bats-tag]" ]
  terminal_kill "$pane"
}

@test "terminal_activate succeeds on a live pane" {
  pane=$(terminal_spawn /tmp "sleep 30")
  run terminal_activate "$pane"
  [ "$status" -eq 0 ]
  terminal_kill "$pane"
}

@test "terminal_capture returns buffer for a live pane" {
  pane=$(terminal_spawn /tmp "printf hello-bats-capture; sleep 30")
  sleep 0.3
  run terminal_capture "$pane"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello-bats-capture"* ]]
  terminal_kill "$pane"
}

@test "terminal_send to a gone pane exits 3" {
  pane=$(terminal_spawn /tmp "sleep 30")
  terminal_kill "$pane"
  run terminal_send "$pane" "x"
  [ "$status" -eq 3 ]
}

@test "terminal_set_title on a gone pane exits 3" {
  pane=$(terminal_spawn /tmp "sleep 30")
  terminal_kill "$pane"
  run terminal_set_title "$pane" "should-fail"
  [ "$status" -eq 3 ]
}

@test "terminal_activate on a gone pane exits 3" {
  pane=$(terminal_spawn /tmp "sleep 30")
  terminal_kill "$pane"
  run terminal_activate "$pane"
  [ "$status" -eq 3 ]
}
