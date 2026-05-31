#!/usr/bin/env bash
# Runs actionlint over the caller repo's GitHub Actions surface:
# every YAML under .github/workflows/ and every composite action.yml
# under .github/actions/. Single source of truth for the actionlint
# invocation - the composite wrapper (action.yml) and the local
# pre-push runner (scripts/run-tests.sh) both exec this file so the
# discovery rules and docker arguments cannot drift between CI and
# local.
#
# Uses the pinned rhysd/actionlint Docker image - the version comes
# from .github/lib/versions.env via the shared getter so a bump there
# propagates to every consumer in one commit. No native install path
# in the composite action: the image is small, pinned, and avoids a
# per-runner toolchain step.
#
# Skips silently with a `::notice::` when neither directory exists, so
# consumers can wire the workflow in before they have any workflows
# of their own.
#
# Usage: ./actionlint.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

workflows_dir=".github/workflows"
actions_dir=".github/actions"

# Discover files explicitly rather than letting actionlint auto-scan,
# so the absent-directory branch is observable and the same file list
# could be reused by the local runner. -maxdepth on workflows mirrors
# GitHub's own loader (only top-level *.yml is a workflow); -mindepth
# 2 on actions skips any stray action.yml at the actions root. Capture
# to a single newline-delimited string and word-split at use - keeps
# return-value handling visible to shellcheck (SC2312) without an
# inline disable per call.
files=""
if [[ -d "${workflows_dir}" ]]; then
    workflow_files="$(find "${workflows_dir}" -maxdepth 1 -type f \
        \( -name '*.yml' -o -name '*.yaml' \))"
    files+="${workflow_files}"$'\n'
fi
if [[ -d "${actions_dir}" ]]; then
    action_files="$(find "${actions_dir}" -mindepth 2 -type f \
        \( -name 'action.yml' -o -name 'action.yaml' \))"
    files+="${action_files}"$'\n'
fi

# Trim blank lines from optional-branch concatenation before counting.
files="$(printf '%s' "${files}" | sed '/^$/d')"
if [[ -z "${files}" ]]; then
    echo "::notice::no workflow or composite action YAML files, skipping"
    exit 0
fi

version="$("${script_dir}/../../lib/get-actionlint-version.sh")"
image="rhysd/actionlint:${version}"

# MSYS_NO_PATHCONV stops Git Bash on Windows from mangling the mount
# path. -color keeps actionlint's annotations readable when the host
# terminal supports it; GitHub's log viewer renders the ANSI cleanly.
# shellcheck disable=SC2086  # word-splitting the newline-joined list is intentional
MSYS_NO_PATHCONV=1 docker run --rm \
    -v "${PWD}:/repo" \
    -w /repo \
    "${image}" \
    -color \
    ${files}
