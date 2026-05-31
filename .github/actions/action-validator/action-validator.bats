#!/usr/bin/env bats
# Unit tests for action-validator.sh - the composite action's helper
# that schema-validates workflows AND composite action.yml files. The
# most important contract is the skip-silently branch when nothing is
# discoverable (covered without docker so it stays green on any
# workstation), plus the pass/fail outcomes on real fixtures (covered
# through the locally-built github-common/action-validator image so the
# bar matches what consumers actually experience). Docker-dependent
# tests `skip` cleanly when the engine is unavailable so the suite
# remains usable without it.

SCRIPT="${BATS_TEST_DIRNAME}/action-validator.sh"

setup() {
    # Run each case from an isolated workdir so the fixture trees
    # cannot leak across tests and so PWD-based file discovery in the
    # script sees only what the test created.
    workdir="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${workdir}"
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        skip "docker not on PATH"
    fi
    if ! docker info >/dev/null 2>&1; then
        skip "docker daemon not running"
    fi
}

@test "skips silently when neither workflows nor actions directory exists" {
    # Pre-image-resolution branch - no docker required, so this test
    # locks the no-op contract even on bare workstations.
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"skipping"* ]]
}

@test "exits 0 on a valid composite action.yml fixture" {
    require_docker
    mkdir -p "${workdir}/.github/actions/sample"
    cat > "${workdir}/.github/actions/sample/action.yml" <<'YAML'
name: sample
description: sample composite action
runs:
  using: composite
  steps:
    - name: echo
      shell: bash
      run: echo hello
YAML
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
}

@test "exits non-zero on a composite action.yml with a schema violation" {
    require_docker
    mkdir -p "${workdir}/.github/actions/broken"
    # `runs.using: bogus` is not in the schema's enum of allowed
    # runtimes - a stable failure-path fixture across action-validator
    # versions.
    cat > "${workdir}/.github/actions/broken/action.yml" <<'YAML'
name: broken
description: broken composite action
runs:
  using: bogus
  steps:
    - name: echo
      shell: bash
      run: echo hello
YAML
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -ne 0 ]
}
