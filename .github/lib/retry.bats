#!/usr/bin/env bats
# Unit tests for scripts/lib/retry.sh. Step 1 covers budget
# enforcement, step 2 adds exponential-with-jitter backoff. Classifier
# cases (steps 3-4) land alongside the code that introduces them.
#
# The primitive is sourced rather than executed - retry_command is a
# shell function, not a standalone script - so each test sources
# retry.sh into the test shell and calls retry_command directly.

setup() {
    # Each test gets its own scratch dir so attempt-counter files
    # don't leak between tests.
    TEST_TMP="$(mktemp -d)"
    # Reset budget env so a test setting one doesn't bleed into the
    # next. Tests that need a value set it explicitly.
    unset RETRY_MAX_ATTEMPTS RETRY_MAX_SECONDS
    unset RETRY_BACKOFF_STRATEGY \
          RETRY_BACKOFF_INITIAL_SECONDS RETRY_BACKOFF_MAX_SECONDS \
          RETRY_BACKOFF_MULTIPLIER RETRY_BACKOFF_JITTER_RATIO \
          RETRY_BACKOFF_JITTER_SEED
    unset RETRY_CLASSIFIERS
    # shellcheck source=./retry.sh
    source "${BATS_TEST_DIRNAME}/retry.sh"
}

# Step-1 control-flow tests that actually retry add the env vars
# below inline to disable the production 2 s+ backoff - they only
# care that retries happened, not how long they slept. Backoff-math
# tests below leave the production defaults intact.

teardown() {
    rm -rf "${TEST_TMP}"
}

# Builds a one-shot stub command at $TEST_TMP/cmd that increments a
# counter on each invocation and exits according to a caller-supplied
# script body. Returns the path to the stub. The body receives the
# current attempt number in $ATTEMPT.
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

@test "succeeds on first attempt with no retry diagnostic" {
    stub="$(make_stub 'exit 0')"
    run retry_command "noop" -- "${stub}"
    [ "${status}" -eq 0 ]
    [ "$(attempt_count)" -eq 1 ]
    [[ "${output}" != *"retry:"* ]]
}

@test "retries until success and names the op on each failure" {
    # Fail twice, then succeed. Default max_attempts (5) is plenty.
    stub="$(make_stub 'if (( ATTEMPT < 3 )); then exit 7; fi; exit 0')"
    RETRY_MAX_SECONDS=30 RETRY_BACKOFF_INITIAL_SECONDS=0 RETRY_BACKOFF_JITTER_RATIO=0 \
        run retry_command "flaky" -- "${stub}"
    [ "${status}" -eq 0 ]
    [ "$(attempt_count)" -eq 3 ]
    # Two retry diagnostics (one per failed attempt before success).
    count=$(printf '%s\n' "${output}" | grep -c "retry: flaky attempt")
    [ "${count}" -eq 2 ]
}

@test "exhausted attempts returns the command's last exit code" {
    stub="$(make_stub 'exit 13')"
    RETRY_MAX_ATTEMPTS=3 RETRY_MAX_SECONDS=30 \
        RETRY_BACKOFF_INITIAL_SECONDS=0 RETRY_BACKOFF_JITTER_RATIO=0 \
        run retry_command "always-fails" -- "${stub}"
    [ "${status}" -eq 13 ]
    [ "$(attempt_count)" -eq 3 ]
    [[ "${output}" == *"retry: always-fails exhausted attempts (3)"* ]]
}

@test "RETRY_MAX_ATTEMPTS=1 disables retry entirely" {
    stub="$(make_stub 'exit 5')"
    RETRY_MAX_ATTEMPTS=1 RETRY_MAX_SECONDS=30 run retry_command "once" -- "${stub}"
    [ "${status}" -eq 5 ]
    [ "$(attempt_count)" -eq 1 ]
    [[ "${output}" == *"exhausted attempts (1)"* ]]
}

