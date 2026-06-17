# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.3] — 2026-06-17

State-file hygiene fix for panes that exit without firing `SessionEnd`.

### Fixed

- **Prune ghost state files from dead panes.** Hard-killed panes (`pa.sh kill`/`shutdown`, terminal close, crash, reboot) never fire `SessionEnd`, so their per-repo state JSON was never unlinked and lingered as a phantom "active" row in `peek-all`, the live dashboard, and the todo roll-up. The readers now unlink any state file whose recorded `pane_id` is gone from the live pane list (`peek-all` and the dashboard delete; the todo roll-up skips). Pruning is guarded — it only runs when the live listing is non-empty, so a transient backend outage can't delete every state file, and null-`pane_id` files are kept. `live_pane_ids()` is now backend-aware (tmux `%N` ids vs wezterm numeric) via `PA_TERMINAL_BACKEND` instead of being wezterm-hardcoded.

## [0.2.2] — 2026-06-01

Default behaviour shift in the `personal-assistant` skill for project-scoped task handoff.

### Changed

- **Auto-spawn project panes on handoff.** When a user names a project-scoped task ("work on X in repo Y", "fix Z", any CE workflow targeting a repo), the skill now spawns the project pane automatically via `pa.sh spawn <repo> "<prompt>"` instead of telling the user to switch panes. Previous default ("do NOT spawn a new pane unless the user explicitly asked") flipped — orchestrator-only execution silently polluted context and hid task progress from `pa.sh peek-all`. Documented exceptions for trivial single-line edits, cross-repo summaries, and meta-work on the orchestrator itself.

## [0.2.1] — 2026-05-29

Dashboard reliability + PR-filter follow-ups landed on top of 0.2.0.

### Added

- `PA_WORK_ORGS` env var support — filter PR-status lists in dashboard + morning routine to specific GitHub orgs (e.g. `PA_WORK_ORGS="your-org"`). Defaults empty (no filter). Plumbed via `lib/paths.sh` export so the dashboard Python subprocess sees it.

### Fixed

- Dashboard self-labels its WezTerm tab via OSC 2 escape sequence on every render, stopping `pa.sh focus` from clobbering the dashboard tab title.
- Dashboard liveness check watches the live `watch` loop process rather than just the pane state — fixes false-positive "dead" reads when a pane exists but its watcher has crashed.
- Dashboard state glob skips `vault-session-*.json` files so stale vault-session checkpoints don't render as ghost `● ?` project rows.

## [0.2.0] — 2026-05-22

`pa init` three-mode refactor + four follow-ups + verification bugfixes.

### Added

- `pa init` three modes selectable via flags. Default mode (no flags) auto-detects vault + projects-dir + backend; confirms with a source-labelled block; writes. `--wizard` walks every field with the previous-style default chain. `--preset NAME` is preset-only; `--preset NAME` is validated against `presets/<name>/` before any other work fires.
- `pa shell-init <shell>` subcommand emits an eval-style PATH snippet for bash / zsh / fish. Auto-detects from `$SHELL`; falls back to bash on empty.
- `presets/default/config.env` (config-only preset) ships PARA-light vault-org defaults the wizard consumes as the fallback layer when auto-detect can't resolve.
- `lib/_backend_detect.sh` — single source of truth for terminal backend detection. Replaces 3 inlined copies in `lib/paths.sh`, `pa_doctor`, and the wizard.
- `lib/pa/paths.py::validate_assignments` — strict allowlist + regex + semantic validator. Every resolved value pipes through it before write regardless of mode (closes a `--non-interactive` injection gap that previously let `$(...)` slip into the sourced config).
- Atomic config write: same-directory `mktemp` → `chmod 600` → atomic `mv`. `trap` on `EXIT/INT/TERM` removes any in-flight tmpfile. `flock` on `$CONFIG_DIR/.init.lock` serializes concurrent `pa init` runs.
- Launcher symlink offer: post-write offer for `~/.local/bin/pa`. Nix-managed `~/.local/bin` short-circuits. `--force-symlink` repoints an existing symlink atomically; refuses to clobber regular files regardless of flag.
- `docs/bridge-from-legacy.md` — doc-only migration guide for users coming from the pre-plugin `~/.claude/pa/` layout.
- Upward-walk vault detection (`_pa_walk_upward_for_vault`) from `$CWD` looking for `.obsidian/`. Runs before the iCloud / `~/Documents` / `~/Obsidian` broad scan.
- aws configure-style per-field merge on re-run. Existing config + interactive `pa init` sources the file, switches to wizard mode, and walks every field with the current value as the default. Enter keeps, type to change, Ctrl-C aborts. Preset auto-load is skipped (`merge_existing` flag) so user values aren't shadowed.

### Changed

