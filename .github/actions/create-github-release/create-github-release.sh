#!/usr/bin/env bash
# Creates a GitHub Release for a tag, with the body taken from the matching
# CHANGELOG.md section (Keep a Changelog format). Stack-agnostic: it needs
# only a changelog file and an existing tag, so a PowerShell module, a
# NuGet package, or any other artifact stream can reuse it unchanged.
#
# Inputs are read from the environment (set by action.yml):
#   CHANGELOG   Path to the changelog file.        Default: CHANGELOG.md
#   VERSION     Version to release.                Default: the topmost
#               '## [X.Y.Z]' section (skipping '## [Unreleased]').
#   TAG         Git tag to attach the release to.  Default: VERSION
#   DRAFT       'true' to create a draft release.  Default: false
#   PRERELEASE  'true' to mark as a prerelease.    Default: false
#   FILES       Newline-separated asset paths to attach. Default: none
#
# Requires gh on PATH and GH_TOKEN in the environment, plus the caller's
# workflow granting 'permissions: contents: write'. Fails if the resolved
# version has no changelog section, so a release can never ship with empty
# notes.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve the changelog helpers: COMMON_AUTOMATION_REPO_ROOT is authoritative
# when the composite exports it; the relative fallback resolves the same file
# from this action's own location otherwise. Mirrors action-validator.sh.
repo_root="${COMMON_AUTOMATION_REPO_ROOT:-$(cd "${script_dir}/../../.." && pwd)}"
# shellcheck source=../../lib/changelog.sh
source "${repo_root}/.github/lib/changelog.sh"

changelog="${CHANGELOG:-CHANGELOG.md}"
version="${VERSION:-}"
tag="${TAG:-}"
draft="${DRAFT:-false}"
prerelease="${PRERELEASE:-false}"
files="${FILES:-}"

if [[ ! -f "${changelog}" ]]; then
    echo "::error::create-github-release: changelog not found at '${changelog}'." >&2
    exit 1
fi

# Resolve the version from the changelog's latest section when not supplied.
if [[ -z "${version}" ]]; then
    version="$(changelog_latest_version "${changelog}")"
fi
if [[ -z "${version}" ]]; then
    echo "::error::create-github-release: no '## [X.Y.Z]' version heading in '${changelog}' and no VERSION input." >&2
    exit 1
fi

tag="${tag:-${version}}"

notes="$(changelog_section "${changelog}" "${version}")"

if [[ -z "${notes//[[:space:]]/}" ]]; then
    echo "::error::create-github-release: no changelog entry for version '${version}' in '${changelog}'. Add a '## [${version}]' section before releasing." >&2
    exit 1
fi

create_args=( release create "${tag}" --title "${version}" --notes "${notes}" --verify-tag )
[[ "${draft}" == "true" ]]      && create_args+=( --draft )
[[ "${prerelease}" == "true" ]] && create_args+=( --prerelease )

# Attach asset files when supplied. gh takes asset paths as trailing
# positional args, so they go after the flags. Each non-blank line of FILES is
# one asset; empty FILES leaves the release asset-less (historical behaviour).
if [[ -n "${files//[[:space:]]/}" ]]; then
    while IFS= read -r asset; do
        [[ -n "${asset//[[:space:]]/}" ]] && create_args+=( "${asset}" )
    done <<< "${files}"
fi

echo "create-github-release: creating release for tag '${tag}' (version '${version}') from '${changelog}'."
gh "${create_args[@]}"
