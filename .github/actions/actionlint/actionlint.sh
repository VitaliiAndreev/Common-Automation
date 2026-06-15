#!/usr/bin/env bash
# Runs actionlint over the caller repo's GitHub Actions surface:
# every workflow YAML under .github/workflows/. Composite actions
# under .github/actions/ are linted transitively - actionlint follows
# `uses: ./.github/actions/...` references from the workflows it
# checks. Passing composite action.yml files as positional args does
# NOT work: actionlint treats positional args as workflows and rejects
# the composite schema ("jobs section is missing", etc.). Discovery is
# therefore workflow-only here.
#
# Single source of truth for the actionlint invocation - the composite
# wrapper (action.yml) and the local pre-push runner
# (scripts/run-tests.sh) both exec this file so the discovery rules
# and docker arguments cannot drift between CI and local.
#
# Uses the pinned rhysd/actionlint Docker image - the version comes
# from .github/lib/versions.env via the shared getter so a bump there
# propagates to every consumer in one commit. No native install path
# in the composite action: the image is small, pinned, and avoids a
# per-runner toolchain step.
#
# Skips silently with a `::notice::` when no workflows exist, so
# consumers can wire the workflow in before they have any workflows
# of their own.
#
# Usage: ./actionlint.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the retry primitive via the locked env-var-primary /
# relative-path-fallback contract from problem.md: in a workflow the
# composite's action.yml exports COMMON_AUTOMATION_REPO_ROOT so the path is
# authoritative even if the action directory ever moves; outside
# Actions (the pre-push runner, ad-hoc invocations) the env var is
# unset and SCRIPT_DIR/../../.. resolves to the same file as long as
# the repo layout is intact.
repo_root="${COMMON_AUTOMATION_REPO_ROOT:-$(cd "${script_dir}/../../.." && pwd)}"
# shellcheck source=../../lib/retry.sh
source "${repo_root}/.github/lib/retry.sh"

workflows_dir=".github/workflows"

# -maxdepth 1 mirrors GitHub's own loader - only top-level *.yml under
# .github/workflows/ is a workflow. Explicit discovery (rather than
# letting actionlint auto-scan) keeps the absent-directory skip branch
# observable and makes "what we lint" auditable in one place.
files=""
if [[ -d "${workflows_dir}" ]]; then
    files="$(find "${workflows_dir}" -maxdepth 1 -type f \
        \( -name '*.yml' -o -name '*.yaml' \))"
fi

if [[ -z "${files}" ]]; then
    echo "::notice::no workflow YAML files under ${workflows_dir}, skipping"
    exit 0
fi

version="$("${script_dir}/../../lib/get-actionlint-version.sh")"
image="rhysd/actionlint:${version}"

# Pull the pinned upstream image explicitly on first use rather than
# letting `docker run` pull implicitly. Two reasons: it isolates the
# registry-pull transient surface from the lint invocation (so retries
# cannot mask a real lint failure - see step 8 of plan 22), and it
# matches the build-once shape used by the sibling lint actions
# (yamllint / ansible-lint / action-validator). `docker image inspect`
# acts as the cache guard so a no-op run is just a cheap metadata
# lookup. Unlike the siblings there is no Dockerfile here - actionlint
# ships an official image, so the work to wrap is the pull, not a build.
if ! docker image inspect "${image}" >/dev/null 2>&1; then
    echo "::notice::pulling ${image} (first run for this version)"
    RETRY_CLASSIFIERS="${RETRY_CLASSIFIERS:-classify_docker_registry:classify_network:classify_http_5xx}" \
        retry_command "actionlint docker pull" -- \
        docker pull "${image}" \
        || exit $?
fi

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
