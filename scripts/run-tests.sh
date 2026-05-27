#!/usr/bin/env bash
# Runs every bats suite in the repo before pushing.
#
# Mirrors the bats job in .github/workflows/ci-bash.yml so failures
# are caught locally rather than on the remote.
#
# Uses native bats if available on PATH; otherwise falls back to
# Docker so a developer with only Docker Desktop on Windows still
# gets a working pre-push check. The image is pinned to the same
# version as CI - update both together.

set -euo pipefail

BATS_IMAGE='bats/bats:1.11.0'
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

if command -v bats >/dev/null 2>&1; then
    echo "Running bats (native) ..."
    exec bats --recursive "${repo_root}"
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "Neither bats nor docker is available. Install one to run tests." >&2
    exit 1
fi

# docker info exits non-zero when the CLI is installed but the daemon
# is not running - distinguish that from "docker missing" so the error
# is actionable.
if ! docker info >/dev/null 2>&1; then
    echo "Docker CLI is installed but the daemon is not running." >&2
    exit 1
fi

echo "Running bats via Docker (${BATS_IMAGE}) ..."

# Git Bash on Windows rewrites POSIX-looking paths on the docker
# command line into Windows form, which breaks the volume mount.
# MSYS_NO_PATHCONV disables that for this invocation only.
export MSYS_NO_PATHCONV=1
exec docker run --rm -v "${repo_root}:/code" "${BATS_IMAGE}" \
    --recursive /code
