#!/usr/bin/env bash
# shellcheck disable=SC2310
# SC2310 (set -e disabled inside functions called from `if !`) is
# intentional here: each check is invoked from `if ! foo; then` so
# its failure is tracked rather than terminating the script - we want
# every check to report, the same way CI's parallel jobs all fire.

# Runs the same checks as .github/workflows/ci-bash.yml against this
# repo, so failures are caught locally rather than on the remote:
#
#   - shellcheck (production bash under .github)
#   - shellcheck (runner bash under scripts/)
#   - shellcheck (git hooks under .githooks/)
#   - check-sh-executable (+x bit on every tracked *.sh)
#   - bats (every *.bats suite in the repo)
#
# Uses native shellcheck / bats if available on PATH; otherwise falls
# back to Docker so a developer with only Docker Desktop on Windows
# still gets a working pre-push check. Both images are pinned to the
# same versions as CI - update CI and here together.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

# Resolve the canonical bats version through the same accessor the
# composite action uses, so local and CI cannot drift. The getter
# reads .github/lib/versions.env - the single source of truth.
BATS_IMAGE="bats/bats:$("${repo_root}/.github/lib/get-bats-version.sh")"
SHELLCHECK_IMAGE='koalaman/shellcheck:v0.10.0'

# shellcheck source=./_hold-window.sh
source "${script_dir}/_hold-window.sh"
trap hold_window_open EXIT

# Runs shellcheck with the canonical strict flags over explicit file
# args - native if shellcheck is on PATH, else via the pinned docker
# image. Sources shellcheck-bash.sh only for SHELLCHECK_FLAGS so the
# strict flag set stays single-sourced with CI. Every lint caller
# below shares this; each computes its own file list. Paths are
# expected relative to repo_root - both branches cd there first so the
# native run and the docker mount (-w /work) resolve them identically.
run_shellcheck_flagged() {
    local helper="${repo_root}/.github/actions/shellcheck-bash/shellcheck-bash.sh"
    # shellcheck source=../.github/actions/shellcheck-bash/shellcheck-bash.sh
    source "${helper}"

    if command -v shellcheck >/dev/null 2>&1; then
        # shellcheck disable=SC2154  # SHELLCHECK_FLAGS set by source above
        (cd "${repo_root}" && shellcheck "${SHELLCHECK_FLAGS[@]}" -- "$@")
        return $?
    fi

    # Docker fallback. The koalaman/shellcheck image is Alpine without
    # bash, so it cannot run the helper itself - only the flag set is
    # reused. MSYS_NO_PATHCONV stops Git Bash mangling the mount path
    # on Windows. SC2154: shellcheck cannot follow the source directive
    # into the function scope; the array IS set at runtime above.
    # shellcheck disable=SC2154
    (cd "${repo_root}" && MSYS_NO_PATHCONV=1 docker run --rm \
        -v "${repo_root}:/work" -w /work \
        "${SHELLCHECK_IMAGE}" \
        "${SHELLCHECK_FLAGS[@]}" -- "$@")
}

# Lints every *.sh under a path. The native branch runs the same
# helper the composite action runs, keeping find/skip/lint
# single-sourced with CI; the docker branch re-creates the helper's
# existence/find guards (the Alpine image has no bash) and hands the
# files to the shared executor. That find/skip duplication is a small,
# low-drift copy; the flags themselves stay single-sourced.
run_shellcheck_on() {
    local rel_path="$1"
    local label="$2"
    local helper="${repo_root}/.github/actions/shellcheck-bash/shellcheck-bash.sh"

    echo "=== shellcheck ${label} (${rel_path}) ==="

    if command -v shellcheck >/dev/null 2>&1; then
        (cd "${repo_root}" && bash "${helper}" "${rel_path}")
        return $?
    fi

    if [[ ! -d "${repo_root}/${rel_path}" ]]; then
        echo "::notice::${rel_path} does not exist, skipping"
        return 0
    fi
    local files
    files=$(cd "${repo_root}" && find "${rel_path}" -name '*.sh')
    if [[ -z "${files}" ]]; then
        echo "::notice::no ${rel_path}/**/*.sh files, skipping"
        return 0
    fi
    # shellcheck disable=SC2086  # word-splitting the file list is intentional
    run_shellcheck_flagged ${files}
}

# Lints the git hooks. They have no .sh extension (git requires exact
# filenames), so the helper's *.sh discovery cannot find them - expand
# the hook list explicitly (relative to repo_root) and lint via the
# shared executor, mirroring CI's shellcheck-hooks job.
run_shellcheck_hooks() {
    echo "=== shellcheck hooks (.githooks) ==="
    local files
    files=$(cd "${repo_root}" && printf '%s\n' .githooks/*)
    # shellcheck disable=SC2086  # word-splitting the file list is intentional
    run_shellcheck_flagged ${files}
}

run_check_sh_executable() {
    echo "=== check-sh-executable ==="
    # Pure git/awk gate - no Docker fallback needed, it runs anywhere
    # git does. Delegates to the same helper the composite action runs
    # so the local and CI gates cannot drift. Run from repo_root so the
    # git index lookup covers the whole repo.
    local helper="${repo_root}/.github/actions/check-sh-executable/check-sh-executable.sh"
    (cd "${repo_root}" && bash "${helper}")
    return $?
}

run_bats() {
    echo "=== bats ==="
    if command -v bats >/dev/null 2>&1; then
        bats --pretty --recursive "${repo_root}"
        return $?
    fi
    if ! command -v docker >/dev/null 2>&1; then
        echo "Neither bats nor docker is available. Install one to run tests." >&2
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "Docker CLI is installed but the daemon is not running." >&2
        return 1
    fi
    # -e TERM=xterm: --pretty calls tput for cursor positioning; tput
    # exits non-zero without TERM, which crashes bats.
    MSYS_NO_PATHCONV=1 docker run --rm \
        -e TERM=xterm \
        -v "${repo_root}:/code" \
        "${BATS_IMAGE}" \
        --pretty --recursive /code
}

# Track failures so a shellcheck miss in production does not short-
# circuit before runner-bash and bats also report. Same shape as CI's
# parallel jobs - the user sees every problem in one run. `if ! foo;
# then ... fi` (rather than `foo || ...`) is used so set -e stays
# active inside each function.
failures=()

if ! run_shellcheck_on .github production; then
    failures+=("shellcheck-production")
fi
echo

if ! run_shellcheck_on scripts runners; then
    failures+=("shellcheck-runners")
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

if ! run_bats; then
    failures+=("bats")
fi
echo

if (( ${#failures[@]} > 0 )); then
    echo "FAILED: ${failures[*]}" >&2
    exit 1
fi
echo "All checks passed."
