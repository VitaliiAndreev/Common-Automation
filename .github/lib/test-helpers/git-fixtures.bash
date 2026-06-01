#!/usr/bin/env bash
# Shared git fixtures for the git-backed bats suites (check-sh-executable,
# fix-sh-executable, setup-hooks, publish-version-tags). Sourced - never run -
# so it carries no tests itself and is skipped by the recursive *.bats runner.
#
# Lives under .github/lib/test-helpers/ because the production callers
# (.github/actions/check-sh-executable/check-sh-executable.bats and
# .github/lib/fix-sh-executable.bats) take priority over the secondary
# maintainer-script callers under scripts/. Keeping shared test infra inside
# .github/lib/ also keeps the sparse-checkout list of the reusable-workflow
# second checkout uncluttered - .github/lib is already pulled for the version
# files and getter scripts, so this rides along at zero extra entries.

# Skips the calling test when git is absent (e.g. the git-less bats Docker
# image used by run-tests.sh's local fallback). The scripts under test are
# pure git behaviour, so without git there is nothing meaningful to assert -
# a skip is the correct outcome, not a failure. Stated here once so the
# policy stays single-sourced across every git suite.
require_git() {
    command -v git >/dev/null 2>&1 || skip "git not available in this environment"
}

# Creates an empty repo under BATS_TEST_TMPDIR, inits it, and cd's into it,
# exporting its path as REPO. The throwaway location keeps every fixture
# isolated from the real repo and from other tests. Callers that operate on
# the repo by path (rather than cwd) use ${REPO}; those that rely on cwd get
# it for free from the cd.
new_git_repo() {
    REPO="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${REPO}"
    git -C "${REPO}" init -q
    cd "${REPO}" || return 1
}

# Adds a tracked .sh file with an explicit git-index mode. --chmod sets the
# mode directly so the fixture does not depend on the host umask or
# core.fileMode (commonly false on Windows checkouts). $1 = filename,
# $2 = +x (executable, 100755) or -x (non-executable, 100644). Must run with
# cwd inside the repo (see new_git_repo).
add_tracked_sh() {
    local name="$1" mode="$2"
    printf '#!/usr/bin/env bash\necho hi\n' > "${name}"
    git add "${name}"
    git update-index --chmod="${mode}" "${name}"
}

# Prints the git-index mode of a tracked path: 100644 (no +x) or 100755
# (+x). `git ls-files -s` emits "<mode> <object> <stage>\t<path>".
index_mode_of() {
    git ls-files -s -- "$1" | awk '{print $1}'
}
