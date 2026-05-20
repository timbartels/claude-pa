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

## Development

```bash
git clone git@github.com:timbartels/claude-pa.git ~/Projects/claude-pa
cd ~/Projects/claude-pa
./scripts/dev-shell.sh   # launches Claude with --plugin-dir + dev config + test vault
```

See `CONTRIBUTING.md` (Phase 8) for full dev setup.

## License

- Plugin code: MIT (see `LICENSE`)
- Community-contributed presets in `presets/`: CC BY-SA 4.0 (see `presets/LICENSE`)
