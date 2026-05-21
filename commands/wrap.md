---
description: End-of-day routine — daily commit summary, feature-note reconciliation, pane shutdown.
argument-hint: (none)
---

Run the end-of-day routine from the personal-assistant skill:

1. Scan `$PA_PROJECTS_DIR/*` for today's commits, group by repo, write a 1–2 sentence summary per repo under `## Commits` in today's daily note.
2. Reconcile feature notes whose `status:` flipped to the configured shipped value today — tick the matching `[[link]]` via `pa.sh tick`.
3. Show still-unchecked `- [ ]` items under `## Work` and `## Personal`. Ask via `AskUserQuestion` which carry to tomorrow.
4. Ask once: anything for `## Notes`?
5. Run `pa.sh shutdown` to save each project pane's buffer to vault and kill the pane. Keeps the orchestrator + dashboard panes alive.
6. Report one line: `Day wrapped. N commits logged, M tasks open, P panes closed.`
