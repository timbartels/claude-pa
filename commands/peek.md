---
description: Show live state of one or all project Claude panes.
argument-hint: [<repo>]
---

Read cross-pane state via the dispatcher.

- No argument → `pa.sh peek-all`. One line per project pane: repo, state, age, last event, last tool, todos / prompt.
- With argument `$1` → `pa.sh peek <repo>`. Detailed dump for a single repo: pane id, idle flag, last event, last prompt, todos with completion marks, recent event log.

For agent parsing prefer `pa.sh peek-all --json` or `pa.sh peek <repo> --json` — the structured output matches the on-disk state file shape.
