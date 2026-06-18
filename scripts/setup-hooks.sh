#!/usr/bin/env bash
# One-time per-clone setup. Wires the repo-checked-in hooks under
# .githooks/ into git so they actually fire on commit.
#
# Without this step, .git/hooks/ stays empty and the repo's
# defensive hooks (e.g. auto-+x on staged .sh files) do nothing.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The repo whose hooks get wired up. Defaults to this repo
# (Common-Automation); a consuming repo's thin setup-hooks.sh exports
# COMMON_AUTOMATION_TARGET_REPO so the same one-time wiring applies to THAT repo
# - same single-source reuse as run-ci-yaml-and-bash.sh / fix-permissions.sh. The
# target supplies its own .githooks/ (a thin pre-commit that delegates
# back here); this just points git at it.
repo_root="${COMMON_AUTOMATION_TARGET_REPO:-$(cd "${script_dir}/.." && pwd)}"

# shellcheck source=./_hold-window.sh
source "${script_dir}/_hold-window.sh"
trap hold_window_open EXIT

# Green for success / already-done notices. Emitted only on a tty (and only
# when tput knows how) so piped/redirected output stays plain ASCII.
green=""
reset=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    green="$(tput setaf 2 2>/dev/null || true)"
    reset="$(tput sgr0 2>/dev/null || true)"
fi

# Idempotent: if this clone already points at .githooks there is nothing to
# wire, so say so (in green) and skip the redundant git config write.
current="$(git -C "${repo_root}" config --get core.hooksPath || true)"
if [[ "${current}" == ".githooks" ]]; then
    echo "${green}No need - hooks have been configured already for ${repo_root}. core.hooksPath=.githooks${reset}"
    exit 0
fi

git -C "${repo_root}" config core.hooksPath .githooks

echo "${green}Hooks configured for ${repo_root}. core.hooksPath=.githooks${reset}"
echo "Commits in this clone will now auto-fix .sh permissions."