@test "RETRY_MAX_SECONDS=0 ends after the first failed attempt" {
    stub="$(make_stub 'exit 9')"
    RETRY_MAX_ATTEMPTS=10 RETRY_MAX_SECONDS=0 run retry_command "no-time" -- "${stub}"
    [ "${status}" -eq 9 ]
    [ "$(attempt_count)" -eq 1 ]
    [[ "${output}" == *"exhausted seconds (0)"* ]]
}

@test "stdout from the wrapped command reaches the caller verbatim" {
    stub="$(make_stub 'echo "hello-from-cmd"; exit 0')"
    run retry_command "echoer" -- "${stub}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"hello-from-cmd"* ]]
}

@test "primitive diagnostics go to stderr with the retry: prefix" {
    stub="$(make_stub 'echo "real-output"; exit 4')"
    # Capture stdout and stderr separately to assert the routing.
    out_file="${TEST_TMP}/out"
    err_file="${TEST_TMP}/err"
    RETRY_MAX_ATTEMPTS=2 RETRY_MAX_SECONDS=30 \
        RETRY_BACKOFF_INITIAL_SECONDS=0 RETRY_BACKOFF_JITTER_RATIO=0 \
        retry_command "router" -- "${stub}" \
        >"${out_file}" 2>"${err_file}" || true
    grep -q "real-output" "${out_file}"
    ! grep -q "retry:" "${out_file}"
    grep -q "retry: router" "${err_file}"
}

@test "missing op-name argument is a usage error (exit 2)" {
    run retry_command
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]
}

@test "empty op-name argument is a usage error (exit 2)" {
    run retry_command "" -- true
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]
}

@test "first arg of -- is a usage error (op-name missing)" {
    run retry_command -- echo hi
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]
}

@test "missing -- separator is a usage error (exit 2)" {
    run retry_command "op" echo hi
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]
}

@test "missing command after -- is a usage error (exit 2)" {
    run retry_command "op" --
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]
}

# --- Step 2: pluggable backoff strategy ------------------------------
#
# These tests cover two surfaces:
#   1. The default strategy `exponential_jitter_backoff` - its math is
#      asserted by calling the function directly, avoiding timing
#      flakiness from real sleeps.
#   2. The registry plumbing in `retry_command` - default selection,
#      custom-strategy injection, unknown-strategy error.

# Helper: assert a decimal $1 falls inside the inclusive band [$2, $3].
# Uses awk because bash arithmetic is integer-only and the backoff
# function emits a fractional value.
assert_within() {
    local value="$1" lo="$2" hi="$3"
    awk -v v="${value}" -v lo="${lo}" -v hi="${hi}" \
        'BEGIN { exit !(v + 0 >= lo + 0 && v + 0 <= hi + 0) }'
}

@test "default strategy: first-retry sleep lands in [1.4, 2.6]" {
    # Production defaults: initial=2, mult=2, jitter=0.3. The sleep
    # after the first failed attempt uses base = 2 * 2^0 = 2, so the
    # jittered value falls in 2 * [1-0.3, 1+0.3] = [1.4, 2.6]. A fixed
    # seed keeps the sample reproducible while still exercising the
    # jitter path (ratio > 0).
    RETRY_BACKOFF_JITTER_SEED=42
    value="$(exponential_jitter_backoff 1 9999)"
    assert_within "${value}" 1.4 2.6
}

@test "default strategy: second-retry sleep lands in [2.8, 5.2]" {
    # Second retry base = 2 * 2^1 = 4; jittered band [2.8, 5.2].
    RETRY_BACKOFF_JITTER_SEED=42
    value="$(exponential_jitter_backoff 2 9999)"
    assert_within "${value}" 2.8 5.2
}

