#!/usr/bin/env bash
# Composite-action entry point for the retry primitive. Reads the
# action's three inputs from RETRY_COMMAND / RETRY_MAX_ATTEMPTS /
# RETRY_CLASSIFIERS (already exported by action.yml), resolves
# `.github/lib/retry.sh`, and hands off to `retry_command`.
#
# Kept as a real `.sh` (rather than inline in action.yml) so the bats
# suite can drive the exact same entry point with seeded env - mirroring
# the convention every other composite in this repo uses (ansible-lint,
# yamllint, actionlint, action-validator).
#
# Primitive resolution follows the locked env-var-primary /
# relative-path-fallback contract from problem.md:
#   - In a workflow, action.yml sets COMMON_AUTOMATION_REPO_ROOT from
#     `${{ github.action_path }}/../../..` so the resolved path is
#     authoritative even if the action directory ever moves.
#   - Outside Actions (local pre-push runner, ad-hoc `bash ...`), the
#     env var is unset and the SCRIPT_DIR-relative fallback resolves
#     to the same file as long as the repo layout is intact.

# Deliberately no `set -e`. The primitive's inner loop catches the
# wrapped command's non-zero exit via `exit_code=$?` immediately after
# a bare `"$@"`; with `set -e` propagating into the sourced function,
# the first failed attempt would abort the script before the loop got
# to inspect the exit and decide to retry. `-u` and `pipefail` are
# still on - they don't interact with the loop's failure path.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${COMMON_AUTOMATION_REPO_ROOT:-$(cd "${script_dir}/../../.." && pwd)}"

# Required input. action.yml marks `command` as required, but a direct
# invocation (tests, local runs) might forget - surface that as a clear
# usage error rather than letting `retry_command` complain about its
# own argv shape.
if [[ -z "${RETRY_COMMAND:-}" ]]; then
    echo "retry-action: RETRY_COMMAND is required (set the action's 'command' input)" >&2
    exit 2
fi

# shellcheck source=../../lib/retry.sh
source "${repo_root}/.github/lib/retry.sh"

# `bash -lc` lets the input be a normal shell expression (pipes,
# redirects, &&/||) - matches what a workflow author would write in a
# plain `run:` block. The op-name is the command string itself so the
# primitive's `retry:` diagnostics name the failing operation in terms
# the workflow author recognises.
retry_command "${RETRY_COMMAND}" -- bash -lc "${RETRY_COMMAND}"
