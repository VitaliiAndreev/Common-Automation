#!/usr/bin/env bats
# Unit tests for actionlint.sh - the composite action's helper that
# lints a repo's workflows (composite actions are linted transitively
# via `uses:` references from those workflows). The most important
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

@test "skips silently when workflows directory does not exist" {
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

# Stub shape parallels ansible-lint.bats / yamllint.bats but wraps the
# `pull` verb instead of `build` - actionlint uses the upstream image
# directly, so there is no build to retry. `image inspect` returns 1
# unconditionally so the cache-miss branch is exercised; `run` exits 0
# so the lint outcome stays out of scope for the retry harness.
make_docker_stub() {
    stub_dir="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${stub_dir}"
    counter="${BATS_TEST_TMPDIR}/pull-attempts"
    echo 0 > "${counter}"
    body_file="${BATS_TEST_TMPDIR}/pull-body.sh"
    printf '%s\n' "$1" > "${body_file}"
    cat > "${stub_dir}/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
    image)
        exit 1
        ;;
    pull)
        PULL_ATTEMPT=\$(( \$(cat "${counter}" 2>/dev/null || echo 0) + 1 ))
        echo "\${PULL_ATTEMPT}" > "${counter}"
        # shellcheck disable=SC1090
        source "${body_file}"
        ;;
    run)
        exit 0
        ;;
    info)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "${stub_dir}/docker"
    echo "${stub_dir}"
}

pull_attempts() {
    cat "${BATS_TEST_TMPDIR}/pull-attempts" 2>/dev/null || echo 0
}

seed_minimal_workflow_repo() {
    # Bypass the skip-silently branch so the pull / retry / run pipeline
    # is exercised. Workflow content is irrelevant - docker run is stubbed.
    mkdir -p "${workdir}/.github/workflows"
    cat > "${workdir}/.github/workflows/ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  noop:
    runs-on: ubuntu-latest
    steps:
      - run: echo hello
YAML
}

@test "retry: docker pull succeeds first try -> exit 0, no retry diagnostic" {
    seed_minimal_workflow_repo
    stub_dir="$(make_docker_stub 'exit 0')"
    run env PATH="${stub_dir}:${PATH}" \
        RETRY_MAX_ATTEMPTS=3 RETRY_BACKOFF_INITIAL_SECONDS=0 \
        RETRY_BACKOFF_JITTER_RATIO=0 \
        bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
    [ "$(pull_attempts)" -eq 1 ]
    [[ "${output}" != *"retry: actionlint docker pull attempt"* ]]
}

@test "retry: transient docker pull failure recovers on second attempt" {
    seed_minimal_workflow_repo
    stub_dir="$(make_docker_stub 'if (( PULL_ATTEMPT < 2 )); then echo "dial tcp 1.2.3.4:443: i/o timeout" >&2; exit 1; fi; exit 0')"
    run env PATH="${stub_dir}:${PATH}" \
        RETRY_MAX_ATTEMPTS=3 RETRY_BACKOFF_INITIAL_SECONDS=0 \
        RETRY_BACKOFF_JITTER_RATIO=0 \
        bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
    [ "$(pull_attempts)" -eq 2 ]
    [[ "${output}" == *"retriable via classify_docker_registry"* ]]
}

@test "retry: permanent docker pull failure exits immediately" {
    seed_minimal_workflow_repo
    stub_dir="$(make_docker_stub 'echo "Permission denied" >&2; exit 13')"
    run env PATH="${stub_dir}:${PATH}" \
        RETRY_MAX_ATTEMPTS=5 RETRY_BACKOFF_INITIAL_SECONDS=0 \
        RETRY_BACKOFF_JITTER_RATIO=0 \
        bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 13 ]
    [ "$(pull_attempts)" -eq 1 ]
    [[ "${output}" == *"permanent (exit 13)"* ]]
}

@test "retry: cached image (inspect hit) skips pull entirely" {
    # Override the inspect branch so cache-hit short-circuits to docker run.
    # If the script still calls pull, the counter goes >0 and we catch it.
    seed_minimal_workflow_repo
    stub_dir="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${stub_dir}"
    counter="${BATS_TEST_TMPDIR}/pull-attempts"
    echo 0 > "${counter}"
    cat > "${stub_dir}/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
    image) exit 0 ;;
    pull)
        PULL_ATTEMPT=\$(( \$(cat "${counter}" 2>/dev/null || echo 0) + 1 ))
        echo "\${PULL_ATTEMPT}" > "${counter}"
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "${stub_dir}/docker"
    run env PATH="${stub_dir}:${PATH}" \
        bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
    [ "$(pull_attempts)" -eq 0 ]
}
