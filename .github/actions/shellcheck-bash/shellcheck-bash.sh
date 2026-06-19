#!/usr/bin/env bash
# Strict shellcheck on every .sh under a given path. Single source of
# truth for the strict-bash lint rules - referenced by both this
# action's composite wrapper (action.yml) and the local pre-push
# runner (scripts/_run-lint-yaml-and-bash.sh) so the bar cannot drift between CI
# and local.
#
# Modes:
#
#   - Executed:  ./shellcheck-bash.sh <scan-path> [exclude-dir...]
#     Runs shellcheck against the path. Requires shellcheck on PATH.
#     Any <exclude-dir> names are pruned from the walk (matched by
#     directory basename at any depth). This lets a scan-path of '.'
#     cover a repo's own production bash while skipping trees that are
#     linted by another job (.github, scripts), test-only (Tests), or
#     vendored (.venv, node_modules, the .common-automation CI checkout).
#
#   - Sourced:   source ./shellcheck-bash.sh
#     Defines SHELLCHECK_FLAGS for callers that need to invoke the
#     linter through a different runtime (e.g. via Docker when the
#     binary is not installed locally). The caller is then
#     responsible for `find` and the docker invocation.

set -euo pipefail

SHELLCHECK_FLAGS=(--shell=bash --severity=style --enable=all -x -e SC1091)

# Sourced? Just expose the flags array and return - skip the runner.
# BASH_SOURCE[0] differs from $0 only when this file is sourced.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

if (( $# < 1 )); then
    echo "Usage: $0 <scan-path> [exclude-dir...]" >&2
    exit 2
fi
scan_path="$1"
shift
excludes=("$@")

if [[ ! -d "${scan_path}" ]]; then
    echo "::notice::${scan_path} does not exist, skipping"
    exit 0
fi

# Discover *.sh under scan_path. With excludes, prune any directory whose
# basename matches one - kept as a separate branch from the plain walk so
# the no-exclude callers (.github, scripts) behave exactly as before.
if (( ${#excludes[@]} )); then
    name_tests=()
    for d in "${excludes[@]}"; do
        (( ${#name_tests[@]} )) && name_tests+=(-o)
        name_tests+=(-name "${d}")
    done
    files="$(find "${scan_path}" -type d \( "${name_tests[@]}" \) -prune -o -name '*.sh' -print)"
else
    files="$(find "${scan_path}" -name '*.sh')"
fi
if [[ -z "${files}" ]]; then
    echo "::notice::no ${scan_path}/**/*.sh files, skipping"
    exit 0
fi

# shellcheck disable=SC2086  # word-splitting intentional
shellcheck "${SHELLCHECK_FLAGS[@]}" -- ${files}
