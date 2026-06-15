#!/usr/bin/env bash
# Repo-wide manual fix for the executable bit on tracked .sh files.
#
# The pre-commit hook only fixes files in a given commit, and only in
# clones where setup-hooks.sh has been run. This runner re-stages +x
# on every tracked .sh missing it across the whole repo - the way to
# heal files that slipped in before the hook existed or was installed,
# which is exactly what the CI gate (check-sh-executable) flags.
#
# Reuses the shared fix engine (.github/lib/fix-sh-executable.sh) so
# the manual path and the hook apply an identical fix.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The repo whose tracked .sh files get fixed. Defaults to this repo
# (Common-Automation); a consuming repo's thin fix-permissions.sh exports
# COMMON_AUTOMATION_TARGET_REPO so the shared fix engine heals THAT repo instead
# - same single-source reuse as run-tests.sh. The fix engine itself
# always lives here, sourced relative to script_dir below.
target_repo="${COMMON_AUTOMATION_TARGET_REPO:-$(cd "${script_dir}/.." && pwd)}"

# Keep the window open on an Explorer double-click (no-op under the
# .bat launcher, which sets COMMON_AUTOMATION_NO_PAUSE=1, and in CI/pipes).
# shellcheck source=./_hold-window.sh
source "${script_dir}/_hold-window.sh"
trap hold_window_open EXIT

# shellcheck source=../.github/lib/fix-sh-executable.sh
source "${script_dir}/../.github/lib/fix-sh-executable.sh"

# fix_sh_executable resolves the git toplevel from the current dir, so
# run it inside the target repo to scope the fix there.
echo "=== fixing +x on tracked .sh files in ${target_repo} ==="
(cd "${target_repo}" && fix_sh_executable)
echo "Done. Review staged mode changes with: git status"
