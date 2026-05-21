# Contributing to claude-pa

Welcome. This document covers what you need to know before opening a PR.

## Dev setup

```bash
git clone git@github.com:timbartels/claude-pa.git ~/Projects/claude-pa
cd ~/Projects/claude-pa
ln -s "$PWD/bin/pa" ~/.local/bin/pa     # one-time
pa dev on                                # next `pa` runs use this checkout
```

`pa dev status` confirms the active path. `pa dev off` returns to the marketplace install. Worktrees work too — see `README.md` § Parallel branches.

## Running tests + lint

```bash
# Python (42 tests, ~90ms)
pytest tests/pytest

# Bash (23 tests, ~10s — uses a real tmux server)
bats tests/bats/

# End-to-end smoke (≈30s — fake-vault install → doctor → hooks → uninstall)
scripts/smoke-test.sh

# Shellcheck (SC2086 + SC2046 promoted to errors in CI)
shellcheck -S error -e SC1090,SC1091,SC2148 \
  bin/pa bin/pa.sh hooks/scripts/*.sh \
  lib/paths.sh lib/wizard.sh \
  lib/terminal/*.sh lib/window-raise/*.sh \
  scripts/*.sh tests/ci/*.sh

# Ruff (configured in pyproject.toml)
ruff check lib/ tests/

# Manifest + preset structure
python3 tests/ci/validate-manifest.py
tests/ci/validate-preset.sh --all
```

CI runs every check on `macos-latest` + `ubuntu-latest`. PRs that don't pass locally will fail there too.

## Submitting a preset

Layout under `presets/<name>/`:

```
config.env            # strict KEY=VALUE — never sourced as bash
SKILL.md              # personal-assistant skill body for this preset
daily-template.md     # daily-note template the routine copies each morning
README.md             # target audience, required deps, design notes
```

All four files required. See `presets/README.md` for the full security model — `config.env` is parsed by `lib/pa/preset_loader.py`, which rejects `$(…)`, `` ` ``, `${VAR}`, escape sequences, and bare metacharacters. The preset validator (`tests/ci/validate-preset.sh`) enforces structure + scans `SKILL.md` for `curl|wget|eval|source|pipe-to-shell` in fenced bash blocks.

Before opening the PR:

1. `python3 -m pa.preset_loader presets/<name>` — confirm output matches what you intended.
2. `tests/ci/validate-preset.sh presets/<name>` — exits 0.
3. PR checklist: license agreement (CC BY-SA 4.0 — see `presets/LICENSE`), README declares target audience + dependencies, `config.env` only uses allowlisted PA_* keys.

The maintainer reads every preset PR before merge. Expect 1–2 weeks turnaround until external review capacity grows.

## Adding a terminal backend

Backends live in `lib/terminal/<name>.sh` and must implement the 9-function contract documented in `lib/terminal/_interface.sh`. Exit codes are part of the contract — 0 success, 1 transient, 2 backend unavailable, 3 pane gone. The dispatcher checks them.

When adding one:

1. Implement every function — `terminal_health` first so `pa doctor` can probe.
2. Add a smoke `bats` suite at `tests/bats/terminal-<name>.bats`. Use `tests/bats/terminal-tmux.bats` as the template.
3. If the backend needs headless CI (most don't — wezterm/kitty are flaky in CI per the plan's deepening review), add the install script under `tests/ci/install-<name>.sh` and wire it into `.github/workflows/ci.yml`. Default for v0.1: native backends are manual QA only on macOS; tmux is the only backend in CI matrix.
4. Update the wizard's terminal-backend allowlist in `lib/paths.sh` and `lib/pa/paths.py` (`_VALID_BACKENDS`).
5. Update the README's terminal-backend matrix.

## Code style

### Bash

- `set -euo pipefail` at the top of every script.
- `[[ ]]` over `[ ]` (we already require bash 4+ at runtime; portability isn't a constraint).
- Source-only libraries (`lib/**/*.sh`) have no shebang. The CI's shellcheck invocation passes `-e SC2148` for them.
- Quote everything that could contain spaces or shell metacharacters. shellcheck SC2086 + SC2046 are promoted to errors.
- Functions named `_pa_*` are private — prefer them for internal helpers so they don't collide with future user shell aliases.

### Python

- Modules in `lib/pa/` are importable; tests import them directly rather than subprocessing.
- Hook scripts in `hooks/scripts/` are 5-line shims that import the corresponding `lib/pa/` module and call `main()`.
- Type hints encouraged (we run `from __future__ import annotations` so they're deferred at runtime).
- Ruff rules: `E,W,F,I,B,UP,RUF,SIM,PTH,RET,TC`. See `pyproject.toml` for the active ignore list.

### Commit messages

[Conventional Commits](https://www.conventionalcommits.org/) style with these scopes:

- `feat(<area>):` new functionality (`feat(wizard): …`, `feat(phase-7): …`)
- `fix(<area>):` bug fix
- `test(<area>):` tests / CI
- `docs(<area>):` documentation only
- `refactor(<area>):` code reorg without behavior change
- `chore(<area>):` housekeeping (gitignore, dependency bumps)

PR descriptions follow the project convention: `## Summary` with bullets. No tool-attribution footers, no test-plan checkboxes in the PR body itself (tests live in the diff).

## What not to PR

- Removing the `tim` preset or adding "this is the way" opinions to the generic core. The generic core stays opinion-free; opinions belong in presets.
- Adding the `mcp` Python package as a runtime dep. The MCP server is stdlib-only by design — keeps the install footprint zero outside the plugin payload.
- Replacing the strict preset parser (`lib/pa/preset_loader.py`) with `source` for any reason. Presets are a third-party-contributable surface; sourcing them is supply-chain compromise waiting to happen.
- Telemetry, opt-in metrics, "phone home" features. Vault contents stay local — that's the privacy contract.

## Code of Conduct

Contributor Covenant v2.1 — see `CODE_OF_CONDUCT.md`. Maintainer (Tim) enforces.

## License

By contributing code to this repository, you agree it ships under MIT (see `LICENSE`). By contributing a preset under `presets/`, you agree it ships under CC BY-SA 4.0 (see `presets/LICENSE`). The PR template includes a checkbox confirming this for preset contributions.
