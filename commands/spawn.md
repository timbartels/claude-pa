---
description: Spawn (or activate) a project pane for a repo.
argument-hint: <repo> [<initial-prompt>]
---

Spawn a project Claude pane for the repo named in $1.

Procedure:

1. Run `pa.sh peek-all --json` to check whether a pane for this repo already exists. If yes, activate it via `pa.sh focus <pane-id> <repo>` and stop — do not inject.
2. If no existing pane:
   - Build the initial prompt. If `$PA_SPAWN_PROMPT_TEMPLATE` is configured, substitute `{title}=<repo>` (or feature note title if available), `{intent}` from any context in the user's message, `{context}` from the feature note H1 paragraph. Drop placeholders that have no value.
   - If `$2` is supplied, use it as the prompt verbatim instead.
   - Run `pa.sh spawn <repo> "<prompt>"`. This spawns the pane, verifies it stayed alive, focuses the window, and prints the pane id.
3. If the spawn fails (no project at `$PA_PROJECTS_DIR/<repo>`, terminal backend unreachable), report the specific error.
