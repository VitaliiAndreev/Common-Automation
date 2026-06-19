#!/usr/bin/env bash
# Shared ANSI colour helper for .github/lib shell scripts. Centralises the
# "colour only when it will reach a terminal" decision so callers highlight
# output through one tested place instead of re-deriving the TTY/NO_COLOR
# gate inline (and drifting on it). Sourced, not executed.
#
# colorize is meant to be used inside command substitution:
#     echo "$(colorize green "fixing +x on ${f}")"
# Inside $(...) fd 1 is a pipe, so a live `[[ -t 1 ]]` check would always
# read "not a terminal" and silently strip colour. To avoid that, whether
# the *sourcing script's* stdout is a terminal is captured ONCE here, at
# source time, and reused on every call.
#
# Env overrides (read live on each call, so a caller can flip them per run).
# NO_COLOR takes precedence: it is the user's universal opt-out and must win
# even against an explicit FORCE_COLOR.
#   NO_COLOR    (any value) - force colour off   (https://no-color.org)
#   FORCE_COLOR (any value) - force colour on, even when piped or captured
#                             (e.g. a menu runner that records the stream
#                             but still renders escapes)
#
# API:
#   colorize <name> <text...>     - echo <text> wrapped in <name>'s colour,
#                                   reset appended. Gated on stdout's TTY.
#                                   Unknown <name>, or colour disabled,
#                                   yields the text unchanged - so
#                                   captured/CI output stays plain ASCII.
#   colorize_fd <fd> <name> <txt> - as colorize, but gated on <fd>'s TTY
#                                   (1=stdout, 2=stderr). Lets a stderr
#                                   writer (e.g. a logger) tint only when
#                                   stderr itself is a terminal, so a
#                                   `cmd 2>file` capture stays plain ASCII.
#   color_enabled [fd]            - return 0 when colour is on for <fd>
#                                   (default 1=stdout, 2=stderr), else 1.

# Capture the sourcing script's stdout AND stderr TTY-ness once, at source
# time. See the header for why a live check inside colorize would be wrong
# under command substitution (fd 1 becomes a pipe). Both fds are captured
# so a stderr writer can gate on stderr's terminal-ness independently.
if [[ -t 1 ]]; then _COLOR_STDOUT_TTY=1; else _COLOR_STDOUT_TTY=0; fi
if [[ -t 2 ]]; then _COLOR_STDERR_TTY=1; else _COLOR_STDERR_TTY=0; fi

# Colour is off when explicitly suppressed (NO_COLOR wins over everything),
# on when explicitly forced, and otherwise tracks whether the requested fd
# was a terminal. $1 selects the fd: 2 = stderr, anything else (default) =
# stdout. The fd argument lets a stderr logger avoid writing escape bytes
# into a `cmd 2>file` capture while stdout is still a TTY.
color_enabled() {
    [[ -n "${NO_COLOR:-}" ]] && return 1
    [[ -n "${FORCE_COLOR:-}" ]] && return 0
    if [[ "${1:-1}" == 2 ]]; then
        [[ "${_COLOR_STDERR_TTY}" == 1 ]]
    else
        [[ "${_COLOR_STDOUT_TTY}" == 1 ]]
    fi
}

# Map a colour name to its SGR escape. Kept as a case (not an associative
# array) so it runs on the bash 3.2 of macOS runners. Unknown name -> exit 1
# with no output, letting colorize fall back to plain text.
_color_code() {
    case "${1}" in
        reset)   printf '\033[0m'  ;;
        bold)    printf '\033[1m'  ;;
        dim)     printf '\033[2m'  ;;
        red)     printf '\033[31m' ;;
        green)   printf '\033[32m' ;;
        yellow)  printf '\033[33m' ;;
        blue)    printf '\033[34m' ;;
        magenta) printf '\033[35m' ;;
        cyan)    printf '\033[36m' ;;
        *)       return 1          ;;
    esac
}

# echo <text> wrapped in <name>'s colour for output on <fd>, reset appended.
# No trailing newline (callers add their own). Colour disabled for <fd> or an
# unknown name -> plain text. <fd>: 1 = stdout, 2 = stderr.
colorize_fd() {
    local fd="${1:?colorize_fd: output fd required}"
    local name="${2:?colorize_fd: colour name required}"
    shift 2
    local text="$*"
    local code reset
    if ! color_enabled "${fd}" || ! code="$(_color_code "${name}")"; then
        printf '%s' "${text}"
        return 0
    fi
    # Assign reset on its own line (not inline in printf) so its exit status
    # is observed rather than masked - shellcheck SC2312 under --enable=all.
    reset="$(_color_code reset)"
    printf '%s%s%s' "${code}" "${text}" "${reset}"
}

# Stdout-gated wrapper - the common case, used inside `$(colorize ...)`.
# Back-compatible shim over colorize_fd so existing callers are unchanged.
colorize() {
    colorize_fd 1 "$@"
}
