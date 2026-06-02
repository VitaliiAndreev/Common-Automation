#!/usr/bin/env bash
# Runs yamllint over the caller repo's plain YAML surface: every
# *.yml / *.yaml file outside a curated exclude list. The excludes
# cover surfaces already linted by sibling composites
# (.github/workflows/, .github/actions/) and directories that are
# not first-party source (.git/, .venv/, collections/, node_modules/).
# Keeping the exclude list in the composite means every consumer
# inherits the same shape without re-stating it per repo.
#
# Single source of truth for the yamllint invocation - the composite
# wrapper (action.yml) and the local pre-push runner
# (scripts/run-tests.sh) both exec this file so discovery, excludes,
# config resolution, and docker arguments cannot drift between CI
# and local.
#
# Uses a pinned in-repo Docker image - the version comes from
# .github/lib/versions.env via the shared getter so a bump there
# propagates to every consumer in one commit. No native install path
# in the composite action: the image is small, pinned, and avoids a
# per-runner toolchain step (same rationale as actionlint).
#
# Distribution: the upstream cytopia/yamllint image only tags by
# major version, which cannot satisfy the repo's exact-version pin
# contract. To keep the same docker-only ergonomics actionlint has,
# this action ships its own Dockerfile that pip-installs the pinned
# yamllint==<version> from PyPI at build time. The image is tagged
# github-common/yamllint:<version> and only rebuilt when the pinned
# tag changes - subsequent runs reuse the cached image (same shape
# action-validator uses for the same reason).
#
# Config resolution: a consumer-supplied .yamllint / .yamllint.yml /
# .yamllint.yaml at the repo root wins (yamllint auto-discovers it
# when run from there). Otherwise the bundled yamllint.config.yml
# next to this script applies - the strict `default` ruleset, so
# every consumer gets the same bar by default.
#
# Skips silently with a `::notice::` when no eligible YAML files
# exist, so consumers can wire the workflow in before they have any
# plain YAML of their own.
#
# Usage: ./yamllint.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the retry primitive via the locked env-var-primary /
# relative-path-fallback contract from problem.md: in a workflow the
# composite's action.yml exports GHCOMMON_REPO_ROOT so the path is
# authoritative even if the action directory ever moves; outside
# Actions (the pre-push runner, ad-hoc invocations) the env var is
# unset and SCRIPT_DIR/../../.. resolves to the same file as long as
# the repo layout is intact.
repo_root="${GHCOMMON_REPO_ROOT:-$(cd "${script_dir}/../../.." && pwd)}"
# shellcheck source=../../lib/retry.sh
source "${repo_root}/.github/lib/retry.sh"

# Directories the action never lints. Workflows and composite
# actions are covered by actionlint / action-validator against their
# proper schemas; the remaining entries are non-source trees that
# happen to contain YAML (virtualenvs, Ansible Galaxy collections,
# vendored node_modules) which we do not want to gate CI on.
exclude_dirs=(
    .git
    .venv
    collections
    node_modules
    .github/workflows
    .github/actions
    # Staging dir created by ci-yaml.yml's conditional sparse
    # checkout (this composite only runs in that workflow's job).
    # Holds a copy of GitHub-Common's action tree and is not the
    # consumer's concern; skip.
    .github-common
)

# Build a `find` prune expression from the exclude list so file
# discovery and the skip-when-empty branch stay in one place.
prune_expr=()
for d in "${exclude_dirs[@]}"; do
    if (( ${#prune_expr[@]} > 0 )); then
        prune_expr+=(-o)
    fi
    prune_expr+=(-path "./${d}")
done

# SC2312: `find` inside a process substitution masks its exit status.
# Tolerated here - find only fails on unreadable paths inside the repo
# checkout (which would break every other check too), and the empty-
# result branch below already covers the "nothing found" case.
# shellcheck disable=SC2312
mapfile -t files < <(
    find . \( "${prune_expr[@]}" \) -prune \
        -o -type f \( -name '*.yml' -o -name '*.yaml' \) -print
)

if (( ${#files[@]} == 0 )); then
    echo "::notice::no plain YAML files outside excluded paths, skipping"
    exit 0
fi

# Consumer-config wins so a downstream repo can tighten or relax the
# bar. yamllint resolves these names natively when -c is omitted; we
# detect explicitly here so the bundled-config branch is observable.
consumer_config=""
for candidate in .yamllint .yamllint.yml .yamllint.yaml; do
    if [[ -f "${candidate}" ]]; then
        consumer_config="${candidate}"
        break
    fi
done

version="$("${script_dir}/../../lib/get-yamllint-version.sh")"
image="github-common/yamllint:${version}"

# Build the pinned image on first use; the version-suffixed tag
# means a bump invalidates the cache automatically and a no-op run
# is just a cheap `docker image inspect`. stderr is left visible so
# a build failure (e.g. PyPI unreachable) surfaces.
if ! docker image inspect "${image}" >/dev/null 2>&1; then
    echo "::notice::building ${image} (first run for this version)"
    # Wrap the build in the retry primitive so a transient registry
    # blip doesn't fail the run - default classifiers cover docker
    # registry, network, and HTTP 5xx. `docker run` (below) is NOT
    # wrapped: a lint failure is a real failure, not transient. The
    # `|| exit $?` form lets `set -e` ignore the inner non-zero
    # attempts (errexit-inheritance rule) so retry_command can loop.
    RETRY_CLASSIFIERS="${RETRY_CLASSIFIERS:-classify_docker_registry:classify_network:classify_http_5xx}" \
        retry_command "yamllint docker build" -- \
        docker build \
            --build-arg "VERSION=${version}" \
            -t "${image}" \
            "${script_dir}" \
        || exit $?
fi

# Two mounts: the repo at /work (where yamllint sees the files and
# any consumer config) and the action dir at /action (where the
# bundled config lives - read-only so we cannot accidentally mutate
# it from inside the container). MSYS_NO_PATHCONV stops Git Bash on
# Windows mangling either mount path.
config_args=()
if [[ -z "${consumer_config}" ]]; then
    config_args=(-c /action/yamllint.config.yml)
fi

MSYS_NO_PATHCONV=1 docker run --rm \
    -v "${PWD}:/work" -w /work \
    -v "${script_dir}:/action:ro" \
    "${image}" \
    "${config_args[@]}" \
    -- "${files[@]}"
