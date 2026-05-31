#!/usr/bin/env bats
# Unit tests for actionlint.sh - the composite action's helper that
# lints a repo's workflows and composite actions. The most important
# contract is the skip-silently branch (covered without docker so it
# stays green on any workstation) plus the pass/fail outcomes on real
# fixtures (covered through the pinned rhysd/actionlint image, so the
# bar matches what consumers actually experience). Docker-dependent
# tests `skip` cleanly when the engine is unavailable so the suite
# remains usable without it.

SCRIPT="${BATS_TEST_DIRNAME}/actionlint.sh"

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

@test "exits 0 on a clean workflow fixture" {
    require_docker
    mkdir -p "${workdir}/.github/workflows"
    cat > "${workdir}/.github/workflows/clean.yml" <<'YAML'
name: clean
on: [push]
jobs:
  noop:
    runs-on: ubuntu-latest
    steps:
      - run: echo hello
YAML
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
}

@test "exits non-zero on a workflow with a schema error" {
    require_docker
    mkdir -p "${workdir}/.github/workflows"
    # A step with neither `run` nor `uses` is a schema error
    # actionlint flags reliably across versions - a stable choice for
    # the failure-path contract.
    cat > "${workdir}/.github/workflows/broken.yml" <<'YAML'
name: broken
on: [push]
jobs:
  noop:
    runs-on: ubuntu-latest
    steps:
      - name: bare
YAML
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -ne 0 ]
}
