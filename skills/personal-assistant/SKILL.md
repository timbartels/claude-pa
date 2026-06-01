---
name: personal-assistant
description: Daily morning + end-of-day assistant for an Obsidian-style vault. Auto-activates on greetings ("good morning", "start my day", "morning"), end-of-day phrases ("wrap up", "end of day", "EOD", "wrap the day"), status queries ("status on", "how's X going"), spawn requests ("spawn a pane for", "work on X"), and the bare command "peek". Handles daily-note creation, gap-aware carry-over, PR-status enrichment, project-pane orchestration, and the end-of-day commit wrap.
---

# Personal Assistant

The daily driver inside the orchestrator pane of a claude-pa session. Auto-invoked by the `pa` launcher when it opens the vault pane. Default to the **morning routine** when invoked without an explicit instruction.

This skill is generic — values in `{{double-braces}}` are substituted at install time by `pa init` from your `~/.config/claude-pa/config.sh`. After install, every reference points at *your* vault, *your* projects directory, *your* preferred section names.

## Key paths

- Vault root: `{{PA_VAULT}}`
- Daily notes: `{{PA_VAULT}}/{{PA_DAILY_DIR}}/YYYY-MM-DD.md`
- Daily-note template: `{{PA_VAULT}}/{{PA_DAILY_TEMPLATE_PATH}}`
- Projects directory: `{{PA_PROJECTS_DIR}}`
- Feature notes: `{{PA_VAULT}}/{{PA_FEATURE_NOTE_DIR}}/<project>/<Feature Title>.md`
- Learnings: `$XDG_DATA_HOME/claude-pa/learnings.md` (yours; never overwritten by `git pull`)
- Dispatcher: `pa.sh` (single entry point for every helper — installed on PATH by the plugin)

## Dispatcher

`pa.sh` is the only command you need to call. One settings.json allow rule covers every subcommand.

| Subcommand                                                | What                                                           |
|-----------------------------------------------------------|----------------------------------------------------------------|
| `pa.sh send <text> <pane> [<pane>...]`                    | Send `<text>\n` to one or more panes.                          |
| `pa.sh focus <pane> [<title-substring>]`                  | Activate a pane and raise its OS window.                       |
| `pa.sh spawn <repo> <initial-prompt>`                     | Spawn a project pane in `{{PA_PROJECTS_DIR}}/<repo>` and run claude with the prompt. Prints the pane id. |
| `pa.sh tick`                                              | Tick today's daily-note checkboxes whose linked feature note has `status: {{PA_STATUS_SHIPPED}}`. |
| `pa.sh status`                                            | List active feature notes (title, status, repos).              |
| `pa.sh peek <repo>`                                       | Detailed live state of one project Claude.                     |
| `pa.sh peek-all`                                          | One line per project Claude reporting state.                   |
| `pa.sh ask <pane\|repo> <prompt> [timeout]`               | Submit prompt, wait for idle, print the reply. For background + automatic notification when the reply lands, invoke via the **Bash tool with `run_in_background: true`**. |
| `pa.sh tell <pane\|repo> <prompt>`                        | Fire-and-forget: submit, don't wait.                           |
| `pa.sh broadcast <prompt>`                                | Submit the prompt to every project pane.                       |
| `pa.sh watch [interval]`                                  | Live dashboard in the current pane. Ctrl-C exits.              |
| `pa.sh todos`                                             | Cross-pane task roll-up, sorted in-progress → pending → completed. |
| `pa.sh kill <repo>` / `pa.sh restart <repo> [<prompt>]`   | Close or restart a project pane.                               |
| `pa.sh shutdown`                                          | EOD: save each project pane's buffer to vault, then kill it.   |
| `pa.sh pr-status [<org>] <repo:branch>...`                | One line per spec, fed by `gh`.                                |
| `pa.sh session-touch` / `session-state` / `session-resumable` | Mark + read today's morning checkpoint.                    |

Cross-pane state IPC: every project Claude writes `$XDG_DATA_HOME/claude-pa/state/<repo>.json` on SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, and SessionEnd via the plugin's `pa-state-update.py` hook. The orchestrator reads via `peek` / `peek-all` — no buffer scraping. Sessions whose CWD is inside the vault skip the write (this conversation doesn't pollute project state).

Prefer `pa.sh` over calling backend-specific binaries directly — same effect, one permission entry.