- Settings allow-rule snippet now uses bare `Bash(pa.sh:*)` instead of an absolute path. The plugin runtime auto-adds the plugin's `bin/` to the Bash tool's `$PATH`; bare form stays stable across marketplace reinstalls and `pa dev on` toggles.
- `_pa_emit_settings_snippet` resolves `PA_TERMINAL_BACKEND=auto` to a concrete backend at emit time via `_pa_resolve_backend` — previously the snippet's case statement missed `auto`, leaving the backend allow line empty.
- `pa doctor` settings.json detection accepts either bare `Bash(pa.sh:*)` or the legacy absolute-path form.
- TTY auto-promotion: `pa init` with non-TTY stdin implicitly behaves like `--non-interactive` (matches `gh auth login`).
- `tests/bats/pa-init.bats` setup unsets PA_* env that may leak from a developer's parent shell.

### Removed

- `lib/wizard.sh::_PA_DEFAULTS_*` constants and `_pa_default_for()` helper. `presets/default/config.env` is now the single source of truth for wizard-time vault-org defaults. CI guard at `tests/ci/check-no-deprecated-symbols.sh` fails the build on regression.

### Security

- `_FORBIDDEN_SUBSTRINGS` + the strict assignment regex moved DOWN into `lib/pa/paths.py`. `lib/pa/preset_loader.py` imports them (preserving the existing `preset_loader → paths` import direction). Single source of truth.
- Defence-in-depth: `lib/pa/paths.py::_parse_file` now applies `_FORBIDDEN_SUBSTRINGS` against the bash-sourced user config too.
- Auto-detected vault paths flow through `_pa_resolve_safe` — rejects symlink targets outside `$HOME` unless `PA_ALLOW_EXTERNAL=1`.
- Backend detection emits one of four literal strings (`wezterm`/`kitty`/`iterm2`/`tmux`), never verbatim env content.

### Fixed

- `bin/pa.sh` + `hooks/scripts/mark-main-pane.sh` resolve `$0` via `realpath` so symlinked launchers (`~/.local/bin/pa` → plugin install) find `$PA_LIB` inside the actual plugin tree.

## [0.1.0] — 2026-05-21

First public release. Extracts the personal-assistant daily driver from `~/.claude/pa/` into a Claude Code plugin installable via the marketplace.

### Added

- Plugin scaffolding: `.claude-plugin/{plugin,marketplace}.json`, `userConfig` for `PA_VAULT` + `PA_PROJECTS_DIR`, MIT license at root, CC BY-SA 4.0 for `presets/`.
- Config layer: every personal value flows through `PA_*` vars in `$XDG_CONFIG_HOME/claude-pa/config.sh`. Bash loader at `lib/paths.sh`, Python loader at `lib/pa/paths.py` with strict KEY=VALUE allowlist parser.
- Terminal backend abstraction at `lib/terminal/` with 9-function contract — WezTerm + Kitty + iTerm2 native plus tmux universal fallback. Window-raise helper at `lib/window-raise/` covers macOS (AppleScript) + Linux (wmctrl / xdotool).
- Dispatcher (`bin/pa.sh`, 19 subcommands) routes every terminal op through the abstraction. Dashboard split stays wezterm-gated in v0.1.
- Six event hooks registered via `hooks/hooks.json`: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse (matchered to write tools), Stop, SessionEnd. Per-repo state files at `$XDG_DATA_HOME/claude-pa/state/<repo>.json`.
- Wizard subcommands: `pa init` (interactive + `--non-interactive` + `--print-settings`), `pa doctor` (6 checks + `--verbose` + `--json`), `pa uninstall` (`--force`).
- Vault-session launcher: `bin/pa` bare invocation auto-orchestrates (cd vault, ensure dashboard, mark main pane, resume same-day or exec slash command).
- Five plugin-namespaced slash commands at `commands/`: `morning`, `wrap`, `spawn`, `peek`, `status`.
- MCP stdio server (`lib/pa/mcp_server.py`) exposing 4 read tools + 1 write tool. Zero runtime deps beyond Python 3.10+ stdlib.
- `--json` machine-readable output on `pa.sh peek-all`, `pa.sh peek`, `pa.sh status`, `pa doctor`.
- `presets/obsidian-ce/` — full Obsidian + Compound Engineering workflow preset (six-stage status taxonomy).
- `pa.sh resume` — post-crash pane recovery via `claude --continue`.
- Test infrastructure: 42 pytest tests, 23 bats tests, manifest + preset validators, end-to-end smoke script.
- CI workflow at `.github/workflows/ci.yml`: lint + python + manifest + bash (macOS + Ubuntu matrix on tmux).

### Security

- Preset files (`presets/<name>/config.env`) parsed by a strict allowlist regex — never sourced as bash. Blocks command substitution, brace expansion, backticks, escape sequences.
- All state files written with mode 0600; data directory 0700. State may contain prompt text + daily-note excerpts.
- No telemetry. No network calls except user-invoked `gh` and `git`.

### Known limitations

- Windows / PowerShell deferred to v0.3+.
- iTerm2 backend tested via manual QA only on macOS (Python lib auth prompt blocks scripted runs).
- Dashboard split (`pa.sh dashboard`) is wezterm-only. `pa.sh watch` works on every backend.
- macOS default `/bin/bash` is 3.2; users must `brew install bash` for `pa doctor` to report all green.

[Unreleased]: https://github.com/timbartels/claude-pa/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/timbartels/claude-pa/releases/tag/v0.1.0
