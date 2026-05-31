#!/usr/bin/env bash
# Runs action-validator over the caller repo's GitHub Actions surface:
# every workflow YAML under .github/workflows/ AND every composite
# action.yml under .github/actions/*/ (mindepth 2 - a stray
# .github/actions/action.yml is ignored, matching the discovery rule
# the actionlint helper uses for workflows). action-validator validates
# both file kinds against their respective official schemas, so we feed
# it both in one invocation.
#
# Single source of truth for the action-validator invocation - the
# composite wrapper (action.yml) and the local pre-push runner
# (scripts/run-tests.sh) both exec this file so the discovery rules
# and docker arguments cannot drift between CI and local.
#
# Distribution: mpalmer/action-validator has no official Docker image
# and its npm channel lags the GitHub releases (only 0.6.0 vs 0.9.0
# pinned). To keep the same docker-only ergonomics actionlint has, this
# action ships its own Dockerfile that pulls the pinned linux binary
# from GitHub releases at build time. The image is tagged
# github-common/action-validator:<version> and only rebuilt when the
# pinned tag changes - subsequent runs reuse the cached image.
#
# Skips silently with a `::notice::` when neither workflows nor
# composite actions exist, so consumer repos with only one of those
# surfaces still work without configuration.
#
# Usage: ./action-validator.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

workflows_dir=".github/workflows"
actions_dir=".github/actions"

# Explicit discovery (rather than glob expansion in the docker
# command) keeps the absent-directory skip branch observable and makes
# "what we validate" auditable in one place. Workflows: top-level only
# (-maxdepth 1) mirrors GitHub's loader. Composite actions: -mindepth 2
# so .github/actions/<name>/action.yml is picked up but a stray
# .github/actions/action.yml is not.
files=()
# SC2312: collect each find's output into a variable first so its exit
# status is observable to set -e, then feed the variable into the loop.
# Reading directly from a process substitution would mask a find failure.
if [[ -d "${workflows_dir}" ]]; then
    workflow_hits="$(find "${workflows_dir}" -maxdepth 1 -type f \
        \( -name '*.yml' -o -name '*.yaml' \))"
    while IFS= read -r f; do
        [[ -n "${f}" ]] && files+=("${f}")
    done <<< "${workflow_hits}"
fi
if [[ -d "${actions_dir}" ]]; then
    action_hits="$(find "${actions_dir}" -mindepth 2 -type f \
        \( -name 'action.yml' -o -name 'action.yaml' \))"
    while IFS= read -r f; do
        [[ -n "${f}" ]] && files+=("${f}")
    done <<< "${action_hits}"
fi

if (( ${#files[@]} == 0 )); then
    echo "::notice::no workflow or composite action YAML found, skipping"
    exit 0
fi

version="$("${script_dir}/../../lib/get-action-validator-version.sh")"
image="github-common/action-validator:${version}"

# Build the pinned image on first use; the version-suffixed tag means
# a bump invalidates the cache automatically and a no-op run is just a
# cheap `docker image inspect`. stderr is left visible so a build
# failure (e.g. network error fetching the release binary) surfaces.
if ! docker image inspect "${image}" >/dev/null 2>&1; then
    echo "::notice::building ${image} (first run for this version)"
    docker build \
        --build-arg "VERSION=${version}" \
        -t "${image}" \
        "${script_dir}"
fi

# MSYS_NO_PATHCONV=1 stops Git Bash on Windows from mangling the mount
# path. The discovered file list is passed as positional args -
# action-validator picks the schema (workflow vs composite) per file.
MSYS_NO_PATHCONV=1 docker run --rm \
    -v "${PWD}:/repo" \
    -w /repo \
    "${image}" \
    "${files[@]}"
