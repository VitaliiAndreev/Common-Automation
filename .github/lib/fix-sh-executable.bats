#!/usr/bin/env bats
# Tests for fix-sh-executable.sh - the write-side counterpart that re-stages
# tracked .sh files with +x. Mode changes are git-index behaviour, so each
# test drives a throwaway repo in BATS_TEST_TMPDIR. Index mode is read back
# from `git ls-files -s` (first field: 100644 = no +x, 100755 = +x).
# Run with: bats lib/fix-sh-executable.bats

source "${BATS_TEST_DIRNAME}/test-helpers/git-fixtures.bash"

setup() {
    require_git
    SCRIPT="${BATS_TEST_DIRNAME}/fix-sh-executable.sh"

    new_git_repo
    add_tracked_sh noexec.sh -x
}

@test "fixes a tracked .sh missing +x across the whole repo" {
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(index_mode_of noexec.sh)" = "100755" ]
}

@test "is a silent no-op when nothing is missing +x" {
    git update-index --chmod=+x noexec.sh
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "sourced fix function fixes only the path it is given" {
    # A second offender that must be left untouched, proving the path
    # argument scopes the fix rather than always healing the whole repo.
    add_tracked_sh other.sh -x

    # shellcheck source=./fix-sh-executable.sh
    source "${SCRIPT}"
    run fix_sh_executable noexec.sh
    [ "${status}" -eq 0 ]
    [ "$(index_mode_of noexec.sh)" = "100755" ]
    [ "$(index_mode_of other.sh)" = "100644" ]
}
