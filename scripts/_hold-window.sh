#!/usr/bin/env bash
# Sourced helper that defines `hold_window_open`, an EXIT-trap handler
# that pauses for a keypress before letting bash exit. Used by every
# user-facing script under scripts/ so an Explorer double-click does
# not flash a window closed before the output is readable.
#
# Activation contract: callers source this file and then register the
# trap themselves, e.g.
#
#     # shellcheck source=./_hold-window.sh
#     source "${script_dir}/_hold-window.sh"
#     trap hold_window_open EXIT
#
# The trap stays out of the way when:
#   - COMMON_AUTOMATION_NO_PAUSE=1 is exported (e.g. by the .bat launchers,
#     which hold the cmd window themselves and would otherwise double-
#     prompt)
#   - stdout is not a tty (CI, pipe, redirect)

# shellcheck disable=SC2148  # intentionally no shebang on sourced file? Keep one to satisfy editors.

hold_window_open() {
    local rc=$?
    if [[ "${COMMON_AUTOMATION_NO_PAUSE:-}" != "1" && -t 1 ]]; then
        # shellcheck disable=SC2162
        read -n 1 -r -s -p "Press any key to close ..." || true
        echo
    fi
    exit "${rc}"
}