@test "default strategy: RETRY_BACKOFF_MAX_SECONDS clamps before jitter" {
    # Retry 10 would unjittered-base to 2 * 2^9 = 1024 s. The MAX
    # cap of 5 must bring it down before jitter is applied, so the
    # jittered value still falls in [5 * 0.7, 5 * 1.3] = [3.5, 6.5].
    RETRY_BACKOFF_MAX_SECONDS=5
    RETRY_BACKOFF_JITTER_SEED=42
    value="$(exponential_jitter_backoff 10 9999)"
    assert_within "${value}" 3.5 6.5
}

@test "default strategy: RETRY_BACKOFF_JITTER_RATIO=0 is exact exponential" {
    # No jitter -> deterministic exponential, seed irrelevant.
    RETRY_BACKOFF_JITTER_RATIO=0
    [ "$(exponential_jitter_backoff 1 9999)" = "2.000" ]
    [ "$(exponential_jitter_backoff 2 9999)" = "4.000" ]
    # Fourth retry, default cap 60: 2 * 2^3 = 16.000 (below cap).
    [ "$(exponential_jitter_backoff 4 9999)" = "16.000" ]
}

@test "default strategy: same seed produces the same sample" {
    # Reproducibility is the contract the seed env var exists for.
    RETRY_BACKOFF_JITTER_SEED=123
    first="$(exponential_jitter_backoff 2 9999)"
    RETRY_BACKOFF_JITTER_SEED=123
    second="$(exponential_jitter_backoff 2 9999)"
    [ "${first}" = "${second}" ]
}

@test "primitive caps any strategy's return to remaining deadline" {
    # The cap lives in the primitive (via _retry_cap_sleep), not the
    # strategy, so every registered strategy inherits it. Verify by
    # asking the cap helper directly: a 16 s requested sleep against
    # a 3 s remaining budget shrinks to 3.000.
    [ "$(_retry_cap_sleep 16 3)" = "3.000" ]
    # A strategy that returns negative (or zero) is clamped to 0.
    [ "$(_retry_cap_sleep -5 10)" = "0.000" ]
}

@test "registry: unset RETRY_BACKOFF_STRATEGY uses exponential_jitter_backoff" {
    # No env var set: the default must kick in. We verify by driving
    # retry_command end-to-end with a stub that fails once then
    # succeeds, under RATIO=0 + small INITIAL so the default
    # strategy's deterministic exponential sleeps for a known short
    # value (0.000 -> 0.001) without making the test slow.
    stub="$(make_stub 'if (( ATTEMPT < 2 )); then exit 1; fi; exit 0')"
    RETRY_MAX_SECONDS=30 RETRY_BACKOFF_INITIAL_SECONDS=0 RETRY_BACKOFF_JITTER_RATIO=0 \
        run retry_command "uses-default" -- "${stub}"
    [ "${status}" -eq 0 ]
    [ "$(attempt_count)" -eq 2 ]
    # One retry diagnostic confirms the strategy was invoked.
    [[ "${output}" == *"retry: uses-default attempt 1 failed"* ]]
}

@test "registry: a custom <name>_backoff function can be selected" {
    # Define a strategy that always sleeps 0 s so the test stays
    # fast, and assert the primitive routes through it. Side-effect
    # marker file proves the function was actually called.
    marker="${TEST_TMP}/strategy-called"
    rm -f "${marker}"
    constant_zero_backoff() {
        touch "${marker}"
        # Echo the contract'd stdout: sleep seconds for this retry.
        echo "0.000"
    }
    export -f constant_zero_backoff

    stub="$(make_stub 'if (( ATTEMPT < 2 )); then exit 1; fi; exit 0')"
    RETRY_MAX_SECONDS=30 RETRY_BACKOFF_STRATEGY=constant_zero_backoff \
        run retry_command "custom" -- "${stub}"
    [ "${status}" -eq 0 ]
    [ -e "${marker}" ]
}

