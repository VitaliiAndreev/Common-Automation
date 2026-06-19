#!/usr/bin/env bats
# Unit tests for scripts/log.sh - the shared level-tagged stderr logger.
# Run with: bats scripts/log.bats
#
# Each test runs a tiny driver script (rather than sourcing log.sh into the
# bats process) so the entry-script attribution - BASH_SOURCE bottom frame -
# resolves to a name this test controls (driver.sh) instead of bats internals.

setup() {
    # Start from a known-clean colour env so a tester's own NO_COLOR /
    # FORCE_COLOR does not leak into the assertions below.
    unset NO_COLOR FORCE_COLOR
    DRIVER="${BATS_TEST_TMPDIR}/driver.sh"
    # driver.sh <log-fn> <message...> - source the real logger, call <log-fn>.
    cat >"${DRIVER}" <<DRIVER
#!/usr/bin/env bash
source "${BATS_TEST_DIRNAME}/log.sh"
"\$1" "\${@:2}"
DRIVER
}

@test "log_info emits an INFO-tagged line attributed to the entry script" {
    run bash "${DRIVER}" log_info hello world
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ ^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]\ INFO\ +driver\.sh:\ hello\ world$ ]]
}

@test "log_warn emits a WARN tag" {
    run bash "${DRIVER}" log_warn careful
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ \]\ WARN\ +driver\.sh:\ careful$ ]]
}

@test "log_err emits an ERROR tag" {
    run bash "${DRIVER}" log_err boom
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ \]\ ERROR\ +driver\.sh:\ boom$ ]]
}

@test "log output goes to stderr, not stdout" {
    run bash -c "bash '${DRIVER}' log_info onlyOnStderr 2>/dev/null"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "no escape bytes when stderr colour is off (not a TTY, no force)" {
    run bash "${DRIVER}" log_err plain
    [ "${status}" -eq 0 ]
    # An ESC byte would mean colour leaked into a non-TTY (captured) stream.
    [[ "${output}" != *$'\033'* ]]
}

@test "FORCE_COLOR tints the line with the level colour (red for ERROR)" {
    FORCE_COLOR=1 run bash "${DRIVER}" log_err boom
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"$(printf '\033[31m')"*"$(printf '\033[0m')" ]]
}
