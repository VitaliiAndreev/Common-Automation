#!/usr/bin/env bats
# Integration tests for publish-version-tags.sh - the end-to-end tag/push
# flow exercised against a local bare repo standing in for origin (no
# network). Covers the behaviours that only emerge when the connected git
# pieces run together: resolving origin/master to a SHA, creating and pushing
# the immutable tag, force-moving the major tag, and the immutability guard.
# Run with: bats scripts/publish-version-tags.integration.bats

source "${BATS_TEST_DIRNAME}/test-helpers/git-fixtures.bash"

SCRIPT="${BATS_TEST_DIRNAME}/publish-version-tags.sh"

setup() {
    require_git

    # A bare repo acts as origin; a working clone pushes an initial master to
    # it. The script under test then runs from inside the working clone with
    # its default origin/master target.
    origin="${BATS_TEST_TMPDIR}/origin.git"
    work="${BATS_TEST_TMPDIR}/work"
    git init --bare -q "${origin}"
    git init -q "${work}"
    cd "${work}"
    git config user.email "test@example.com"
    git config user.name "Test"
    git remote add origin "${origin}"
    echo "hello" > file.txt
    git add file.txt
    git commit -qm "initial"
    git branch -M master
    git push -q origin master
}

@test "publishes immutable and major tags pointing at the master tip" {
    run bash "${SCRIPT}" "v1.2.3"
    [ "${status}" -eq 0 ]
    local sha
    sha="$(git rev-parse master)"
    [ "$(git -C "${origin}" rev-parse "v1.2.3^{commit}")" = "${sha}" ]
    [ "$(git -C "${origin}" rev-parse "v1^{commit}")" = "${sha}" ]
}

@test "refuses to re-point an already published immutable tag" {
    run bash "${SCRIPT}" "v1.2.3"
    [ "${status}" -eq 0 ]
    # The local immutable tag now exists, so a repeat must abort before push.
    run bash "${SCRIPT}" "v1.2.3"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"already exists"* ]]
}

@test "moves the major tag forward when master advances" {
    run bash "${SCRIPT}" "v1.2.3"
    [ "${status}" -eq 0 ]

    echo "more" >> file.txt
    git commit -qam "second"
    git push -q origin master
    local sha2
    sha2="$(git rev-parse master)"

    run bash "${SCRIPT}" "v1.2.4"
    [ "${status}" -eq 0 ]
    # Major tag tracks the new tip; the new immutable tag does too.
    [ "$(git -C "${origin}" rev-parse "v1^{commit}")" = "${sha2}" ]
    [ "$(git -C "${origin}" rev-parse "v1.2.4^{commit}")" = "${sha2}" ]
    # The earlier immutable tag stays anchored to the old commit.
    [ "$(git -C "${origin}" rev-parse "v1.2.3^{commit}")" != "${sha2}" ]
}
