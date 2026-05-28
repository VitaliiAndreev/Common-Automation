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

# Keep the window open on an Explorer double-click (no-op under the
# .bat launcher, which sets GHCOMMON_NO_PAUSE=1, and in CI/pipes).
# shellcheck source=./_hold-window.sh
source "${script_dir}/_hold-window.sh"
trap hold_window_open EXIT

# shellcheck source=../.github/lib/fix-sh-executable.sh
source "${script_dir}/../.github/lib/fix-sh-executable.sh"

echo "=== fixing +x on tracked .sh files ==="
fix_sh_executable
echo "Done. Review staged mode changes with: git status"
