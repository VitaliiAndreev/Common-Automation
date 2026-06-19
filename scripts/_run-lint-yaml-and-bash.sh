#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2154
# SC2310 (set -e disabled inside functions called from `if !`) is
# intentional here: each check is invoked from `if ! foo; then` so its
# failure is tracked rather than terminating the script - we want every
# check to report, the same way CI's parallel jobs all fire.
# SC2154 (referenced but not assigned): script_dir,
# common_automation_root and repo_root are set by the sourced
# _run-common.sh, which shellcheck cannot follow through the
# command-substitution source path.

# Lint half of the local CI suite, run against the target repo:
#
#   - shellcheck (production bash under .github)
#   - shellcheck (runner bash under scripts/)
#   - shellcheck (git hooks under .githooks/)
#   - check-sh-executable (+x bit on every tracked *.sh)
#   - actionlint (every workflow)
#   - action-validator (every workflow + composite action.yml)
#   - yamllint (plain YAML outside the actionlint/action-validator surface)
#   - ansible-lint (auto-skips when no Ansible content is present)
#
# This is the lint half of ci-yaml.yml plus the shellcheck /
# check-sh-executable jobs of ci-bash.yml; bats (the test half) lives in
# _run-tests-bash.sh, and run-ci-yaml-and-bash.sh runs both. Underscore-
# prefixed because it is a building block invoked by that orchestrator
# and by the per-repo run-lint-yaml-and-bash.sh shims, not a standalone
# entry name.
#
# Uses native shellcheck if available on PATH; otherwise falls back to
# Docker so a developer with only Docker Desktop on Windows still gets a
# working pre-push check. Image pins match CI - update CI and here
# together.

set -euo pipefail

# shellcheck source=./_run-common.sh disable=SC2312
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_run-common.sh"

SHELLCHECK_IMAGE='koalaman/shellcheck:v0.10.0'

# Runs shellcheck with the canonical strict flags over explicit file
# args - native if shellcheck is on PATH, else via the pinned docker
# image. Sources shellcheck-bash.sh only for SHELLCHECK_FLAGS so the
# strict flag set stays single-sourced with CI. Every lint caller below
# shares this; each computes its own file list. Paths are expected
# relative to repo_root - both branches cd there first so the native run
# and the docker mount (-w /work) resolve them identically.
run_shellcheck_flagged() {
    local helper="${common_automation_root}/.github/actions/shellcheck-bash/shellcheck-bash.sh"
    # shellcheck source=../.github/actions/shellcheck-bash/shellcheck-bash.sh
    source "${helper}"

    if command -v shellcheck >/dev/null 2>&1; then
        # shellcheck disable=SC2154  # SHELLCHECK_FLAGS set by source above
        (cd "${repo_root}" && shellcheck "${SHELLCHECK_FLAGS[@]}" -- "$@")
        return $?
    fi

    # Docker fallback. The koalaman/shellcheck image is Alpine without
    # bash, so it cannot run the helper itself - only the flag set is
    # reused. MSYS_NO_PATHCONV stops Git Bash mangling the mount path on
    # Windows. SC2154: shellcheck cannot follow the source directive into
    # the function scope; the array IS set at runtime above.
    # shellcheck disable=SC2154
    (cd "${repo_root}" && MSYS_NO_PATHCONV=1 docker run --rm \
        -v "${repo_root}:/work" -w /work \
        "${SHELLCHECK_IMAGE}" \
        "${SHELLCHECK_FLAGS[@]}" -- "$@")
}

