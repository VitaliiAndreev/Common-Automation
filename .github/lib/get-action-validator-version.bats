#!/usr/bin/env bats
# Unit tests for get-action-validator-version.sh - the single accessor
# for the action-validator version. Mirrors get-actionlint-version.bats:
# an override argument echoed verbatim, the default path that reads
# ACTION_VALIDATOR_VERSION from the adjacent versions.env, plus a guard
# for the unset case so a missing pin fails loudly rather than silently
# producing an empty version string.
# Run with: bats lib/get-action-validator-version.bats

SCRIPT="${BATS_TEST_DIRNAME}/get-action-validator-version.sh"
VERSIONS_ENV="${BATS_TEST_DIRNAME}/versions.env"

@test "echoes an override argument verbatim" {
    run "${SCRIPT}" "9.9.9"
    [ "${status}" -eq 0 ]
    [ "${output}" = "9.9.9" ]
}

@test "override wins without reading versions.env" {
    # An arbitrary override that is not a real version must still pass
    # through untouched, proving the default file is not consulted.
    run "${SCRIPT}" "not-a-real-version"
    [ "${status}" -eq 0 ]
    [ "${output}" = "not-a-real-version" ]
}

@test "with no argument returns the canonical version from versions.env" {
    # Source versions.env here rather than hardcoding the number, so the
    # test asserts the accessor faithfully returns the single source of
    # truth and cannot drift when the version is bumped.
    # shellcheck source=./versions.env
    source "${VERSIONS_ENV}"
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${ACTION_VALIDATOR_VERSION}" ]
}

@test "the returned default version is non-empty" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ -n "${output}" ]
}

@test "exits non-zero when ACTION_VALIDATOR_VERSION is unset" {
    # Stage a versions.env without ACTION_VALIDATOR_VERSION in a temp
    # dir and invoke a colocated copy of the script - the set -u guard
    # inside the script must turn the missing variable into a hard
    # failure rather than a silent empty print.
    tmp="$(mktemp -d)"
    cp "${SCRIPT}" "${tmp}/get-action-validator-version.sh"
    printf 'BATS_VERSION=1.11.0\n' > "${tmp}/versions.env"
    run "${tmp}/get-action-validator-version.sh"
    rm -rf "${tmp}"
    [ "${status}" -ne 0 ]
}
