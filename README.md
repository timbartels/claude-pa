# claude-pa

Personal assistant for Obsidian-style vault management as a Claude Code plugin. Daily-note creation + carry-over, multi-pane terminal orchestration, cross-pane state IPC, live dashboard, end-of-day commit wrap, same-day session resume.

<!-- badges (real CI / version / license badges land at v0.1.0 release) -->
[![ci](https://img.shields.io/badge/ci-pending-lightgrey)](.github/workflows/ci.yml)
[![version](https://img.shields.io/badge/version-0.1.0-blue)](.claude-plugin/plugin.json)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## Status

v0.1.0 — first public release. Tim's own daily driver. Production-grade for his vault layout; friends should expect rough edges on first install and report them.

## Requirements

- **Claude Code v2.1.141+** (plugin marketplace + namespaced skills + `hooks/hooks.json`).
- **macOS or Linux.** Windows / PowerShell deferred to v0.3+.
- **bash 4+.** macOS ships `/bin/bash` 3.2 — run `brew install bash` and ensure `/opt/homebrew/bin` is ahead of `/usr/bin` on PATH. The wizard and launcher are 3.2-compatible, but `pa doctor` flags this as a failure because the dispatcher relies on a few bash-4 idioms.
- **python 3.10+** (`/usr/bin/python3` on modern macOS, `apt install python3` on Linux).
- **Terminal backend** — one of:

  | Backend  | Native? | Notes                                                                 |
  |----------|---------|-----------------------------------------------------------------------|
  | WezTerm  | yes     | Full multi-pane orchestration + dashboard split. Tim's daily driver.  |
  | Kitty    | yes     | `kitten @` remote control; needs `allow_remote_control yes` in config.|
  | iTerm2   | yes     | macOS only. Manual QA per CONTRIBUTING.md (auth prompt on first run). |
  | tmux 3.0+| fallback | Universal — covers Terminal.app, Ghostty, gnome-terminal, etc.       |

## Install

```
/plugin marketplace add timbartels/claude-pa
/plugin install claude-pa@claude-pa
pa init
```

`pa init` walks you through configuration: terminal backend (auto-detected), preset selection, vault + projects paths, then prints the `~/.claude/settings.json` allow-rules snippet for manual paste. Re-run any time to tweak.

## Quick start

```
pa init       # interactive wizard
pa doctor     # confirm green
pa            # bare launch — opens orchestrator session in your current terminal
```

Inside the session, the personal-assistant skill auto-runs the morning routine. Spawn project panes during the day with `/claude-pa:spawn <repo>`; end the day with `/claude-pa:wrap`.

## Slash commands

Auto-discovered by Claude Code from `commands/`:

- `/claude-pa:morning` — daily-note carry-over + PR enrichment + agenda question
- `/claude-pa:wrap` — EOD commit summary + feature-note reconciliation + pane shutdown
- `/claude-pa:spawn <repo> [<prompt>]` — open or activate a project pane
- `/claude-pa:peek [<repo>]` — cross-pane state read
- `/claude-pa:status [<filter>]` — feature notes by status

## MCP server

The plugin registers an MCP stdio server (`pa.mcp_server`) exposing five tools — `peek_pane`, `list_panes`, `aggregate_todos`, `current_state`, `dispatch_to_pane`. Schema-validated; lets Claude drive PA without shell-parsing pa.sh output.

## Presets

`presets/tim/` ships in v0.1 — full Obsidian (iCloud MyVault) + Compound Engineering workflow flavor. Pick it at `pa init`, or "start fresh" to answer every question. New presets are welcome via PR — see `presets/README.md`.

## Privacy + data handling

- **All state local-only.** No network telemetry, no analytics, no opt-in metrics in v0.1.
- **Vault contents never sent remotely.** Any future remote feature would require an explicit opt-in + documented data flow.
- **State files** under `$XDG_DATA_HOME/claude-pa/state/` may contain prompt text + daily-note excerpts. Stored with mode 0600; the data dir is 0700.
- **`pa uninstall`** wipes config + (optionally) data. The vault itself is never touched.

## Known limitations (v0.1)

- **Windows** — deferred to v0.3+. Architecture differs significantly.
- **iTerm2** — macOS-only and manual QA only in CI (Python lib auth prompt blocks scripted runs).
- **Dashboard split** — `pa.sh dashboard` is wezterm-only because `split-pane` semantics diverge across backends. `pa.sh watch` works everywhere; non-wezterm users open a sibling pane manually.
- **Dev-mode SKILL.md mutation** — `pa init` substitutes `{{PA_*}}` placeholders in `skills/personal-assistant/SKILL.md` in place. In a `pa dev on` checkout, that mutates your working tree — `git checkout -- skills/personal-assistant/SKILL.md` after testing.
- **bash 3.2 on macOS** — `pa doctor` reports `✗ bash >= 4` until you `brew install bash` and re-order PATH.
- **Screen-reader accessibility** — the live dashboard is ANSI-heavy with rapid in-place updates; screen-reader hostile. `pa init` / `pa doctor` output stays linear and append-only.

## Developing

The launcher (`bin/pa`) supports a `dev` toggle that swaps between the marketplace-installed plugin and a local checkout. Same vault, state, and config — only the code path changes.

### One-time setup

```bash
git clone git@github.com:timbartels/claude-pa.git ~/Projects/claude-pa
ln -s ~/Projects/claude-pa/bin/pa ~/.local/bin/pa
```

### The `dev` toggle

```bash
pa dev on              # use ~/Projects/claude-pa/ for the next pa launches
pa dev on /alt/path    # use a different checkout (e.g. a worktree)
pa dev off             # back to the marketplace install
pa dev status          # show current mode + active path
```

`pa dev on` writes `$XDG_CONFIG_HOME/claude-pa/dev-path` (0600). When present, `pa` launches `claude --plugin-dir $(cat dev-path)` instead of vanilla `claude`. Persists across shells and reboots.

### Iteration loop

```bash
pa dev on
$EDITOR ~/Projects/claude-pa/bin/pa.sh
pa                     # next launch picks up the edit (no reinstall)
                       # hook changes need a fresh claude session to re-register
pa dev off
```

### Safety net

`pa dev on` snapshots `~/.local/share/claude-pa/learnings.md` to `.learnings.bak-<timestamp>` before swapping — the only irreplaceable file. State, vault, and config are shared between dev and prod; broken dev code can write garbage to either. Iterate carefully; restore from snapshot if learnings get mangled.

### Parallel branches via git worktree

```bash
git -C ~/Projects/claude-pa worktree add ../claude-pa-feat my-feature
pa dev on ~/Projects/claude-pa-feat
```

Each worktree is a self-contained plugin checkout.

### Tests + lint

```bash
pytest tests/pytest          # 42 tests covering paths / preset_loader / state_update / mcp_server / aggregate_todos
bats tests/bats/             # 23 tests: terminal-tmux + pa-init + pa-doctor
scripts/smoke-test.sh        # end-to-end install simulation
shellcheck -S error bin/pa bin/pa.sh hooks/scripts/*.sh lib/**/*.sh
ruff check lib/ tests/
```

CI runs everything on macOS + Ubuntu. See `.github/workflows/ci.yml` and `CONTRIBUTING.md` for details.

## License

- Plugin code: MIT (see `LICENSE`)
- Community-contributed presets in `presets/`: CC BY-SA 4.0 (see `presets/LICENSE`)
