#!/usr/bin/env bats
# Tests for check-sh-executable.sh - the +x gate over tracked .sh files.
# The logic is git-index behaviour, so each test runs against a throwaway
# repo built in BATS_TEST_TMPDIR (never the real repo). The script files
# under test are referenced by absolute path; the git repo they inspect is
# whatever the current directory belongs to - here, the fixture.
# Run with: bats actions/check-sh-executable/check-sh-executable.bats

source "${BATS_TEST_DIRNAME}/../../lib/test-helpers/git-fixtures.bash"

setup() {
    require_git
    SCRIPT="${BATS_TEST_DIRNAME}/check-sh-executable.sh"

    new_git_repo
    # Two tracked .sh files differing only in their index mode.
    add_tracked_sh exec.sh +x
    add_tracked_sh noexec.sh -x
}

@test "sourced detector lists only the .sh missing +x" {
    # shellcheck source=./check-sh-executable.sh
    source "${SCRIPT}"
    run list_sh_missing_x
    [ "${status}" -eq 0 ]
    [ "${output}" = "noexec.sh" ]
}

@test "gate exits 1, names the offender, and prints the fix command" {
    run bash "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"missing +x"* ]]
    [[ "${output}" == *"noexec.sh"* ]]
    [[ "${output}" == *"git update-index --chmod=+x"* ]]
}

@test "gate exits 0 when every tracked .sh has +x" {
    git update-index --chmod=+x noexec.sh
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
}

@test "detector reports nothing when no .sh is missing +x" {
    git update-index --chmod=+x noexec.sh
    # shellcheck source=./check-sh-executable.sh
    source "${SCRIPT}"
    run list_sh_missing_x
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}
