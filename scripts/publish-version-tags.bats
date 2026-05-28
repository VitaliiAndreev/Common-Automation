#!/usr/bin/env bats
# Unit tests for publish-version-tags.sh - the version-argument handling that
# runs before any git interaction. These cases never reach fetch/tag/push
# (the script exits at validation), so they need no git and run everywhere,
# including the git-less local fallback. The tag/push behaviour is covered
# separately in publish-version-tags.integration.bats.
# Run with: bats scripts/publish-version-tags.bats

SCRIPT="${BATS_TEST_DIRNAME}/publish-version-tags.sh"

@test "rejects a version missing the v prefix with exit 2" {
    run bash "${SCRIPT}" "1.2.3"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"must look like v1.2.3"* ]]
}

@test "rejects a two-component version with exit 2" {
    run bash "${SCRIPT}" "v1.2"
    [ "${status}" -eq 2 ]
}

@test "rejects a four-component version with exit 2" {
    run bash "${SCRIPT}" "v1.2.3.4"
    [ "${status}" -eq 2 ]
}

@test "rejects a non-numeric version with exit 2" {
    run bash "${SCRIPT}" "vX.Y.Z"
    [ "${status}" -eq 2 ]
}

@test "prompts for the version when no argument is given" {
    # Feed an (invalid) answer on stdin: the script must read it via the
    # prompt and then fail validation, proving the no-arg path consumes
    # input rather than erroring on a missing argument.
    run bash -c 'printf "%s\n" "bad" | bash "$1"' _ "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"must look like v1.2.3"* ]]
}