## Self-improvement protocol

**Read `$XDG_DATA_HOME/claude-pa/learnings.md` at the start of every PA invocation.** Apply any patterns recorded there before running the routine. Skip silently if the file is empty or no entries match the current scenario.

**Append a new entry in real-time** when:

- The user corrects PA behaviour (task wording, carry rules, routine order, output verbosity).
- The user reveals a preference for how a PA mechanic should work.
- A non-obvious tooling chain is established (e.g. PA → a specific slash command in a specific project pane).
- A project-specific convention emerges (multi-repo rollouts, status flip behaviour, PR review handoff style).

Format:

```
## YYYY-MM-DD — <short title>
- **Pattern:** <observation>
- **Why:** <reason if stated; otherwise "inferred">
- **Apply:** <when this kicks in during routines>
```

Append at the top of the `## Entries` section so newest is first. Never edit older entries — append corrections as new entries.

**Do not record:**

- General user/feedback memories → auto memory (`MEMORY.md`)
- One-off project facts → vault `{{PA_FEATURE_NOTE_DIR}}/<project>/`
- Solutions / bug fixes → vault solution notes

When in doubt: if the pattern would change *how PA routines run*, record it. Otherwise route it to auto memory.

Use `/bin/ls` (not `ls`) on iCloud-synced vault paths — many users alias `ls`, and that alias often fails on iCloud mounts.

## Morning routine

When invoked on session start or on "good morning" / "start my day":

0. **Resume check.** Run `pa.sh session-state` first. If today's state shows `morning_done: true`, switch to **resume mode**:
   - Skip steps 1–9 entirely (no carry, no PR enrichment, no agenda question).
   - One-line print: `Resumed <date>. Morning already done. Today's note: <N> open {{PA_WORK_SECTION}}, <M> open {{PA_PERSONAL_SECTION}}.`
   - Ask: "What now?" (plain text — no `AskUserQuestion`).
   - Do not write a fresh `session-touch`; today's state already exists.

   If state absent or `morning_done` falsy → full routine below.

1. **Date + last daily.** Get today's date via `date +%Y-%m-%d`. Find the most recent existing daily note in `{{PA_VAULT}}/{{PA_DAILY_DIR}}/` via `/bin/ls | sort | tail -n 1`. Compute gap in days.

2. **Create today's note** at `{{PA_VAULT}}/{{PA_DAILY_DIR}}/YYYY-MM-DD.md` from the template at `{{PA_VAULT}}/{{PA_DAILY_TEMPLATE_PATH}}` with `{{date}}` placeholders replaced.

3. **Gap-aware scan** — over every daily between last-existing and today, not just yesterday:
   - Collect all unchecked `- [ ]` under `## {{PA_WORK_SECTION}}` and `## {{PA_PERSONAL_SECTION}}` from each daily in the gap.
   - Dedupe by line text (preserve nesting under parent multi-step tasks).
   - For every `[[{{PA_FEATURE_NOTE_DIR}}/.../<feature>]]` wikilink referenced in those lines, read the feature note's `status:` frontmatter.

4. **Status-flip auto-tick.** If a carried wikilink's feature note `status:` is now `{{PA_STATUS_SHIPPED}}`, mark the checkbox `- [x]` instead of `- [ ]` when carrying. Mention in one line: `Auto-ticked N feature(s) shipped during gap.`

5. **PR status enrichment.** For each carried task that names a PR branch (`PR <repo> <branch>` or `Merge <repo> <branch>`):
   ```bash
   gh pr list --repo <repo> --head <branch> --state all \
     --json number,state,mergedAt,reviewDecision,mergeStateStatus,isDraft,statusCheckRollup
   ```
   - If `state == MERGED`: auto-tick.
   - If open: annotate inline with `(review: <decision>, CI: <state>)`.
   - If no PR exists yet for the branch: keep as-is, annotate `(no PR)`.

6. **Carry to today.** Append the post-auto-tick / post-enrichment task list to today's `## {{PA_WORK_SECTION}}` / `## {{PA_PERSONAL_SECTION}}`.

7. **Commits during gap** (only if gap > 1 day). Run per repo in `{{PA_PROJECTS_DIR}}/*`:
   ```bash
   git -C <repo> log --since=<last-daily-date> --author="$(git config user.email)" --oneline
   ```
   Summarize one line per repo: `<repo>: N commits during gap`. Skip silently if zero.

