#!/usr/bin/env bash
# Single source of truth for "which tracked .sh files are missing the
# executable bit in the git index". Referenced by this action's
# composite wrapper (action.yml), the local pre-push runner
# (scripts/run-tests.sh), and the pre-commit auto-fix hook
# (.githooks/pre-commit) so the detection rule cannot drift between
# them.
#
# Why this matters: files authored on Windows land in git as mode
# 0644 by default. On Linux runners that breaks `bats run` (EACCES ->
# exit 126) and any other direct script execution. The bats job
# catches this too, but its symptom ("every test fails with status
# mismatch") is opaque; this check gives the same failure a one-line,
# copy-pasteable fix.
#
# Modes:
#
#   - Executed:  ./check-sh-executable.sh
#     Repo-wide gate. Scans every tracked .sh and exits non-zero,
#     emitting a CI ::error::, if any lacks +x. No path input by
#     design: the +x bar applies to every tracked .sh, not a subtree.
#
#   - Sourced:   source ./check-sh-executable.sh
#     Defines list_sh_missing_x for callers that need the detection
#     without the gate's exit/error behaviour (e.g. the pre-commit
#     hook, which fixes per-file rather than failing).

set -euo pipefail

# Prints tracked .sh files whose git-index mode is 100644 (missing
# +x), one path per line. `git ls-files -s` emits "<mode> <object>
# <stage>\t<path>"; 100644 is a non-executable regular file, 100755
# carries +x. With no args, scans every tracked .sh; with explicit
# path args, checks only those (caller restricts to .sh itself).
#
# Runs git from the repo top so the result is the same wherever the
# caller is invoked. git pathspecs and ls-files output are relative to
# the current directory, so a plain `*.sh` scan launched from a subdir
# (e.g. the fix-permissions runner double-clicked in scripts/) would
# silently see only that subtree and miss the rest of the repo. cd-ing
# to the toplevel makes the no-arg scan truly repo-wide and the emitted
# paths repo-root-relative for every caller.
# SC2120: args are optional by design - the gate calls with none
# (whole repo), the hook passes specific staged paths.
# shellcheck disable=SC2120
list_sh_missing_x() {
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"
    if (( $# == 0 )); then
        (cd "${repo_root}" && git ls-files -s -- '*.sh')
    else
        (cd "${repo_root}" && git ls-files -s -- "$@")
    fi | awk '$1 == "100644" { print $4 }'
}

# Sourced? Expose the detector and return - skip the gate.
# BASH_SOURCE[0] differs from $0 only when this file is sourced.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

# SC2119: intentional no-arg call - the gate scans the whole repo.
# shellcheck disable=SC2119
missing="$(list_sh_missing_x)"
if [[ -n "${missing}" ]]; then
    echo "::error::these .sh files are missing +x in the git index:"
    echo "${missing}"
    echo "Fix with: git update-index --chmod=+x <path>"
    exit 1
fi
