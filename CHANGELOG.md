# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
- `presets/tim/` — full Obsidian + Compound Engineering workflow preset (six-stage status taxonomy).
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
