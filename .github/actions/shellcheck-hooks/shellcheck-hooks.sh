#!/usr/bin/env bash
# Strict shellcheck on extension-less git hook files under a directory
# (default `.githooks/`). The canonical SHELLCHECK_FLAGS array is
# sourced from the sibling shellcheck-bash helper so the strict bar
# stays single-sourced.
#
# Modes:
#
#   - Executed:  ./shellcheck-hooks.sh [hooks-dir]
#     Lints every file at the top level of <hooks-dir>. Missing or
#     empty directories are a no-op (notice + exit 0). Requires
#     `shellcheck` on PATH.
#
#   - Sourced is not supported: the sibling helper is the canonical
#     sourced-mode entry for SHELLCHECK_FLAGS.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pull SHELLCHECK_FLAGS via the sibling action's helper. Sourced mode
# returns before its own runner block, so this leaves the array
# defined in the current shell without executing shellcheck.
# shellcheck source=../shellcheck-bash/shellcheck-bash.sh
source "${script_dir}/../shellcheck-bash/shellcheck-bash.sh"

hooks_dir="${1:-.githooks}"

if [[ ! -d "${hooks_dir}" ]]; then
    echo "::notice::${hooks_dir} does not exist, skipping"
    exit 0
fi

# `compgen -G` is the cleanest way to test "does this glob match any
# files" without expanding to the literal pattern on no match.
if ! compgen -G "${hooks_dir}/*" >/dev/null; then
    echo "::notice::no files under ${hooks_dir}/, skipping"
    exit 0
fi

# shellcheck disable=SC2154  # SHELLCHECK_FLAGS set by source above
shellcheck "${SHELLCHECK_FLAGS[@]}" -- "${hooks_dir}"/*
