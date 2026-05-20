# claude-pa

Personal assistant for Obsidian-style vault management as a Claude Code plugin.

Daily-note creation + carry-over, multi-pane terminal orchestration, cross-pane state IPC, live dashboard, end-of-day commit wrap, same-day session resume.

## Status

Pre-release. v0.0.0-scaffold — repository structure only. No functional code yet. See the implementation plan for phased rollout to v0.1.0.

## Requirements

- Claude Code **v2.1.141** or newer (plugin marketplace + namespaced skills + `hooks/hooks.json`)
- macOS or Linux (Windows / PowerShell deferred to v0.3+)
- bash 4+ (`brew install bash` on macOS), python 3.10+
- Terminal: one of WezTerm, Kitty, iTerm2 (with vendored Python lib), or tmux 3.0+ as universal fallback

## Install (placeholder — not yet published)

```
/plugin marketplace add timbartels/claude-pa
/plugin install claude-pa@claude-pa
pa init
```

## Quick start

Once installed:

```
pa init      # interactive wizard; configures vault path, terminal backend, preset
pa doctor    # verify everything works
pa           # start the assistant in your current terminal
```

## Developers

The launcher (`bin/pa`) supports a `dev` toggle so you can swap between the marketplace-installed plugin and a local checkout in your normal flow. Same vault, same state, same config — only the code path changes.

### One-time setup

```bash
git clone git@github.com:timbartels/claude-pa.git ~/Projects/claude-pa
```

Make the launcher reachable from anywhere. Either symlink:

```bash
ln -s ~/Projects/claude-pa/bin/pa ~/.local/bin/pa
```

Or alias it (while the marketplace version isn't installed yet):

```bash
echo 'alias pa=~/Projects/claude-pa/bin/pa' >> ~/.zshrc
```

### The `dev` toggle

```bash
pa dev on              # use local ~/Projects/claude-pa/ for next `pa` runs
pa dev on /alt/path    # use a different local checkout (e.g. a worktree)
pa dev off             # back to the marketplace install
pa dev status          # show current mode + active path
```

Internally `pa` writes `$XDG_CONFIG_HOME/claude-pa/dev-path` and, when present, launches `claude --plugin-dir $(cat dev-path)` instead of vanilla `claude`. The toggle persists across shells and reboots.

### Iteration loop

```bash
pa dev on              # switch to local checkout

# in another terminal, edit code:
$EDITOR ~/Projects/claude-pa/bin/pa.sh

pa                     # next launch picks up the edit (no reinstall)
# hook changes need a fresh claude session to re-register

# happy with changes?
cd ~/Projects/claude-pa
git add -p && git commit -m "feat(scope): ..."
git push

pa dev off             # back to marketplace version
```

### Safety net

`pa dev on` snapshots `~/.local/share/claude-pa/learnings.md` to `.learnings.bak-<timestamp>` before swapping (the only irreplaceable file — state files are transient and rebuild themselves). State, vault, and config are shared between dev and prod; broken dev code can write garbage to either. Iterate carefully; restore from snapshot if learnings get mangled.

### Parallel branches via worktree

```bash
git -C ~/Projects/claude-pa worktree add ../claude-pa-feat my-feature
pa dev on ~/Projects/claude-pa-feat
```

Each worktree is a self-contained plugin checkout. Switch branches by switching the `pa dev on <path>` target.

See `CONTRIBUTING.md` (Phase 8 of the implementation plan) for tests, lint, and PR guidelines.

## License

- Plugin code: MIT (see `LICENSE`)
- Community-contributed presets in `presets/`: CC BY-SA 4.0 (see `presets/LICENSE`)