# Lints every *.sh under a path. The native branch runs the same helper
# the composite action runs, keeping find/skip/lint single-sourced with
# CI; the docker branch re-creates the helper's existence/find guards
# (the Alpine image has no bash) and hands the files to the shared
# executor. That find/skip duplication is a small, low-drift copy; the
# flags themselves stay single-sourced.
run_shellcheck_on() {
    local rel_path="$1"
    local label="$2"
    shift 2
    local excludes=("$@")
    local helper="${common_automation_root}/.github/actions/shellcheck-bash/shellcheck-bash.sh"

    echo "=== shellcheck ${label} (${rel_path}) ==="

    if command -v shellcheck >/dev/null 2>&1; then
        # The helper owns the prune logic; pass any exclude basenames
        # through so the native path matches CI exactly.
        (cd "${repo_root}" && bash "${helper}" "${rel_path}" "${excludes[@]}")
        return $?
    fi

    if [[ ! -d "${repo_root}/${rel_path}" ]]; then
        echo "::notice::${rel_path} does not exist, skipping"
        return 0
    fi
    local files
    if (( ${#excludes[@]} )); then
        # Mirror the helper's prune for the docker fallback: drop any
        # directory whose basename matches an exclude before globbing *.sh.
        local name_tests=() d
        for d in "${excludes[@]}"; do
            if (( ${#name_tests[@]} )); then name_tests+=(-o); fi
            name_tests+=(-name "${d}")
        done
        files=$(cd "${repo_root}" && find "${rel_path}" -type d \( "${name_tests[@]}" \) -prune -o -name '*.sh' -print)
    else
        files=$(cd "${repo_root}" && find "${rel_path}" -name '*.sh')
    fi
    if [[ -z "${files}" ]]; then
        echo "::notice::no ${rel_path}/**/*.sh files, skipping"
        return 0
    fi
    # shellcheck disable=SC2086  # word-splitting the file list is intentional
    run_shellcheck_flagged ${files}
}

# Lints the git hooks via the shellcheck-hooks composite's helper - same
# path the CI shellcheck-hooks job runs, so the discovery + skip
# behaviour stays single-sourced with CI. Native shellcheck only; the
# docker fallback below mirrors the helper's logic against the shared
# FLAGS array because the Alpine shellcheck image cannot run bash.
run_shellcheck_hooks() {
    echo "=== shellcheck hooks (.githooks) ==="
    local helper="${common_automation_root}/.github/actions/shellcheck-hooks/shellcheck-hooks.sh"

    if command -v shellcheck >/dev/null 2>&1; then
        (cd "${repo_root}" && bash "${helper}")
        return $?
    fi

    if [[ ! -d "${repo_root}/.githooks" ]]; then
        echo "::notice::no .githooks/, skipping"
        return 0
    fi
    local files
    files=$(cd "${repo_root}" && printf '%s\n' .githooks/*)
    # shellcheck disable=SC2086  # word-splitting the file list is intentional
    run_shellcheck_flagged ${files}
}

run_check_sh_executable() {
    echo "=== check-sh-executable ==="
    # Pure git/awk gate - no Docker fallback needed, it runs anywhere git
    # does. Delegates to the same helper the composite action runs so the
    # local and CI gates cannot drift. Run from repo_root so the git
    # index lookup covers the whole repo.
    local helper="${common_automation_root}/.github/actions/check-sh-executable/check-sh-executable.sh"
    (cd "${repo_root}" && bash "${helper}")
    return $?
}

# Delegates to the composite action's helper so the discovery rules,
# docker image, and pinned version stay single-sourced with CI. The
# helper resolves the image internally via get-actionlint-version.sh -
# no ACTIONLINT_IMAGE constant here, because duplicating it would create
# a second source of truth that could drift from the helper.
run_actionlint() {
    echo "=== actionlint ==="
    local helper="${common_automation_root}/.github/actions/actionlint/actionlint.sh"
    (cd "${repo_root}" && bash "${helper}")
    return $?
}

# Same delegation pattern as run_actionlint: the helper owns discovery,
# the pinned image tag, and the build-on-first-use cache, so no
# action-validator constants leak into this runner.
run_action_validator() {
    echo "=== action-validator ==="
    local helper="${common_automation_root}/.github/actions/action-validator/action-validator.sh"
    (cd "${repo_root}" && bash "${helper}")
    return $?
}

# Same delegation pattern as run_actionlint / run_action_validator: the
# helper owns the exclude list, config resolution, and pinned image, so
# no yamllint constants leak into this runner.
run_yamllint() {
    echo "=== yamllint ==="
    local helper="${common_automation_root}/.github/actions/yamllint/yamllint.sh"
    (cd "${repo_root}" && bash "${helper}")
    return $?
}

# Same delegation pattern: the helper owns the auto-skip detection (no
# Ansible content -> ::notice:: and exit 0), config resolution, and
# pinned image build. Common-Automation itself has no Ansible content,
# so this reports a notice rather than a failure on the local run.
run_ansible_lint() {
    echo "=== ansible-lint ==="
    local helper="${common_automation_root}/.github/actions/ansible-lint/ansible-lint.sh"
    (cd "${repo_root}" && bash "${helper}")
    return $?
}

# Track failures so a shellcheck miss in production does not short-
# circuit before the later checks also report. Same shape as CI's
# parallel jobs - the user sees every problem in one run. `if ! foo;
# then ... fi` (rather than `foo || ...`) is used so set -e stays active
# inside each function.
failures=()

if ! run_shellcheck_on .github production; then
    failures+=("shellcheck-production")
fi
echo

if ! run_shellcheck_on scripts runners; then
    failures+=("shellcheck-runners")
fi
echo

# Domain bash: the repo's own production bash outside .github/scripts
# (e.g. ops/). Scan-by-exclusion mirrors the ci-bash shellcheck-domain
# job so a new production directory is gated automatically. The excludes
# match that job verbatim - the trees already covered by another check
# (.github, scripts, .githooks), the test suites (Tests/tests), and
# vendored or CI-injected trees (.venv, node_modules, .common-automation,
# .git) - so local and CI cannot drift.
if ! run_shellcheck_on . domain \
        .git .github scripts Tests tests .venv node_modules .common-automation .githooks; then
    failures+=("shellcheck-domain")
fi
echo

if ! run_shellcheck_hooks; then
    failures+=("shellcheck-hooks")
fi
echo

if ! run_check_sh_executable; then
    failures+=("check-sh-executable")
fi
echo

if ! run_actionlint; then
    failures+=("actionlint")
fi
echo

if ! run_action_validator; then
    failures+=("action-validator")
fi
echo

if ! run_yamllint; then
    failures+=("yamllint")
fi
echo

if ! run_ansible_lint; then
    failures+=("ansible-lint")
fi
echo

if (( ${#failures[@]} > 0 )); then
    echo "FAILED (lint): ${failures[*]}" >&2
    exit 1
fi
echo "Lint checks passed."
