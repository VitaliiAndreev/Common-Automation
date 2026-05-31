#!/usr/bin/env bash
# Prints the action-validator version to use: an explicit override
# argument wins, otherwise the canonical ACTION_VALIDATOR_VERSION from
# the adjacent versions.env. Single accessor for the action-validator
# version - the composite action and the local runner both call this
# rather than parsing versions.env themselves, so the source format
# stays in one place.
#
# Usage: get-action-validator-version.sh [override]
#   [override]  Optional explicit version; echoed verbatim when
#               non-empty, in which case versions.env is not read.

set -euo pipefail

override="${1:-}"
if [[ -n "${override}" ]]; then
    printf '%s\n' "${override}"
    exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./versions.env
source "${script_dir}/versions.env"

# set -u makes a missing ACTION_VALIDATOR_VERSION fail loudly rather
# than printing an empty version. SC2154: shellcheck cannot follow the
# source to see the assignment, but the runtime guarantee above covers
# it.
# shellcheck disable=SC2154
printf '%s\n' "${ACTION_VALIDATOR_VERSION}"
