---
description: Run the claude-pa morning routine — daily-note carry-over, PR-status enrichment, agenda question.
argument-hint: (none)
---

Run the morning routine from the personal-assistant skill.

If today's `pa.sh session-state` already shows `morning_done: true`, switch to **resume mode** (skip carry-over, print one-line summary, ask "What now?"). Otherwise:

1. Check `pa.sh session-state` for today's resume marker.
2. Create today's daily note from the template, carry over unchecked tasks from the gap window.
3. Enrich PR branches via `gh pr list`.
4. Ask the mandatory agenda question.
5. Call `pa.sh session-touch --morning-done --agenda-asked` when the agenda answer lands.

Refer to the personal-assistant skill body for the full step sequence. Stay terse — under 20 lines total.
