#!/usr/bin/env bash
# Write-side counterpart to the read-only CI gate
# (.github/actions/check-sh-executable/check-sh-executable.sh): the
# gate fails on .sh files missing +x, this re-stages them with +x.
# Both share the same detector (list_sh_missing_x) so they cannot
# disagree about what counts as "missing +x".
#
# Why a fix exists at all: files authored on Windows land in git as
# mode 0644, which breaks direct execution on Linux runners. This is
# the single place the fix is implemented - reused by the pre-commit
# hook (staged files) and the fix-permissions runner (whole repo).
#
# Lives under .github/lib (shared shell helpers), not inside the
# check-sh-executable action folder, so the gate action stays a pure,
# self-contained CI building block, and so the hook can depend on
# .github alone rather than reaching into the maintainer-only scripts/
# tree.
#
# Modes:
#
#   - Executed, no args:   fix every tracked .sh missing +x (repo-wide).
#   - Executed, path args:  fix only those paths (caller restricts to
#     .sh; used by the hook for the set of staged files).
#   - Sourced:  defines fix_sh_executable for callers that want the
#     function without running it (the hook and the runner both source
#     this file).

set -euo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pull in list_sh_missing_x - the single source of truth for the
# missing-+x rule, shared with the CI gate. ../ climbs from lib to the
# .github root, then into the action folder where the detector lives.
# shellcheck source=../actions/check-sh-executable/check-sh-executable.sh
source "${lib_dir}/../actions/check-sh-executable/check-sh-executable.sh"

# Re-stages with +x every .sh that list_sh_missing_x reports for the
# given args (no args = whole repo). Prints each fix; a no-op when
# nothing needs fixing. Returns 0 either way.
fix_sh_executable() {
    local missing
    missing="$(list_sh_missing_x "$@")"
    if [[ -z "${missing}" ]]; then
        return 0
    fi
    while IFS= read -r f; do
        echo "fixing +x on ${f}"
        git update-index --chmod=+x "${f}"
    done <<< "${missing}"
}

# Sourced? Expose the function and return - skip the run.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

fix_sh_executable "$@"
