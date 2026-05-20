# Bash tests (bats-core)

Smoke tests for `lib/terminal/*.sh` backends and other bash components.

## Running locally

Install bats:

```bash
# macOS
brew install bats-core

# Debian/Ubuntu
sudo apt install bats
```

Run all tests:

```bash
bats tests/bats/
```

Run one file:

```bash
bats tests/bats/terminal-tmux.bats
```

## CI

CI installs bats automatically in `.github/workflows/ci.yml` (Phase 6 of the plan).

## What's covered

| Backend | File | Status |
|---------|------|--------|
| tmux | `terminal-tmux.bats` | full 9-op coverage; happy path + error paths (bad id, gone pane, idempotent kill) |
| wezterm | (TBD) | smoke only — requires running WezTerm GUI; manual QA |
| kitty | (TBD) | requires user kitty.conf with remote control enabled; manual QA |
| iterm2 | (TBD) | macOS-only; manual QA per CONTRIBUTING.md |

Tmux is the universal fallback and the only backend that runs reliably headless in CI. Other backends rely on real terminal GUIs and are exercised via manual QA before each release.
