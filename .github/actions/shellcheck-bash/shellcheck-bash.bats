#!/usr/bin/env bats
# Unit tests for shellcheck-bash.sh - the single source of truth for the
# strict-bash lint rules. The most valuable contract is the SHELLCHECK_FLAGS
# array exposed in sourced mode: locking it here stops the CI and local
# lint bars from silently drifting apart. The executed-mode guard branches
# (usage error, missing-path skip) are also covered as they run before any
# shellcheck binary is needed.
# Run with: bats actions/shellcheck-bash/shellcheck-bash.bats

SCRIPT="${BATS_TEST_DIRNAME}/shellcheck-bash.sh"

@test "sourcing exposes the exact canonical flag set" {
    # Sourced directly (not via run) so the array is visible in this shell;
    # the dual-mode guard returns before the runner when sourced.
    # shellcheck source=./shellcheck-bash.sh
    source "${SCRIPT}"
    [ "${SHELLCHECK_FLAGS[*]}" = "--shell=bash --severity=style --enable=all -x -e SC1091" ]
}

@test "the flag set keeps the strict knobs enabled" {
    # Guards the intent (max strictness) independently of array ordering, so
    # a reordering refactor does not silently weaken the bar unnoticed.
    # shellcheck source=./shellcheck-bash.sh
    source "${SCRIPT}"
    local joined="${SHELLCHECK_FLAGS[*]}"
    [[ "${joined}" == *"--enable=all"* ]]
    [[ "${joined}" == *"--severity=style"* ]]
    [[ "${joined}" == *"--shell=bash"* ]]
}

@test "executed with no argument exits 2 with usage" {
    run "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Usage:"* ]]
}

@test "executed against a missing path skips with exit 0" {
    run "${SCRIPT}" "/no/such/path/here"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"does not exist, skipping"* ]]
}

@test "executed against a directory with no .sh files skips with exit 0" {
    # A real but script-free directory must be a no-op, not an error, so
    # callers can point the linter at optional trees safely.
    empty_dir="${BATS_TEST_TMPDIR}/empty"
    mkdir -p "${empty_dir}"
    run "${SCRIPT}" "${empty_dir}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"skipping"* ]]
}

@test "an exclude prunes that directory so its .sh files are not scanned" {
    # The only .sh lives inside an excluded dir; pruning it must leave
    # nothing to lint, so the run skips (exit 0) rather than invoking
    # shellcheck on the vendored file. Asserting via the skip path keeps
    # the test independent of whether a shellcheck binary is installed -
    # the same reason the other executed-mode tests stop before the runner.
    root="${BATS_TEST_TMPDIR}/proj"
    mkdir -p "${root}/.venv"
    printf '#!/usr/bin/env bash\n' > "${root}/.venv/vendored.sh"
    run "${SCRIPT}" "${root}" .venv
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"skipping"* ]]
}
