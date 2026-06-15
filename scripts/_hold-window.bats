#!/usr/bin/env bats
# Tests for _hold-window.sh - the sourced EXIT-trap helper that pauses on an
# Explorer double-click. Only the non-interactive contract is testable here:
# the prompt branch needs a real tty, which bats does not provide. What
# matters for CI and piped use is that the handler never blocks and always
# preserves the script's exit code. Each case runs a throwaway shell that
# sources the helper, arms the trap, and exits with a known code.
# Run with: bats scripts/_hold-window.bats

SCRIPT="${BATS_TEST_DIRNAME}/_hold-window.sh"

@test "sourcing defines hold_window_open" {
    source "${SCRIPT}"
    declare -F hold_window_open >/dev/null
}

@test "preserves a nonzero exit code without prompting (non-tty)" {
    # stdout is a pipe under run, so the -t 1 guard skips the prompt; the
    # handler must pass the original code straight through.
    run bash -c 'source "$1"; trap hold_window_open EXIT; exit 7' _ "${SCRIPT}"
    [ "${status}" -eq 7 ]
    [ -z "${output}" ]
}

@test "preserves a success exit code (non-tty)" {
    run bash -c 'source "$1"; trap hold_window_open EXIT; exit 0' _ "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "COMMON_AUTOMATION_NO_PAUSE=1 suppresses the prompt and preserves the code" {
    # The .bat launchers export this so they, not the trap, hold the window;
    # the handler must then be a pure pass-through.
    COMMON_AUTOMATION_NO_PAUSE=1 run bash -c 'source "$1"; trap hold_window_open EXIT; exit 5' _ "${SCRIPT}"
    [ "${status}" -eq 5 ]
    [ -z "${output}" ]
}
