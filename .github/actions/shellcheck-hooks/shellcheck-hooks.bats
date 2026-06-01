#!/usr/bin/env bats
# Unit tests for shellcheck-hooks.sh - the strict-shellcheck wrapper for the
# extension-less files under .githooks/. The FLAGS array itself is gated by
# shellcheck-bash.bats; this file covers the hook-specific guards: missing
# dir, empty dir, and the happy path against a real fixture hook.
# Run with: bats actions/shellcheck-hooks/shellcheck-hooks.bats

SCRIPT="${BATS_TEST_DIRNAME}/shellcheck-hooks.sh"

@test "missing hooks dir skips with exit 0" {
    run "${SCRIPT}" "${BATS_TEST_TMPDIR}/no-such-dir"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"does not exist, skipping"* ]]
}

@test "empty hooks dir skips with exit 0" {
    empty_dir="${BATS_TEST_TMPDIR}/empty-hooks"
    mkdir -p "${empty_dir}"
    run "${SCRIPT}" "${empty_dir}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"no files under"* ]]
}

@test "clean hook file lints successfully" {
    hooks_dir="${BATS_TEST_TMPDIR}/hooks"
    mkdir -p "${hooks_dir}"
    cat > "${hooks_dir}/pre-commit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "ok"
EOF
    run "${SCRIPT}" "${hooks_dir}"
    [ "${status}" -eq 0 ]
}

@test "hook with shellcheck violation fails" {
    hooks_dir="${BATS_TEST_TMPDIR}/bad-hooks"
    mkdir -p "${hooks_dir}"
    # Bare [ ] with unquoted variable trips SC2086 at strict severity.
    cat > "${hooks_dir}/pre-commit" <<'EOF'
#!/usr/bin/env bash
foo=$1
if [ -z $foo ]; then
    echo bad
fi
EOF
    run "${SCRIPT}" "${hooks_dir}"
    [ "${status}" -ne 0 ]
}
