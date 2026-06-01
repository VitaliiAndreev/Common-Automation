#!/usr/bin/env bats
# Tests for setup-hooks.sh - the one-time per-clone wiring that points git
# at the repo-checked-in .githooks/ directory. Driven against a throwaway
# repo in BATS_TEST_TMPDIR, passed via GHCOMMON_TARGET_REPO so the real
# repo's git config is never touched.
# Run with: bats scripts/setup-hooks.bats

source "${BATS_TEST_DIRNAME}/../.github/lib/test-helpers/git-fixtures.bash"

setup() {
    require_git
    SCRIPT="${BATS_TEST_DIRNAME}/setup-hooks.sh"
    new_git_repo
}

@test "points core.hooksPath at .githooks for the target repo" {
    GHCOMMON_TARGET_REPO="${REPO}" run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(git -C "${REPO}" config core.hooksPath)" = ".githooks" ]
}

@test "announces the configured repo and hooks path" {
    GHCOMMON_TARGET_REPO="${REPO}" run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"core.hooksPath=.githooks"* ]]
}
