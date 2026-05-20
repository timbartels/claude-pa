# lib/terminal/_interface.sh — contract reference for terminal backends.
#
# This file is NOT sourced. It documents the 9 functions every backend in
# lib/terminal/<name>.sh must implement, plus exit-code semantics.
#
# The dispatcher (bin/pa.sh) sources the active backend via:
#   source "$PA_LIB/terminal/${PA_TERMINAL_BACKEND}.sh"
#
# Required functions:
#
#   terminal_spawn <cwd> <cmd>
#     Spawn a new pane/window with the given cwd and run <cmd>.
#     stdout: pane_id (backend-specific string; opaque to callers)
#     stderr: diagnostics
#     exit:   0 success, 1 transient failure, 2 backend unavailable
#
#   terminal_list
#     Enumerate all known panes.
#     stdout: one line per pane in the format "pane_id|cwd|title"
#             (empty stdout is valid when no panes exist)
#     exit:   0 always when backend reachable, 2 if backend unavailable
#
#   terminal_send <pane_id> <text>
#     Send <text> verbatim to the pane (no key-name lookup, no submission).
#     exit:   0 success, 1 transient, 2 backend unavailable, 3 pane gone
#
#   terminal_enter <pane_id>
#     Submit (send Enter/Return key) to the pane.
#     exit:   0 success, 1 transient, 2 backend unavailable, 3 pane gone
#
#   terminal_capture <pane_id>
#     Read the pane's visible buffer (or scrollback per backend default).
#     stdout: buffer text (multi-line)
#     exit:   0 success, 1 transient, 2 backend unavailable, 3 pane gone
#
#   terminal_kill <pane_id>
#     Close the pane. Killing an already-dead pane is success.
#     exit:   0 success, 2 backend unavailable
#
#   terminal_activate <pane_id>
#     Bring the pane to the foreground (focus its window + select within tabs).
#     exit:   0 success, 2 backend unavailable, 3 pane gone
#
#   terminal_set_title <pane_id> <tag>
#     Set the pane (or its containing tab) title to <tag>.
#     exit:   0 success, 2 backend unavailable, 3 pane gone
#
#   terminal_health
#     Probe whether the backend is reachable and ready. Side-effect-free.
#     stdout: short version string or status info
#     exit:   0 reachable, 2 unavailable
#
# Conventions across backends:
#
#   - stdout is reserved for the documented payload. Diagnostics go to stderr.
#   - Backends MUST validate pane-id format before acting (regex or membership
#     check against terminal_list output) and exit 3 on unknown pane.
#   - All exit codes are checked by the dispatcher; do not return non-zero on
#     success.
#   - Backends do not call other backends. window-raise lives in
#     lib/window-raise/<os>.sh and is called only by terminal_focus_window
#     (which delegates rather than implementing window focus directly).
#
# window-raise contract (see lib/window-raise/_interface.sh):
#
#   window_raise <title-substring>
#     Focus the OS window whose title contains <title-substring>.
#     exit:   0 raised, 1 no match
