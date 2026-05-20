# claude-pa presets

A preset is a pre-filled starting point for the `pa init` wizard. Pick one at install time, then tweak any value.

This directory ships with `tim/` in v0.1. Community presets are welcome via PR.

## Layout

```
presets/<name>/
├── config.env          # KEY=VALUE config (strict parser — see security below)
├── SKILL.md            # the personal-assistant skill body for this preset
├── daily-template.md   # the daily-note template the routine copies each morning
└── README.md           # target audience, required deps, design notes
```

All four files are required. The validator at `tests/ci/validate-preset.sh` rejects PRs missing any of them.

## Security posture

**`config.env` is NEVER `source`d.** It is parsed by `lib/pa/preset_loader.py` with a strict allowlist:

- Keys must match the PA_* allowlist used by the user's main config (`lib/pa/paths.py:_ALLOWED_KEYS`).
- Values are either bare ASCII path tokens (`[\w./:,=+@~{}-]*`) or double-quoted strings (Unicode-friendly).
- `$VAR` env references are allowed and expanded at parse time via `os.path.expandvars` — no shell invocation.
- `$(…)`, `${VAR}`, backticks, and backslash escape sequences are rejected.
- Bare values cannot contain pipes, redirects, semicolons, or ampersands. Quoted values may, because the loader emits them through `shlex.quote` so bash receives them as literal characters inside a single-quoted string.

The wizard reads parsed assignments via `eval "$(python3 -m pa.preset_loader presets/<name>)"`. If the loader rejects anything, the wizard refuses to apply the preset.

**SKILL.md** is markdown — Claude reads it as instructions. Reviewers must read every preset SKILL.md before merge. Embedded `` ```bash `` blocks with `curl` / `wget` / `eval` are flagged by the validator as a sanity check, but the actual mitigation is human review.

**daily-template.md** is plain markdown copied into the vault on first morning. No execution surface.

## Contributing a preset

1. Create `presets/<name>/` and fill the four files above.
2. Run `tests/ci/validate-preset.sh presets/<name>` locally — fix any reported issues.
3. Run `python3 -m pa.preset_loader presets/<name>` and confirm the printed values match what you intended.
4. Open a PR. The PR template includes:
   - License agreement checkbox (CC BY-SA 4.0 — see `presets/LICENSE`).
   - Confirmation that the README declares target audience + required deps.
   - Confirmation that you reviewed `config.env` against the allowlist.

The maintainer reads every preset PR. Until external review capacity grows, expect a 1–2 week turnaround.

## License

Presets in this directory are published under CC BY-SA 4.0 (see `presets/LICENSE`). The main plugin code remains MIT (see top-level `LICENSE`). Contributors agree to the CC BY-SA terms by opening a PR that touches this directory.
