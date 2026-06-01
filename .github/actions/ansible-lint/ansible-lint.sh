#!/usr/bin/env bash
# Runs ansible-lint over the caller repo's Ansible content (playbooks,
# roles, ansible.cfg). Auto-skips with a `::notice::` when none of
# `ansible.cfg`, `playbooks/`, or `roles/` exists at the repo root -
# the composite is wired into every consumer's ci-yaml.yml so it must
# no-op silently on repos with no Ansible content (e.g. GitHub-Common
# itself) rather than fail or print noise.
#
# Single source of truth for the ansible-lint invocation - the
# composite wrapper (action.yml) and the local pre-push runner
# (scripts/run-tests.sh) both exec this file so the detection rules,
# config resolution, and docker arguments cannot drift between CI and
# local.
#
# Uses a pinned in-repo Docker image - the version comes from
# .github/lib/versions.env via the shared getter so a bump there
# propagates to every consumer in one commit. No native install path
# in the composite action: pip-installing ansible-lint per CI run
# would defeat the version-pin contract (transitively pulls
# ansible-core + cryptography + ruamel.yaml, any of which can float).
#
# Distribution: the upstream ghcr.io/ansible/community-ansible-lint
# image does not publish exact-version tags reliably, which cannot
# satisfy the repo's exact-version pin contract. The bundled
# Dockerfile next to this script pip-installs the pinned
# ansible-lint==<version> from PyPI at build time; the image is
# tagged github-common/ansible-lint:<version> and only rebuilt when
# the pinned tag changes - subsequent runs reuse the cached image
# (same shape yamllint and action-validator use for the same reason).
#
# Config resolution: a consumer-supplied .ansible-lint /
# .ansible-lint.yml / .ansible-lint.yaml at the repo root wins
# (ansible-lint auto-discovers it). Otherwise the bundled
# ansible-lint.config.yml next to this script applies - the
# `production` profile, so every consumer gets the strictest built-in
# bar by default.
#
# Usage: ./ansible-lint.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-skip detection. Mirrors the contract in problem.md: every
# consumer's ci-yaml.yml invokes this action unconditionally, so a
# repo with no Ansible content must no-op rather than fail. ansible-
# lint with no playbooks/roles still emits warnings about missing
# inventory - the auto-skip keeps non-Ansible CI runs quiet.
if [[ ! -f ansible.cfg && ! -d playbooks && ! -d roles ]]; then
    echo "::notice::no Ansible content (ansible.cfg/playbooks/roles), skipping"
    exit 0
fi

# Consumer-config wins so a downstream repo can tighten or relax the
# bar. ansible-lint resolves these names natively when -c is omitted;
# we detect explicitly here so the bundled-config branch is observable.
consumer_config=""
for candidate in .ansible-lint .ansible-lint.yml .ansible-lint.yaml; do
    if [[ -f "${candidate}" ]]; then
        consumer_config="${candidate}"
        break
    fi
done

version="$("${script_dir}/../../lib/get-ansible-lint-version.sh")"
image="github-common/ansible-lint:${version}"

# Build the pinned image on first use; the version-suffixed tag means
# a bump invalidates the cache automatically and a no-op run is just a
# cheap `docker image inspect`. stderr is left visible so a build
# failure (e.g. PyPI unreachable) surfaces.
if ! docker image inspect "${image}" >/dev/null 2>&1; then
    echo "::notice::building ${image} (first run for this version)"
    docker build \
        --build-arg "VERSION=${version}" \
        -t "${image}" \
        "${script_dir}"
fi

# Two mounts: the repo at /work (where ansible-lint discovers
# playbooks/roles and any consumer config) and the action dir at
# /action (where the bundled config lives - read-only so we cannot
# accidentally mutate it from inside the container). MSYS_NO_PATHCONV
# stops Git Bash on Windows mangling either mount path.
config_args=()
if [[ -z "${consumer_config}" ]]; then
    config_args=(-c /action/ansible-lint.config.yml)
fi

# ANSIBLE_HOME=/tmp/ansible-home redirects ansible's cache (modules,
# roles, collections) off the mounted host workspace. ansible-lint
# defaults ANSIBLE_HOME to <project-dir>/.ansible to avoid polluting
# the user's $HOME - but with --project-dir /work that "non-pollution"
# default writes root-owned .ansible/ directories straight into the
# mounted host repo, which then breaks any non-root caller (bats test
# cleanup, CI runner tmpdir teardown) that tries to remove the workdir.
# A container-local path sidesteps that. HOME=/tmp covers any ansible
# subprocess that bypasses ANSIBLE_HOME and falls back to ~/.ansible.
#
# No positional args - ansible-lint auto-discovers playbooks and
# roles from the working directory. --project-dir is explicit because
# passing -c <path> would otherwise set project_dir to the config
# file's directory (i.e. /action), causing ansible-lint to scan the
# bundled-config mount instead of the consumer repo. --force-color
# keeps output readable in CI logs where ansible-lint defaults to
# colourless.
MSYS_NO_PATHCONV=1 docker run --rm \
    -v "${PWD}:/work" -w /work \
    -v "${script_dir}:/action:ro" \
    -e HOME=/tmp \
    -e ANSIBLE_HOME=/tmp/ansible-home \
    "${image}" \
    --force-color \
    --project-dir /work \
    "${config_args[@]}"
