# lib/window-raise/_interface.sh — contract reference for window-raise helpers.
#
# This file is NOT sourced. Documents the single function each window-raise
# implementation in lib/window-raise/<os>.sh must expose.
#
#   window_raise <title-substring>
#     Bring the OS window whose title contains <title-substring> to the
#     foreground.
#
#     exit:   0 success (window matched and raised)
#             1 no window matches; OR no window manager support (Wayland
#               without compositor-specific helper)
#             2 dependency missing (e.g. wmctrl/xdotool on Linux)
#
# Notes for backend implementers:
#   - Terminal backends set distinctive window titles via terminal_set_title
#     (e.g. "[PA:<repo>]") so window-raise can match by substring without
#     needing to know about panes or sessions.
#   - The dispatcher selects the OS file by uname:
#       Darwin → lib/window-raise/macos.sh
#       Linux  → lib/window-raise/linux.sh
#   - No corresponding file ships for Windows in v0.1; PowerShell support
#     is deferred per the implementation plan.