@test "default strategy is sourced from retry-strategies/exponential-jitter.sh" {
    # extdebug makes `declare -F` print the source file of a function,
    # which is the contract this test pins: editing the function's
    # body in retry.sh by mistake (instead of in the strategies file)
    # would flip this assertion. Without extdebug `declare -F` only
    # prints the name.
    shopt -s extdebug
    info="$(declare -F exponential_jitter_backoff)"
    shopt -u extdebug
    [[ "${info}" == *"retry-strategies/exponential-jitter.sh"* ]]
}

# --- Step 3: pluggable classifier strategy ---------------------------
#
# Classifiers decide retriable vs permanent. With RETRY_CLASSIFIERS
# unset (the default) behaviour matches steps 1-2: every non-zero exit
# is retried. With one or more classifiers configured, the primitive
# captures stdout/stderr to inspectable files and ORs the classifiers'
# verdicts - any accept means retry, all reject means fail fast.

@test "classifier: unset RETRY_CLASSIFIERS keeps step-1/2 always-retry behaviour" {
    # Sanity-check: with classifiers off, a permanent-looking failure
    # still retries until the attempt budget is exhausted - i.e. the
    # default path is unchanged from step 2.
    stub="$(make_stub 'echo "syntax error" >&2; exit 1')"
    RETRY_MAX_ATTEMPTS=3 RETRY_MAX_SECONDS=30 \
        RETRY_BACKOFF_INITIAL_SECONDS=0 RETRY_BACKOFF_JITTER_RATIO=0 \
        run retry_command "always-retry" -- "${stub}"
    [ "${status}" -eq 1 ]
    [ "$(attempt_count)" -eq 3 ]
    [[ "${output}" == *"exhausted attempts (3)"* ]]
}

@test "classifier: single accepting classifier triggers retry and is named in diagnostic" {
    accept_all_classify() { return 0; }
    export -f accept_all_classify

    stub="$(make_stub 'if (( ATTEMPT < 2 )); then exit 1; fi; exit 0')"
    RETRY_MAX_SECONDS=30 RETRY_BACKOFF_INITIAL_SECONDS=0 RETRY_BACKOFF_JITTER_RATIO=0 \
        RETRY_CLASSIFIERS=accept_all_classify \
        run retry_command "accepted" -- "${stub}"
    [ "${status}" -eq 0 ]
    [ "$(attempt_count)" -eq 2 ]
    [[ "${output}" == *"retriable via accept_all_classify"* ]]
}

@test "classifier: single rejecting classifier fails fast with rejector + its stderr" {
    # Rejector writes a reason to its own stderr - the primitive
    # surfaces that in the permanent-failure diagnostic so log readers
    # don't have to re-run with set -x to see why.
    reject_with_reason_classify() {
        echo "not a known transient signature" >&2
        return 1
    }
    export -f reject_with_reason_classify

    stub="$(make_stub 'exit 7')"
    RETRY_MAX_ATTEMPTS=5 RETRY_MAX_SECONDS=30 \
        RETRY_CLASSIFIERS=reject_with_reason_classify \
        run retry_command "perm" -- "${stub}"
    [ "${status}" -eq 7 ]
    # Only one attempt: classifier rejection short-circuits the loop.
    [ "$(attempt_count)" -eq 1 ]
    [[ "${output}" == *"permanent (exit 7)"* ]]
    [[ "${output}" == *"rejected by reject_with_reason_classify"* ]]
    [[ "${output}" == *"not a known transient signature"* ]]
}

@test "classifier: OR-semantics - reject-then-accept order still retries" {
    # Verifies the OR fold: a leading rejector must not prevent a
    # later classifier from triggering the retry.
    reject_first_classify() { return 1; }
    accept_second_classify() { return 0; }
    export -f reject_first_classify accept_second_classify

    stub="$(make_stub 'if (( ATTEMPT < 2 )); then exit 1; fi; exit 0')"
    RETRY_MAX_SECONDS=30 RETRY_BACKOFF_INITIAL_SECONDS=0 RETRY_BACKOFF_JITTER_RATIO=0 \
        RETRY_CLASSIFIERS=reject_first_classify:accept_second_classify \
        run retry_command "or-fold" -- "${stub}"
    [ "${status}" -eq 0 ]
    [ "$(attempt_count)" -eq 2 ]
    [[ "${output}" == *"retriable via accept_second_classify"* ]]
}