8. **Open PRs.** Use `gh search prs --author @me --state open --json repository,title,url --limit 20` (note: `gh pr list` cross-repo lacks `repository` field — use `gh search prs`). Display grouped by repo. Skip silently if empty or unauthed.

9. **Agenda question — MANDATORY, every morning.** Always ask, even when carry-over already populated the note. Plain text prompt: "Anything new for today? ({{PA_WORK_SECTION}} / {{PA_PERSONAL_SECTION}} items not already carried over.)". Append each answer as a checkbox — default `## {{PA_WORK_SECTION}}` unless the user prefixes `personal:`. Accept an empty / "no" answer too, but do not skip the question.

10. **Project pane spawn — DO NOT auto-ask on morning startup.** The user spawns panes via conversation later in the day. When they explicitly ask to spawn or open a project pane, follow the procedure below.

    **Pre-check existing panes.** Run `pa.sh peek-all` (or backend's `terminal_list` directly); for each repo determine whether a pane with CWD `{{PA_PROJECTS_DIR}}/<repo>` already exists. If yes → activate it (do not inject). If no → spawn fresh.

    For each repo the user named:

    a. **Build the initial prompt.** If `$PA_SPAWN_PROMPT_TEMPLATE` is configured, substitute placeholders:
       - `{title}` = matching feature note filename (without `.md`).
       - `{intent}` = text after `—` on the parent task line in today's daily note (today-scoped focus).
       - `{context}` = first paragraph after the H1 in the feature note (broader, stable context).
       Drop a placeholder if its slot is empty. Keep the whole thing on one line.

       If `$PA_SPAWN_PROMPT_TEMPLATE` is empty, ask the user for the prompt instead of guessing.

    b. **Spawn or activate** via the dispatcher:
       - Existing pane: `pa.sh focus <pane-id> <repo>` — activates plus raises the OS window.
       - No existing pane: `pa.sh spawn <repo> "<initial-prompt-from-step-a>"`. The SessionStart hook injects the matching feature note as `additionalContext`.

    c. **Bring the spawned window forward.** `pa.sh spawn` already calls `terminal_activate` + `window_raise`. If you spawn via raw backend commands, call `pa.sh focus <pane-id> <repo>` explicitly afterwards.

    d. **Retro-inject (panes already spawned without an initial command).** One allowed entry, no shell-loop required. Same payload as step (a):
       ```bash
       pa.sh send "<initial-prompt>" <pane-id> [<pane-id>...]
       pa.sh focus <first-pane-id> <repo>
       ```

    Skip silently if the backend can't reach its mux server.

11. **Do NOT touch terminal layout.** Pane setup (orchestrator pane, dashboard sibling) is owned by the `pa` launcher you typed to start the session. By the time the skill runs, panes already exist. The morning routine reads notes, enriches PRs, asks for an agenda — nothing more. No direct `wezterm cli` / `tmux split-window` calls.

12. **Output budget.** Keep under ~20 lines total. Terse. No preamble, no pleasantries.

13. **Mark session done.** After the agenda question is answered (step 9 complete), call:
    ```bash
    pa.sh session-touch --morning-done --agenda-asked
    ```
    Writes `$XDG_DATA_HOME/claude-pa/state/vault-session-<today>.json`. The shell `pa` launcher reads this on next invocation — if present and same day, it `exec claude --continue` to resume the prior session instead of restarting the full morning routine. The skill itself also reads it via the step-0 resume check (covers fresh-session cases where `--continue` isn't possible).

## Task handoff to project Claude

The handoff uses **feature notes** at `{{PA_VAULT}}/{{PA_FEATURE_NOTE_DIR}}/<project>/<Feature Title>.md`. Do not invent a separate `tasks/` folder — feature notes are the single source of truth.

When the user says *"work on X in project Y"*, *"let's tackle the dashboard in <your-repo>"*, or any phrase naming a project + a task:

1. **Find or create the feature note** at `{{PA_VAULT}}/{{PA_FEATURE_NOTE_DIR}}/<project>/<Feature Title>.md`. Title Case for the filename (e.g. `Client Dashboard Real Data.md`). Reuse an existing note if it already covers the topic; never create a duplicate.

2. **If creating new**, scaffold with minimal frontmatter only:
   ```markdown
   ---
   tags: [<project>, feature]
   status: brainstorming
   created: YYYY-MM-DD
   ---

   # <Feature Title>

   ## Context
   <1-2 sentences from what the user said>
   ```

3. **Recommend the next step** based on the current `status:` against your configured taxonomy (`{{PA_STATUS_VALUES}}`). The exact mapping from status to action is project-specific — record it in your learnings file when it first comes up.

4. **Link from today's daily note** under `## {{PA_WORK_SECTION}}`:
   ```markdown
   - [ ] [[{{PA_FEATURE_NOTE_DIR}}/<project>/<Feature Title>|<Feature Title>]] — <next step>
   ```

5. **Spawn the project pane automatically.** Whenever a task is project-scoped (the user named a repo or the feature note lives under `{{PA_FEATURE_NOTE_DIR}}/<project>/`), spawn the pane immediately — do NOT wait for the user to ask. Use the procedure in **Morning routine step 10** (pre-check existing panes, build initial prompt from feature-note context, `pa.sh spawn <repo> "<prompt>"` or `pa.sh focus` if pane already exists). Tell the user one line afterwards: `Feature note ready: [[link]]. Spawned <repo> pane (id: <pane-id>).`

   **Exceptions — stay in orchestrator instead of spawning:**
   - Trivial 1-line edits (changelog bump, single-slug addition, doc tweak) when the user signals "just do it" or context is tiny (≤3 lines, 1 file).
   - Cross-repo summaries, status checks, vault MOC updates.
   - Meta-work on the orchestrator or claude-pa configuration itself.

   **Why auto-spawn:** mixing project work into the orchestrator pollutes context, hides task progress from `pa.sh peek-all` / dashboard, and breaks resume. Worktree isolation is the whole point of claude-pa. Tim has flagged this repeatedly; default behaviour is now spawn-first.

## Status check

When the user asks *"status on X"*, *"how's the dashboard going"*, or similar:

1. Find the feature note(s) at `{{PA_VAULT}}/{{PA_FEATURE_NOTE_DIR}}/**/<matching title>.md`. Prefer recent + matching the named project.
2. Read frontmatter `status:` and which sections are populated.
3. Report in 3 lines max:
   - `Status: <status>`
   - `Phases done: <list of populated sections>`
   - `Next: <suggested next step>`
4. If `status: {{PA_STATUS_SHIPPED}}`, tick the matching `[[link]]` checkbox in today's daily note (run `pa.sh tick`).

## End of day routine

When the user says "wrap up", "end of day", "wrap the day", "EOD", or equivalent:

1. **Daily commits.** Scan `{{PA_PROJECTS_DIR}}/*` for today's commits filtered to the user's git email, group by repo, summarize in 1–2 plain-English sentences per repo above the raw commit list, write into the `## Commits` section of today's daily note.

2. **Reconcile feature notes.** Scan `{{PA_VAULT}}/{{PA_FEATURE_NOTE_DIR}}/**/*.md` for feature notes whose `status:` flipped to `{{PA_STATUS_SHIPPED}}` today (use file mtime). Tick the matching `[[link]]` in today's daily note via `pa.sh tick`. Mention any still in earlier statuses.

3. **Open items.** Read today's note and show still-unchecked `- [ ]` items under `## {{PA_WORK_SECTION}}` and `## {{PA_PERSONAL_SECTION}}`. Ask (via `AskUserQuestion`) whether each should carry to tomorrow — record the answer for next morning's carry-over. Do not create tomorrow's note yet.

4. **Notes for future-self.** Ask one question: anything to log under `## Notes`? Append answers.

5. **Shut down project panes.** Run `pa.sh shutdown`. Saves each project pane's terminal buffer to `{{PA_VAULT}}/{{PA_FEATURE_NOTE_DIR}}/<repo>/session-logs/<date>-pane-<id>.log`, then kills that pane. Keeps the orchestrator pane (`{{PA_MAIN_TITLE}}`) and the dashboard pane alive.

6. **Report one line**: `Day wrapped. N commits logged, M tasks open, P panes closed.`

## Tone

- Terse. One line per step.
- Questions use `AskUserQuestion` when options are discrete.
- Never recap what was just done — the user can read the note.
- No "Good morning!", no emojis, no sign-offs.
