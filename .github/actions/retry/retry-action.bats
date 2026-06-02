#!/usr/bin/env bats
# End-to-end tests for the retry composite action
# (.github/actions/retry/). The composite is bash under the hood, so
# this suite drives the same entry point (`retry-action.sh`) with
# seeded inputs - exercising the action.yml -> entry -> primitive
# wiring without spinning up a real GitHub Actions runner.
#
# Each test sets RETRY_COMMAND / RETRY_MAX_ATTEMPTS /
# RETRY_CLASSIFIERS (the same env vars action.yml exports from its
# inputs) and runs the entry script. The wrapped command is a stub
# whose attempt-counted behaviour proves the wiring works end-to-end.

setup() {
    TEST_TMP="$(mktemp -d)"
    # Action root, primitive lib root, repo root - resolved from this
    # test file's location so the suite is location-stable.
    TEST_DIR="$(cd "${BATS_TEST_DIRNAME}" && pwd)"
    REPO_ROOT="$(cd "${TEST_DIR}/../../.." && pwd)"
    ACTION_ENTRY="${REPO_ROOT}/.github/actions/retry/retry-action.sh"

    # Reset every env var the action / primitive reads so a leak from a
    # previous test can't mask a wiring bug here.
    unset RETRY_COMMAND RETRY_MAX_ATTEMPTS RETRY_MAX_SECONDS \
          RETRY_CLASSIFIERS RETRY_BACKOFF_STRATEGY \
          RETRY_BACKOFF_INITIAL_SECONDS RETRY_BACKOFF_MAX_SECONDS \
          RETRY_BACKOFF_MULTIPLIER RETRY_BACKOFF_JITTER_RATIO \
          RETRY_BACKOFF_JITTER_SEED
    # GHCOMMON_REPO_ROOT mirrors what action.yml exports from
    # `${{ github.action_path }}/../../..` at runtime.
    export GHCOMMON_REPO_ROOT="${REPO_ROOT}"

    # Fast, deterministic backoff so the suite never sleeps for real.
    # The composite's defaults (2 s + 30% jitter) are correct for prod
    # but would make every test slow and flaky.
    export RETRY_MAX_SECONDS=30
    export RETRY_BACKOFF_INITIAL_SECONDS=0
    export RETRY_BACKOFF_JITTER_RATIO=0
}

teardown() {
    rm -rf "${TEST_TMP}"
}

# Stub command sharing the same shape as retry.bats: counts attempts
# in $TEST_TMP/count and runs the caller-supplied body which can read
# $ATTEMPT. Returns the stub path.
make_stub() {
    local body="$1"
    local stub="${TEST_TMP}/cmd"
    cat > "${stub}" <<EOF
#!/usr/bin/env bash
counter="${TEST_TMP}/count"
ATTEMPT=\$(( \$(cat "\${counter}" 2>/dev/null || echo 0) + 1 ))
echo "\${ATTEMPT}" > "\${counter}"
${body}
EOF
    chmod +x "${stub}"
    echo "${stub}"
}

attempt_count() {
    cat "${TEST_TMP}/count" 2>/dev/null || echo 0
}

@test "composite: command succeeds first try -> exit 0, no retry" {
    stub="$(make_stub 'exit 0')"
    export RETRY_COMMAND="'${stub}'"
    export RETRY_MAX_ATTEMPTS=5
    export RETRY_CLASSIFIERS=""
    run "${ACTION_ENTRY}"
    [ "${status}" -eq 0 ]
    [ "$(attempt_count)" -eq 1 ]
    [[ "${output}" != *"retry: "*"attempt"* ]]
}

@test "composite: transient-fails twice then succeeds -> exit 0, 2 retry diagnostics" {
    # Stub emits a docker-registry signature on the first two attempts
    # so the default classifier set (active in this test) marks them
    # retriable, then succeeds on the third.
    stub="$(make_stub 'if (( ATTEMPT < 3 )); then echo "dial tcp 1.2.3.4:443: i/o timeout" >&2; exit 1; fi; exit 0')"
    export RETRY_COMMAND="'${stub}'"
    export RETRY_MAX_ATTEMPTS=5
    export RETRY_CLASSIFIERS="classify_docker_registry:classify_network:classify_http_5xx"
    run "${ACTION_ENTRY}"
    [ "${status}" -eq 0 ]
    [ "$(attempt_count)" -eq 3 ]
    retried=$(printf '%s\n' "${output}" | grep -c "retriable via classify_docker_registry")
    [ "${retried}" -eq 2 ]
}