@test "classifier: receives the captured stdout and stderr from the failed attempt" {
    # The classifier is the only place that proves what was captured.
    # We write a sentinel to both streams, have the classifier assert
    # the captures contain that sentinel, and use its accept/reject to
    # surface the result back to the test.
    sentinel_stdout="STDOUT-SENTINEL-7Q2"
    sentinel_stderr="STDERR-SENTINEL-7Q2"
    capture_check_classify() {
        local exit_code="$1" stdout_file="$2" stderr_file="$3"
        # Echo a token the test can grep for, regardless of accept/reject.
        echo "capture-check: exit=${exit_code}" >&2
        if grep -q "STDOUT-SENTINEL-7Q2" "${stdout_file}" \
                && grep -q "STDERR-SENTINEL-7Q2" "${stderr_file}"; then
            return 0
        fi
        echo "capture-check: sentinel missing" >&2
        return 1
    }
    export -f capture_check_classify

    stub="$(make_stub "echo '${sentinel_stdout}'; echo '${sentinel_stderr}' >&2; if (( ATTEMPT < 2 )); then exit 1; fi; exit 0")"
    RETRY_MAX_SECONDS=30 RETRY_BACKOFF_INITIAL_SECONDS=0 RETRY_BACKOFF_JITTER_RATIO=0 \
        RETRY_CLASSIFIERS=capture_check_classify \
        run retry_command "captures" -- "${stub}"
    [ "${status}" -eq 0 ]
    [ "$(attempt_count)" -eq 2 ]
    # Classifier saw both sentinels and accepted - so retry happened.
    [[ "${output}" == *"retriable via capture_check_classify"* ]]
    # And there is no "sentinel missing" message in the output.
    [[ "${output}" != *"sentinel missing"* ]]
}

@test "classifier: live output reaches caller while capture is in progress" {
    # The tee'd capture must not swallow output. The stub writes a
    # well-known marker, the classifier always accepts, and the test
    # asserts the marker is visible in the combined run-output (which
    # is the caller's stdout/stderr) - independent of any classifier
    # inspection.
    accept_all_classify() { return 0; }
    export -f accept_all_classify

    stub="$(make_stub 'echo "LIVE-STDOUT-MARKER"; echo "LIVE-STDERR-MARKER" >&2; if (( ATTEMPT < 2 )); then exit 1; fi; exit 0')"
    RETRY_MAX_SECONDS=30 RETRY_BACKOFF_INITIAL_SECONDS=0 RETRY_BACKOFF_JITTER_RATIO=0 \
        RETRY_CLASSIFIERS=accept_all_classify \
        run retry_command "passthrough" -- "${stub}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"LIVE-STDOUT-MARKER"* ]]
    [[ "${output}" == *"LIVE-STDERR-MARKER"* ]]
}

@test "classifier: unknown classifier errors with a clear message (exit 2)" {
    # Mirrors the unknown-strategy contract: a typo'd RETRY_CLASSIFIERS
    # entry must surface immediately with a usage error, not silently
    # become a never-matching rejector that flips every failure into
    # "permanent".
    stub="$(make_stub 'exit 1')"
    RETRY_MAX_ATTEMPTS=3 RETRY_MAX_SECONDS=30 \
        RETRY_CLASSIFIERS=does_not_exist_classify \
        run retry_command "bad-classifier" -- "${stub}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown classifier 'does_not_exist_classify'"* ]]
    [[ "${output}" == *"RETRY_CLASSIFIERS"* ]]
    [ "$(attempt_count)" -eq 1 ]
}

