#!/usr/bin/env bash
# Publish the release tags for the reusable workflows / composite
# actions in this repo, following the GitHub Actions versioning
# convention:
#
#   - an immutable, full semver tag (e.g. v1.2.3) that pins an exact
#     commit and is never re-pointed, and
#   - a floating major tag (e.g. v1) that consumers reference as @v1 and
#     that moves forward across all non-breaking 1.x releases.
#
# Both tags are placed on the current tip of the remote default branch
# (origin/master) by resolving it to an explicit commit SHA and tagging
# THAT - never the local checkout. This means the operator does not
# check out or even touch master, can run from any branch, and the
# release always reflects exactly what is merged on the remote.
#
# Sequence:
#   1. obtain the version (argument, else prompt)
#   2. fetch origin so origin/master is current
#   3. resolve origin/master to a commit SHA
#   4. create the immutable vX.Y.Z tag on that SHA and push it
#   5. force-move the major vX tag to that SHA and force-push it
#
# The semver tag is created WITHOUT -f: if it already exists the run
# aborts, because re-pointing a published immutable tag is exactly the
# supply-chain footgun the convention exists to avoid. Only the major
# tag is ever force-moved.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep the window open on an Explorer double-click (no-op under the
# .bat launcher, which sets GHCOMMON_NO_PAUSE=1, and in CI/pipes).
# shellcheck source=./_hold-window.sh
source "${script_dir}/_hold-window.sh"
trap hold_window_open EXIT

# The remote and branch the release tags track. Overridable for forks
# or repos whose default branch is not master.
remote="${GHCOMMON_RELEASE_REMOTE:-origin}"
branch="${GHCOMMON_RELEASE_BRANCH:-master}"

# Version comes from the first argument; if omitted, prompt for it so a
# double-click launch is still usable rather than just erroring out.
version="${1:-}"
if [[ -z "${version}" ]]; then
  read -r -p "Enter version to publish (e.g. v1.2.3): " version
fi

# Enforce the vX.Y.Z shape up front: the major tag is derived from it,
# and a malformed version would otherwise produce a nonsense major tag.
if [[ ! "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must look like v1.2.3 (got '${version}')." >&2
  exit 2
fi

# Floating major tag: v1 from v1.2.3. Strip the leading v, take the
# first dot-segment, re-prefix v.
bare="${version#v}"
major="v${bare%%.*}"

echo "=== publishing ${version} (major tag ${major}) from ${remote}/${branch} ==="

# Refresh the remote-tracking ref so the SHA below is the real tip.
git fetch "${remote}" "${branch}"

# Resolve to an explicit commit SHA and tag that, so neither the local
# checkout nor a later branch move can affect what gets tagged.
sha="$(git rev-parse "${remote}/${branch}^{commit}")"
echo "Tagging commit ${sha} (${remote}/${branch})."

# Immutable semver tag - refuse to clobber an existing one.
if git rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
  echo "Error: tag ${version} already exists; immutable tags are never re-pointed." >&2
  exit 1
fi
# Lightweight tags (no -a/-s): they point straight at the commit, so on
# GitHub they inherit that commit's signature/verification. Releases tag
# GitHub-signed PR-merge commits, which is what gives the "Verified"
# badge. An annotated tag would instead be checked for its OWN signature
# and, being unsigned, would show as unverified.
git tag "${version}" "${sha}"
git push "${remote}" "${version}"
echo "Pushed immutable tag ${version}."

# Floating major tag - force-move it forward and force-push.
git tag -f "${major}" "${sha}"
git push "${remote}" "${major}" --force
echo "Moved ${major} -> ${version} and force-pushed."

echo "Done. Consumers on @${major} now get ${version}; pin exact builds with @${version}."
