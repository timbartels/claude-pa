---
description: Show vault feature notes by status, optionally filtered to one project or title.
argument-hint: [<title-or-project-substring>]
---

Run `pa.sh status` to list all active (non-shipped) feature notes from the vault — one line per note: title, status, repos.

If `$1` is given, filter the output by case-insensitive substring match against either the title or the comma-separated repos column. Otherwise show every active note.

For agent parsing prefer `pa.sh status --json` — emits a JSON array of `{title, status, repos}` objects matching the columns.