# --- Step 4: shipped default classifiers ------------------------------
#
# Three classifiers ship out of the box, sourced automatically by
# retry.sh from .github/lib/retry-classifiers/. The per-classifier
# tests below feed each documented pattern through the function and
# assert the verdict, plus drive one end-to-end case through
# retry_command per classifier so the auto-source wiring is exercised.

# Helper: build the (stdout_file, stderr_file) pair a classifier
# expects. Most patterns appear on stderr in real failures; we drop
# every fixture into stderr by default and leave stdout empty, which
# matches what docker / curl / dns errors look like.
make_capture() {
    local body="$1"
    local out="${TEST_TMP}/cap_stdout"
    local err="${TEST_TMP}/cap_stderr"
    : > "${out}"
    printf '%s\n' "${body}" > "${err}"
    echo "${out}|${err}"
}

# --- classify_docker_registry ---

@test "classify_docker_registry: dial tcp i/o timeout matches" {
    paths="$(make_capture 'failed to copy: httpReaderSeeker: failed open: dial tcp 1.2.3.4:443: i/o timeout')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_docker_registry 1 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_docker_registry: dial tcp connection refused matches" {
    paths="$(make_capture 'error parsing reference: dial tcp 10.0.0.1:5000: connection refused')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_docker_registry 1 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_docker_registry: failed Head request with dial tcp matches" {
    paths="$(make_capture 'failed to do request: Head "https://registry.example/v2/": dial tcp: lookup registry.example: no such host')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_docker_registry 1 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_docker_registry: received unexpected HTTP 5xx matches" {
    paths="$(make_capture 'received unexpected HTTP status: 503 Service Unavailable')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_docker_registry 1 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_docker_registry: TLS handshake timeout matches" {
    paths="$(make_capture 'net/http: TLS handshake timeout')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_docker_registry 1 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_docker_registry: unexpected EOF matches" {
    paths="$(make_capture 'received unexpected EOF while pulling layer')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_docker_registry 1 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_docker_registry: daemon context deadline matches" {
    # Verbatim wording from the Infrastructure-VM-Ansible feature-02 CI
    # failure that motivated this feature: docker daemon's Go context
    # deadline fires before TCP / TLS report their own timeout.
    paths="$(make_capture 'Error response from daemon: Get "https://registry-1.docker.io/v2/": context deadline exceeded')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_docker_registry 1 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_docker_registry: buildx context deadline matches" {
    # BuildKit / containerd surface form - same root cause, different
    # client path. Both wordings must classify as retriable.
    paths="$(make_capture 'failed to copy: httpReadSeeker: failed open: failed to do request: Head "https://registry-1.docker.io/v2/library/alpine/manifests/3.20": context deadline exceeded')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_docker_registry 1 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_docker_registry: case-insensitive match" {
    # docker's wording is lower-case in practice, but other tools
    # emit "Dial Tcp" or "TLS Handshake Timeout"; the case-insensitive
    # contract keeps the classifier from missing trivially-different
    # spellings.
    paths="$(make_capture 'Dial TCP 1.2.3.4:443: I/O Timeout')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_docker_registry 1 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_docker_registry: clearly-permanent message rejects" {
    # 404 Not Found is the classic "the thing you asked for doesn't
    # exist" - retrying never helps. Must reject.
    paths="$(make_capture 'manifest unknown: 404 Not Found')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_docker_registry 1 "${out}" "${err}"
    [ "${status}" -ne 0 ]
}

@test "classify_docker_registry: Permission denied rejects" {
    paths="$(make_capture 'Permission denied while trying to connect to the Docker daemon')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_docker_registry 1 "${out}" "${err}"
    [ "${status}" -ne 0 ]
}

@test "classify_docker_registry: empty input rejects" {
    paths="$(make_capture '')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_docker_registry 1 "${out}" "${err}"
    [ "${status}" -ne 0 ]
}

@test "classify_docker_registry: defined in retry-classifiers/docker-registry.sh" {
    # Source-of-truth pin: editing the function body in retry.sh by
    # mistake would flip this.
    shopt -s extdebug
    info="$(declare -F classify_docker_registry)"
    shopt -u extdebug
    [[ "${info}" == *"retry-classifiers/docker-registry.sh"* ]]
}

# --- classify_network ---

@test "classify_network: Temporary failure in name resolution matches" {
    paths="$(make_capture 'curl: (6) Could not resolve host: example.com: Temporary failure in name resolution')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_network 6 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_network: Could not resolve host matches" {
    paths="$(make_capture 'curl: (6) Could not resolve host: registry.example')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_network 6 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_network: Connection timed out matches" {
    paths="$(make_capture 'curl: (28) Failed to connect to host port 443: Connection timed out')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_network 28 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_network: Connection reset by peer matches" {
    paths="$(make_capture 'curl: (56) Recv failure: Connection reset by peer')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_network 56 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_network: Network is unreachable matches" {
    paths="$(make_capture 'connect: Network is unreachable')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_network 1 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_network: clearly-permanent message rejects" {
    paths="$(make_capture 'syntax error near unexpected token')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_network 2 "${out}" "${err}"
    [ "${status}" -ne 0 ]
}

@test "classify_network: empty input rejects" {
    paths="$(make_capture '')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_network 1 "${out}" "${err}"
    [ "${status}" -ne 0 ]
}

@test "classify_network: defined in retry-classifiers/network.sh" {
    shopt -s extdebug
    info="$(declare -F classify_network)"
    shopt -u extdebug
    [[ "${info}" == *"retry-classifiers/network.sh"* ]]
}

# --- classify_http_5xx ---

@test "classify_http_5xx: HTTP/1.1 500 matches" {
    paths="$(make_capture '< HTTP/1.1 500 Internal Server Error')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_http_5xx 22 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_http_5xx: HTTP/2 503 matches" {
    paths="$(make_capture '< HTTP/2 503')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_http_5xx 22 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_http_5xx: Server Error: 502 matches" {
    paths="$(make_capture 'Server Error: 502 Bad Gateway')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_http_5xx 1 "${out}" "${err}"
    [ "${status}" -eq 0 ]
}

@test "classify_http_5xx: HTTP 4xx rejects (permanent for the caller)" {
    # 4xx must not retry: the IETF behaviour is "caller error, don't
    # try again until you change something". Pinning this prevents a
    # future regex tweak from accidentally widening the match.
    paths="$(make_capture '< HTTP/1.1 404 Not Found')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_http_5xx 22 "${out}" "${err}"
    [ "${status}" -ne 0 ]
}

@test "classify_http_5xx: HTTP 200 rejects" {
    paths="$(make_capture '< HTTP/1.1 200 OK')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_http_5xx 0 "${out}" "${err}"
    [ "${status}" -ne 0 ]
}

@test "classify_http_5xx: empty input rejects" {
    paths="$(make_capture '')"
    out="${paths%|*}"; err="${paths##*|}"
    run classify_http_5xx 1 "${out}" "${err}"
    [ "${status}" -ne 0 ]
}

@test "classify_http_5xx: defined in retry-classifiers/http-5xx.sh" {
    shopt -s extdebug
    info="$(declare -F classify_http_5xx)"
    shopt -u extdebug
    [[ "${info}" == *"retry-classifiers/http-5xx.sh"* ]]
}

# --- end-to-end via retry_command ---

@test "end-to-end: docker-registry classifier triggers retry on registry timeout" {
    # Stub emits a docker-registry signature on first attempt then
    # succeeds. The classifier is shipped, so no extra sourcing is
    # required - retry.sh autoloaded it.
    stub="$(make_stub 'if (( ATTEMPT < 2 )); then echo "dial tcp 1.2.3.4:443: i/o timeout" >&2; exit 1; fi; exit 0')"
    RETRY_MAX_SECONDS=30 RETRY_BACKOFF_INITIAL_SECONDS=0 RETRY_BACKOFF_JITTER_RATIO=0 \
        RETRY_CLASSIFIERS=classify_docker_registry \
        run retry_command "registry" -- "${stub}"
    [ "${status}" -eq 0 ]
    [ "$(attempt_count)" -eq 2 ]
    [[ "${output}" == *"retriable via classify_docker_registry"* ]]
}

@test "end-to-end: docker-registry classifier triggers retry on daemon context deadline" {
    # Mirrors the registry-timeout case shape; the stub emits the
    # daemon-side wording from the Infrastructure-VM-Ansible feature-02
    # failure that motivated this feature, then succeeds on the second
    # attempt. Proves the new pattern flows end-to-end through the
    # shipped classifier without any caller-side changes.
    stub="$(make_stub 'if (( ATTEMPT < 2 )); then echo "Error response from daemon: Get \"https://registry-1.docker.io/v2/\": context deadline exceeded" >&2; exit 1; fi; exit 0')"
    RETRY_MAX_SECONDS=30 RETRY_BACKOFF_INITIAL_SECONDS=0 RETRY_BACKOFF_JITTER_RATIO=0 \
        RETRY_CLASSIFIERS=classify_docker_registry \
        run retry_command "registry-ctx-deadline" -- "${stub}"
    [ "${status}" -eq 0 ]
    [ "$(attempt_count)" -eq 2 ]
    [[ "${output}" == *"retriable via classify_docker_registry"* ]]
}

@test "end-to-end: docker-registry classifier rejects 404 immediately" {
    stub="$(make_stub 'echo "manifest unknown: 404 Not Found" >&2; exit 1')"
    RETRY_MAX_ATTEMPTS=5 RETRY_MAX_SECONDS=30 \
        RETRY_CLASSIFIERS=classify_docker_registry \
        run retry_command "registry-404" -- "${stub}"
    [ "${status}" -eq 1 ]
    [ "$(attempt_count)" -eq 1 ]
    [[ "${output}" == *"permanent (exit 1)"* ]]
    [[ "${output}" == *"rejected by classify_docker_registry"* ]]
}

@test "end-to-end: combined default classifiers OR together" {
    # Recommended default for dockerised actions. The HTTP 5xx signature
    # must trigger via the third classifier even though the first two
    # reject. Mirrors what step 5 will export as the composite action's
    # default RETRY_CLASSIFIERS value.
    stub="$(make_stub 'if (( ATTEMPT < 2 )); then echo "< HTTP/1.1 502 Bad Gateway" >&2; exit 1; fi; exit 0')"
    RETRY_MAX_SECONDS=30 RETRY_BACKOFF_INITIAL_SECONDS=0 RETRY_BACKOFF_JITTER_RATIO=0 \
        RETRY_CLASSIFIERS=classify_docker_registry:classify_network:classify_http_5xx \
        run retry_command "combined" -- "${stub}"
    [ "${status}" -eq 0 ]
    [ "$(attempt_count)" -eq 2 ]
    [[ "${output}" == *"retriable via classify_http_5xx"* ]]
}

@test "registry: unknown strategy errors with a clear message (exit 2)" {
    # Typo'd strategy must surface as a usage error that names the
    # env var, not as a `command not found` from "$strategy". The
    # error fires on the first retry attempt (after attempt 1 fails),
    # so we need a command that fails at least once.
    stub="$(make_stub 'exit 1')"
    RETRY_MAX_ATTEMPTS=3 RETRY_MAX_SECONDS=30 \
        RETRY_BACKOFF_STRATEGY=does_not_exist_backoff \
        run retry_command "bad-strategy" -- "${stub}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown backoff strategy 'does_not_exist_backoff'"* ]]
    [[ "${output}" == *"RETRY_BACKOFF_STRATEGY"* ]]
    # Only attempted once: the unknown-strategy error short-circuits
    # the retry loop before a second invocation.
    [ "$(attempt_count)" -eq 1 ]
}