@test "composite: command permanently fails -> exit propagates" {
    # Stub always fails with a clearly-permanent message; default
    # classifiers reject it so the action returns the stub's exit code
    # on the first attempt.
    stub="$(make_stub 'echo "manifest unknown: 404 Not Found" >&2; exit 17')"
    export RETRY_COMMAND="'${stub}'"
    export RETRY_MAX_ATTEMPTS=5
    export RETRY_CLASSIFIERS="classify_docker_registry:classify_network:classify_http_5xx"
    run "${ACTION_ENTRY}"
    [ "${status}" -eq 17 ]
    [ "$(attempt_count)" -eq 1 ]
    [[ "${output}" == *"permanent (exit 17)"* ]]
}

@test "composite: default transient_patterns cover docker registry timeouts" {
    # Sanity-pins the wired-in default for the third input: a docker
    # registry timeout signature must trigger a retry even when the
    # workflow author sets nothing - that is the whole point of the
    # composite's "transient_patterns" default.
    stub="$(make_stub 'if (( ATTEMPT < 2 )); then echo "TLS handshake timeout" >&2; exit 1; fi; exit 0')"
    export RETRY_COMMAND="'${stub}'"
    export RETRY_MAX_ATTEMPTS=5
    export RETRY_CLASSIFIERS="classify_docker_registry:classify_network:classify_http_5xx"
    run "${ACTION_ENTRY}"
    [ "${status}" -eq 0 ]
    [ "$(attempt_count)" -eq 2 ]
    [[ "${output}" == *"retriable via classify_docker_registry"* ]]
}

@test "composite: custom transient_patterns overrides the defaults entirely" {
    # Workflow opts in to its own classifier list. The custom function
    # is defined + exported here, then named via RETRY_CLASSIFIERS as a
    # workflow author would do. A docker signature must now be ignored
    # (only the custom classifier is asked), and the custom function's
    # accept must trigger the retry.
    accept_only_custom_classify() {
        local stderr_file="$3"
        grep -qi "CUSTOM-TRANSIENT-MARKER" "${stderr_file}"
    }
    export -f accept_only_custom_classify

    stub="$(make_stub 'if (( ATTEMPT < 2 )); then echo "CUSTOM-TRANSIENT-MARKER" >&2; exit 1; fi; exit 0')"
    export RETRY_COMMAND="'${stub}'"
    export RETRY_MAX_ATTEMPTS=5
    export RETRY_CLASSIFIERS="accept_only_custom_classify"
    run "${ACTION_ENTRY}"
    [ "${status}" -eq 0 ]
    [ "$(attempt_count)" -eq 2 ]
    [[ "${output}" == *"retriable via accept_only_custom_classify"* ]]
}

@test "composite: missing command input errors with a clear usage message (exit 2)" {
    # action.yml marks `command` required, but a direct (test or local)
    # invocation that forgets to set RETRY_COMMAND must fail with an
    # actionable message - not a confusing retry_command argv error.
    unset RETRY_COMMAND
    export RETRY_MAX_ATTEMPTS=5
    export RETRY_CLASSIFIERS=""
    run "${ACTION_ENTRY}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"RETRY_COMMAND is required"* ]]
}

@test "composite: env-var-primary sourcing path is the one used" {
    # GHCOMMON_REPO_ROOT is the authoritative path per problem.md;
    # pointing it at a tree without retry.sh must fail-fast with a
    # source error, proving the env-var-primary branch is the one
    # consulted (and not silently falling back to relative).
    bogus="${TEST_TMP}/bogus_root"
    mkdir -p "${bogus}"
    GHCOMMON_REPO_ROOT="${bogus}" \
        RETRY_COMMAND="true" \
        RETRY_MAX_ATTEMPTS=1 \
        RETRY_CLASSIFIERS="" \
        run "${ACTION_ENTRY}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"retry.sh"* ]]
}

@test "composite: relative-path fallback resolves when GHCOMMON_REPO_ROOT is unset" {
    # The other half of the sourcing contract: with no env var, the
    # entry script must still find retry.sh via SCRIPT_DIR/../../.. -
    # this is the path local invocations and ad-hoc runs take.
    unset GHCOMMON_REPO_ROOT
    stub="$(make_stub 'exit 0')"
    export RETRY_COMMAND="'${stub}'"
    export RETRY_MAX_ATTEMPTS=1
    export RETRY_CLASSIFIERS=""
    run "${ACTION_ENTRY}"
    [ "${status}" -eq 0 ]
    [ "$(attempt_count)" -eq 1 ]
}
