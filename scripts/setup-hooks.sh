#!/usr/bin/env bash
# One-time per-clone setup. Wires the repo-checked-in hooks under
# .githooks/ into git so they actually fire on commit.
#
# Without this step, .git/hooks/ stays empty and the repo's
# defensive hooks (e.g. auto-+x on staged .sh files) do nothing.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

# shellcheck source=./_hold-window.sh
source "${script_dir}/_hold-window.sh"
trap hold_window_open EXIT

git -C "${repo_root}" config core.hooksPath .githooks

echo "Hooks configured. core.hooksPath=.githooks"
echo "Commits in this clone will now auto-fix .sh permissions."
