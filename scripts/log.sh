#!/usr/bin/env bash
# Shared timestamped, level-tagged stderr logger - the single source of
# truth for the
#   [HH:MM:SS] LEVEL <script>: <message>
# progress/diagnostic prefix used across the infra bash surface. Consumed
# cross-repo (e.g. Infrastructure-Vm-Ansible/ops, via a thin _log.sh
# resolver shim) the same way scripts/_to-windows-path.sh is.
#
# SEVERITY IS CARRIED BY THE TEXT TAG (INFO/WARN/ERROR), not by colour, on
# purpose: this output is consumed through `wsl ... 2>&1 | Out-Host` in the
# Infrastructure-E2E dispatchers, where PowerShell wraps every line of the
# merged stderr in a red ErrorRecord regardless of which stream it came
# from. Colour cannot distinguish progress from failure there, but a text
# tag rides through that round-trip, a file redirection, and grep unchanged.
#
# Colour is layered on top only as a convenience for direct-terminal runs,
# via colors.sh (the colour single source of truth) gated on STDERR's
# TTY-ness - so when stderr is redirected to a file the capture stays plain
# ASCII. <script> is the executed entry script (bottom of BASH_SOURCE), so
# a line is attributed to the tool the operator ran even when emitted from
# a sourced helper. All levels go to stderr so stdout stays clean for the
# capturable KEY=value data the orchestrators read back via command
# substitution.
#
# Re-sourcing is harmless (no readonly state); every caller sources this
# directly rather than assuming an ancestor already did.

# Resolve colors.sh relative to THIS file (not the caller's cwd or repo) so
# the colour helper is found no matter which repo or directory sources the
# logger. colors.sh is the single source of truth for the NO_COLOR /
# FORCE_COLOR / TTY gate and the SGR codes - the logger never re-derives
# them.
# shellcheck source=../.github/lib/colors.sh
source "${BASH_SOURCE[0]%/*}/../.github/lib/colors.sh"

# Core formatter. $1 level tag, $2 colour name (a colors.sh palette entry),
# $3.. message words. The whole line is tinted via colorize_fd on fd 2,
# which yields plain text whenever stderr colour is off - so the tag, never
# an escape sequence, carries the severity in a captured or piped stream.
_log_emit() {
    local level="$1" colour="$2"
    shift 2
    # Bottom of the source stack = the executed entry script. Negative array
    # indices need bash 4.3+, so compute the last index explicitly to keep
    # working on the bash 3.2 of macOS CI runners.
    local script="${BASH_SOURCE[$(( ${#BASH_SOURCE[@]} - 1 ))]##*/}"
    local line rendered
    # %-5s pads the tag to a fixed width so the script name and message stay
    # column-aligned across INFO/WARN/ERROR lines.
    # shellcheck disable=SC2312  # date never fails; masking its status is fine
    printf -v line '[%s] %-5s %s: %s' \
        "$(date +%H:%M:%S)" "${level}" "${script}" "$*"
    # Assign on its own line (not inline in printf) so colorize_fd's exit
    # status is observed rather than masked - shellcheck SC2312.
    rendered="$(colorize_fd 2 "${colour}" "${line}")"
    printf '%s\n' "${rendered}" >&2
}

# Colours track the cross-repo convention: green = routine progress (the
# dominant status colour in the E2E dispatchers and Common-Automation's own
# scripts), yellow = caution, red = failure. Magenta is reserved elsewhere
# for section headers, so it is deliberately not used here.
log_info() { _log_emit INFO  green  "$*"; }
log_warn() { _log_emit WARN  yellow "$*"; }
log_err()  { _log_emit ERROR red    "$*"; }
