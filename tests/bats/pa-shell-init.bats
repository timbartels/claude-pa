#!/usr/bin/env bats
# tests/bats/pa-shell-init.bats — covers the `pa shell-init` subcommand.

setup() {
  PA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export PA_ROOT
}

@test "pa shell-init bash emits a PATH-export snippet" {
  run "$PA_ROOT/bin/pa" shell-init bash
  [ "$status" -eq 0 ]
  [[ "$output" == *"export PATH="* ]]
  [[ "$output" == *"$PA_ROOT/bin"* ]]
  [[ "$output" == *'eval "$(pa shell-init bash)"'* ]]
}

@test "pa shell-init zsh emits a PATH-export snippet" {
  run "$PA_ROOT/bin/pa" shell-init zsh
  [ "$status" -eq 0 ]
  [[ "$output" == *"export PATH="* ]]
  [[ "$output" == *"$PA_ROOT/bin"* ]]
}

@test "pa shell-init fish emits fish-flavoured snippet" {
  run "$PA_ROOT/bin/pa" shell-init fish
  [ "$status" -eq 0 ]
  [[ "$output" == *"set -gx PATH"* ]]
  [[ "$output" == *"pa shell-init fish | source"* ]]
}

@test "pa shell-init auto-detects from \$SHELL when arg omitted" {
  run env SHELL=/bin/zsh "$PA_ROOT/bin/pa" shell-init
  [ "$status" -eq 0 ]
  [[ "$output" == *"~/.zshrc"* ]]

  run env SHELL=/usr/local/bin/fish "$PA_ROOT/bin/pa" shell-init
  [ "$status" -eq 0 ]
  [[ "$output" == *"fish"* ]]
  [[ "$output" == *"set -gx PATH"* ]]
}

@test "pa shell-init falls back to bash when \$SHELL is empty" {
  # `env -u SHELL` doesn't actually unset SHELL because bash re-sets it
  # on startup. Empty string is the closest reliable "no SHELL" signal.
  run env SHELL="" "$PA_ROOT/bin/pa" shell-init
  [ "$status" -eq 0 ]
  [[ "$output" == *"~/.bashrc"* ]]
}

@test "pa shell-init rejects unsupported shell with exit 2" {
  run "$PA_ROOT/bin/pa" shell-init powershell
  [ "$status" -eq 2 ]
  [[ "$output" == *"unsupported shell"* ]]
}

@test "pa shell-init bash snippet is no-op when bin already on \$PATH" {
  # The case-statement guards re-adding the same directory; verify the
  # guard is syntactically real by eval-ing the snippet twice.
  snippet=$("$PA_ROOT/bin/pa" shell-init bash)
  PATH_BEFORE="$PATH"
  eval "$snippet"
  PATH_FIRST="$PATH"
  eval "$snippet"
  PATH_SECOND="$PATH"
  [ "$PATH_FIRST" = "$PATH_SECOND" ]
  [[ "$PATH_FIRST" == "$PA_ROOT/bin:"* ]]
  PATH="$PATH_BEFORE"
}
