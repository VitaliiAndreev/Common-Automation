# Problem: classify Go context-deadline timeouts as Docker registry transients

## Index

- [What is changing and why](#what-is-changing-and-why)
- [Solution approach](#solution-approach)
- [Locked decisions](#locked-decisions)
- [Scope](#scope)
- [Out of scope](#out-of-scope)

## What is changing and why

Feature 22 shipped a bash retry primitive with three default
classifiers — `classify_docker_registry`, `classify_network`, and
`classify_http_5xx` — and the four dockerised lint actions
(`ansible-lint`, `yamllint`, `actionlint`, `action-validator`) were
wired to call it around their `docker build` / `docker pull` steps.
The locked decision in
[feature 22's problem.md](../22-bash-retry-primitive/problem.md#locked-decisions)
explicitly listed "Docker registry I/O timeouts (the recent CI
failure mode)" as one of the shipped defaults.

A real CI run on
[Infrastructure-VM-Ansible feature 02](https://github.com/Klark-Morrigan/Infrastructure-VM-Ansible/actions)
hit a transient Docker Hub failure that the primitive correctly
attempted to retry, then rejected as permanent. The relevant excerpt:

```
Notice: pulling rhysd/actionlint:1.7.12 (first run for this version)
Error response from daemon: Get "https://registry-1.docker.io/v2/": context deadline exceeded
retry: actionlint docker pull attempt 1 permanent (exit 1); rejected by classify_http_5xx
Error: Process completed with exit code 1.
```

The Docker daemon emits `context deadline exceeded` when its internal
Go-context boundary times out before the underlying TCP / TLS
operations report their own failure - the same root cause as `dial
tcp ... i/o timeout` but a different surface string. None of the
three shipped classifiers match it:

- `classify_docker_registry` covers `dial tcp .*: i/o timeout`,
  `connection refused`, `TLS handshake timeout`, `unexpected EOF`,
  and `received unexpected HTTP status: 5xx` — not the Go context
  wording.
- `classify_network` covers glibc / busybox surface strings
  (`Temporary failure in name resolution`, `Connection timed out`,
  `Connection reset by peer`, `Network is unreachable`) - none of
  which are emitted here.
- `classify_http_5xx` covers `HTTP/<v> 5xx` and `Server Error: 5xx`
  text - not applicable; the daemon never received a response status.

Result: the primitive classifies `context deadline exceeded` as a
permanent error and propagates exit 1 immediately. The CI run failed
on first attempt; a manual rerun a few minutes later passed. Exactly
the failure mode feature 22 was supposed to absorb.

This feature closes the gap by **extending the existing
`classify_docker_registry` classifier** to recognize Go context-
deadline timeouts on docker / OCI client operations. The lint
actions inherit the fix automatically through the classifier they
already register.

## Solution approach

This is a one-pattern extension to a shipped classifier — not a new
classifier and not a new architectural surface. Off-the-shelf survey
is not needed: the design decision (build custom, strategy / backoff /
budget separation, default classifier per file) was made in feature
22 and remains correct. Feature 24 ships one regex addition plus
test coverage for it.

The new pattern added to
[`classify_docker_registry`](../../../../.github/lib/retry-classifiers/docker-registry.sh):

```
context deadline exceeded
```

Case-insensitive grep on both stdout and stderr, consistent with the
existing patterns in the same classifier. Anchored loosely enough to
match both the daemon-side form (`Get "https://registry-1.docker.io/v2/": context deadline exceeded`)
and the buildx / containerd form (`failed to copy: httpReadSeeker:
failed open: failed to do request: ... context deadline exceeded`),
since both surface the same root cause.

The pattern lives in `classify_docker_registry` rather than getting
its own file because:

- It is a docker / OCI-client wording, not a generic network-stack
  string. `classify_network` covers OS-level transients
  (`Connection timed out` etc.); `context deadline exceeded` is a
  Go-runtime concept the docker client uses internally, so the
  docker classifier is the right home.
- Splitting per-pattern would invert the locked
  [one-file-per-classifier convention](../22-bash-retry-primitive/problem.md#locked-decisions)
  into one-file-per-pattern, which scales poorly.

## Locked decisions

- **Extend `classify_docker_registry`, do not add a new classifier.**
  The pattern is docker-specific surface text, so it belongs in the
  docker classifier alongside the existing daemon / buildx wording.
  A separate `classify_context_deadline` would be conceptually
  misleading (context-deadline is a Go-runtime phrase, not a
  category of error in its own right) and would force every
  docker-touching action to register an extra classifier name to
  pick it up.
- **Case-insensitive match, both fds.** Same shape as the existing
  patterns in `docker-registry.sh`. No reason to diverge.
- **Test coverage co-located with the classifier.**
  `.github/lib/retry.bats` is the shared suite that already covers
  the other docker-registry patterns; the new pattern gets a case
  added there next to its siblings, not in a separate file. Mirrors
  the colocation convention from feature 22.
- **No version bump beyond the shared tag.** Feature 22 already
  established the
  ["same major-version tag as the rest of the repo"](../22-bash-retry-primitive/problem.md#locked-decisions)
  rule; consumers re-pin once the tag is bumped and pick up the
  fix transparently.
- **No changes to the four lint actions' wiring.** They already
  register `classify_docker_registry` as a default classifier (see
  [actionlint.sh:74](../../../.github/actions/actionlint/actionlint.sh),
  ditto for yamllint / ansible-lint / action-validator); the
  extension reaches them through the existing call site. Zero
  consumer-side edits.

## Scope

In-scope deliverables for feature 24:

- One pattern (`context deadline exceeded`) added to the regex
  alternation in
  [`.github/lib/retry-classifiers/docker-registry.sh`](../../../.github/lib/retry-classifiers/docker-registry.sh).
- A bats case in
  [`.github/lib/retry.bats`](../../../.github/lib/retry.bats)
  asserting `classify_docker_registry` returns retriable for a
  stderr fixture containing the daemon-side wording, and a second
  case for the buildx-side wording. Both cases use the existing
  fixture / harness shape from the sibling pattern tests.
- README touch-up: the
  [`.github/actions/retry/README.md`](../../../.github/actions/retry/README.md)
  list of patterns that ship in the default classifiers gains the
  one-line `context deadline exceeded` entry under the
  docker-registry rollup. No consumer-facing README changes — the
  fix is invisible to callers.

## Out of scope

- **A standalone `classify_context_deadline` classifier.** See locked
  decisions above for why the pattern stays in the docker classifier.
- **Migrating consumers off `classify_docker_registry` defaults.**
  Every dockerised lint action already registers it; nothing else in
  the repo needs the extension.
- **Backporting to older tags.** Consumers pinned to a tag predating
  the fix can re-pin to the next published tag once the fix lands;
  no separate patch tag on older lines.
- **Generalised Go-runtime error coverage** (`canceled`, `deadline
  exceeded` outside docker context, `i/o timeout` not already
  matched). These would warrant their own classifier if/when a real
  CI failure surfaces them; speculatively adding patterns invites
  false retries on permanent errors. One real failure pattern, one
  surgical addition.
- **Telemetry for retry effectiveness.** Out of scope in feature 22
  and still out of scope here; reach for an SLO-bearing dashboard
  only when retry behaviour itself becomes a question.
