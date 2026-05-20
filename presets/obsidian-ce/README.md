# tim preset

The author's actual claude-pa configuration. Use it as a starting point if your setup overlaps; tweak via `pa init` afterwards.

## Target audience

- Obsidian users with an iCloud-synced vault (paths with spaces, `~md~obsidian` segment, etc.)
- Compound Engineering workflow users — `PA_SPAWN_PROMPT_TEMPLATE` injects `/workflows:brainstorm` so newly spawned project panes start in the brainstorm phase
- WezTerm as primary terminal (native backend; full multi-pane orchestration + dashboard split)
- Multi-repo rollout pattern — six-stage status taxonomy (`brainstorming, planned, in-progress, in-review, in-dev, shipped`) reflects the dev / review / merge sequence

## Required dependencies

- **Obsidian vault** at `$HOME/Documents/MyVault/` (adjust `PA_VAULT` if yours lives elsewhere)
- **WezTerm** with `wezterm cli` reachable on PATH and the mux server running (any active WezTerm window suffices)
- **bash 4+** (`brew install bash` on macOS — the default `/bin/bash` 3.2 is too old)
- **python 3.10+**

## Optional dependencies

- **Compound Engineering plugin** — if installed, `/workflows:brainstorm`, `/workflows:plan`, `/workflows:work`, `/workflows:review` route the SKILL.md task-handoff flow. Without it, the spawn template still fires but the slash command itself will be unrecognised by the project Claude. Either install CE or override `PA_SPAWN_PROMPT_TEMPLATE` after picking this preset (`pa init` lets you tweak any value).
- **`gh` CLI** — used by the morning routine's PR-status enrichment (step 5) and the open-PRs section (step 8). Without it, those steps print one line and continue.
- **`obsidian-cli`** — vault interactions in the skill fall back to filesystem reads if it's missing, but obsidian-cli is faster and handles wiki-link resolution correctly.

## Status taxonomy

The six values mean:

| Status         | Stage                                                       |
|----------------|-------------------------------------------------------------|
| `brainstorming`| Feature note exists; running `/workflows:brainstorm`        |
| `planned`      | Brainstorm complete; awaiting `/workflows:work`             |
| `in-progress`  | Active implementation in a project pane                     |
| `in-dev`       | Merged to a dev branch; awaiting QA                         |
| `in-review`    | PR open; waiting for review                                 |
| `shipped`      | Merged to main; daily note checkbox auto-ticked next morning |

`PA_STATUS_SHIPPED=shipped` controls which value triggers the auto-tick in `pa.sh tick`. Adjust if your taxonomy differs.

## What you'll want to change

After `pa init` loads this preset, walk through the wizard and update at minimum:

- `PA_VAULT` — point at your actual vault root if not the iCloud MyVault path
- `PA_STATUS_VALUES` / `PA_STATUS_SHIPPED` — drop `in-dev` / `in-review` if you don't run a multi-stage rollout
- `PA_SPAWN_PROMPT_TEMPLATE` — clear it (empty string) if you don't use Compound Engineering, or replace with your preferred slash command

## License

This preset is published under CC BY-SA 4.0 — see `presets/LICENSE`.
