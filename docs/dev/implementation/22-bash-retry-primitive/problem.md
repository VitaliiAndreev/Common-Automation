# Problem: reusable bash retry primitive for CI and shell callers

## Index

- [What is changing and why](#what-is-changing-and-why)
- [Solution approach](#solution-approach)
  - [Off-the-shelf survey](#off-the-shelf-survey)
  - [Chosen direction](#chosen-direction)
- [Locked decisions](#locked-decisions)
- [Scope](#scope)
- [Out of scope](#out-of-scope)

## What is changing and why

GitHub-Common ships four dockerised lint actions (`ansible-lint`,
`yamllint`, `actionlint`, `action-validator`) that build their pinned
images on first run from a Docker Hub base image (`python:3.12-slim`
and friends). When `registry-1.docker.io` is unreachable for a few
seconds — DNS, TCP timeout, or 5xx — `docker build` exits non-zero
and the consumer's CI run fails. The latest example was
[Infrastructure-VM-Ansible feature 02](https://github.com/VitaliiAndreev/Infrastructure-VM-Ansible/actions),
where the ansible-lint job failed with
`dial tcp 52.205.187.141:443: i/o timeout` on a Docker Hub manifest
fetch. Re-running the job succeeded, but every consumer repo eats
the same false-failure tax.

This feature adds a **reusable bash retry primitive** to
GitHub-Common — a sourced helper plus a composite-action wrapper —
that wraps transient-prone commands with exponential-backoff retries.
The four dockerised lint actions become its first in-repo consumers;
their `docker build` calls move inside the helper. Future bash sites
that hit transient failures (curl pulls, ssh probes, package fetches
from flaky mirrors) adopt the same helper instead of hand-rolling an
`until ... sleep ... done` loop each time.

The primitive is the bash-side equivalent of
[`PowerShell.Common`'s `Invoke-WithRetry`](../../../../PowerShell-Common/PowerShell.Common/Public/Retry/Invoke-WithRetry.ps1)
and intentionally mirrors its shape (strategy + backoff + budget)
so a reader who knows one knows the other.

## Solution approach

### Off-the-shelf survey

Hard constraint: **no Node**, **no apt deps beyond what the runner
image already ships**. The org runs self-hosted minimal runners
(see [Infrastructure-GitHubRunners](https://github.com/VitaliiAndreev/Infrastructure-GitHubRunners)
for the base image); JavaScript-based GitHub Actions and
Debian-package retry tools are both off the table.

| # | Candidate | License / status | Fit | Cost / lock-in | Verdict |
|---|---|---|---|---|---|
| 1 | [`nick-fields/retry@v3`](https://github.com/nick-fields/retry) | MIT, active, widely used | Wraps shell steps with `max_attempts` / `retry_wait_seconds` / `timeout_minutes` / `retry_on`. | **JS action — requires Node on runner.** Action-only, no bash callers. | ✗ Node dep. |
| 2 | [`Wandalen/wretry.action`](https://github.com/Wandalen/wretry.action) | MIT, active | Wraps a whole action in retries. | JS — same Node constraint. | ✗ Node dep. |
| 3 | Debian [`retry(1)`](https://packages.debian.org/sid/retry) | BSD, maintained | `retry CMD` with exponential backoff. | Adds an apt install to every runner image and every dockerised-action Dockerfile; absent on minimal/Alpine. | ✗ Not minimal-runner-friendly. |
| 4 | Inline `until ... sleep ...` loop per call site | n/a | Trivial cases work. | No jitter, no transient-vs-permanent filter, no shared budget, no shared tests — copy-paste drift across sites. | ✗ Acceptable stop-gap; not a primitive. |
| 5 | [GNU `parallel --retries`](https://www.gnu.org/software/parallel/) | GPLv3 | Built-in retry on flaky commands. | GPL runtime dep; conceptually heavy (a parallel-execution engine for a sequential retry use case). | ✗ Wrong tool. |
| 6 | `docker buildx` internal retry | n/a | buildx has internal retry for some pull ops but no public CLI surface to control retry-on-network. | Doesn't address the broader bash retry need. | ✗ Not general. |
| 7 | **Reference shape** — `PowerShell.Common`'s `Invoke-WithRetry` + `New-*RetryStrategy` factories | in-house, active | Wrong language but right shape: strategy (transient classifier) + backoff (exponential w/ jitter) + budget. `Invoke-ModuleInstall` is the working existence proof. | n/a — model, not a runtime dep. | ✓ Adopt the shape. |

### Chosen direction

**Build custom**, mirroring `Invoke-WithRetry`'s strategy / backoff /
budget separation, packaged in two layers:

1. **`scripts/lib/retry.sh`** — sourced primitive. Same convention
   as `scripts/_hold-window.sh` + `scripts/_hold-window.bats` today.
   Used directly by other bash scripts, including the lint actions'
   `*.sh` files and the local pre-push runner
   (`scripts/run-tests.sh`).
2. **`.github/actions/retry/action.yml`** — composite action
   wrapping the primitive so workflows can use it like
   `nick-fields/retry` would, but without Node.

The primitive ships with default transient classifiers for today's
known pain (Docker registry I/O timeouts, generic DNS / TCP
failures, HTTP 5xx text in tool output); consumers compose
additional patterns when their tooling surfaces a different
transient signature.

The four dockerised lint actions (`ansible-lint`, `yamllint`,
`actionlint`, `action-validator`) are the **first in-repo
consumers** — their `docker build` calls move inside the helper as
part of this feature. Their bash test fixtures get refreshed to
cover the retry path.

## Locked decisions

- **No Node, no apt-package deps.** Pure bash + standard POSIX
  utilities (`sleep`, `printf`, `awk`, `grep`, `date`) that every
  minimal runner image ships.
- **Strategy / backoff / budget separation.** Three orthogonal
  knobs, mirroring `Invoke-WithRetry`:
  - *Strategy* — function that inspects exit code + stdout/stderr
    and returns retriable yes/no. Composable: callers OR multiple
    strategies together.
  - *Backoff* — function that returns the next sleep interval given
    the attempt number. Default: exponential with jitter, configurable
    initial / max / multiplier.
  - *Budget* — max attempts and total seconds; whichever ceiling
    fires first ends the loop.
- **Default transient classifiers** ship with the primitive:
  Docker registry I/O timeouts (the recent CI failure mode),
  generic network DNS / TCP failures, HTTP 5xx text in tool output.
  Consumers extend by passing additional classifier names or inline
  patterns.
- **Two-layer packaging** — `scripts/lib/retry.sh` (sourced helper,
  bats-tested) and `.github/actions/retry/` (composite action
  wrapper). Same shape as
  [`scripts/_hold-window.sh`](../../../scripts/_hold-window.sh) +
  its composite consumers today.
- **Fail-fast on permanent errors.** Auth (401/403), not-found
  (404), syntax errors, and any non-matching classifier propagate
  immediately so retries don't mask real failures.
- **Output preservation.** stdout / stderr of the wrapped command
  reach the caller verbatim across all attempts (no buffering, no
  prefixing), so logs read the same as if retry weren't there.
  Diagnostics from the primitive itself go to stderr with a
  consistent prefix so they can be greppable without polluting
  parsed output.
- **No magic globals.** The primitive accepts everything via args
  / env (documented contract); no inherited `$RETRY_*` surprises
  from the caller's environment.
- **Composite-action input surface stays minimal.** The composite
  exposes only `command` + `max_attempts` + `transient_patterns`
  (extra patterns to add to the defaults) as `inputs:`. Everything
  else — backoff params, total-seconds budget, strategy
  composition — is reachable via env vars the primitive reads, but
  is not promoted to the action's public surface. Lower surface =
  fewer breaking-change vectors and fewer ways for a workflow author
  to misuse the retry. Workflows that need more are a) rare and
  b) better off sourcing the primitive directly in a `run:` step.
- **Same major-version tag as the rest of the repo.** The primitive
  ships under the existing GitHub-Common version tag (see
  [feature 04 versioning](../04-lint-yaml-workflows-and-actions/));
  no separate primitive version line. Bumping the tag bumps every
  caller in lockstep, which matches the contract consumers already
  rely on for the lint actions.
- **Primitive sourcing inside dockerised actions: env-var primary,
  relative-path fallback.** Each composite `action.yml` exports
  `GHCOMMON_REPO_ROOT="${{ github.action_path }}/../../.."` for its
  bash entry script. The entry resolves the primitive as
  `source "${GHCOMMON_REPO_ROOT:-$(cd "${SCRIPT_DIR}/../../.." &&
  pwd)}/scripts/lib/retry.sh"`. When invoked as a composite action,
  `github.action_path` is authoritative and survives a future
  action-directory move; when invoked outside Actions (local
  pre-push runner, ad-hoc `bash .github/actions/foo/foo.sh`), the
  env var is unset and the `${SCRIPT_DIR}/../../..` fallback
  resolves identically as long as the repo layout is intact. Two
  resolution paths, one target file, both deterministic — no
  drift risk.

## Scope

In-scope deliverables for feature 22:

- `scripts/lib/retry.sh` — primitive with default classifiers,
  default exponential-jitter backoff, and documented contract.
- `scripts/lib/retry.bats` — coverage for strategy composition,
  backoff schedule, budget enforcement, transient-classifier
  defaults, output preservation, fail-fast-on-permanent.
- `.github/actions/retry/action.yml` — composite wrapper.
- `Tests/actions/retry/` — bats coverage for the composite using
  the existing `BATS_LIB_PATH` test helpers.
- Migration of the four dockerised lint actions
  (`ansible-lint`, `yamllint`, `actionlint`, `action-validator`)
  to call the primitive around their `docker build` step.
- README updates: top-level "Retry" subsection plus per-lint-action
  notes on the retry behaviour they now inherit.
- Versioning + tagging coordination so consumer repos pick up the
  new primitive via the existing tag-pinning convention.

## Out of scope

- **Migrating other org repos.** Each consumer adopts the primitive
  on its own timeline once it ships. Feature 22 ships the primitive
  and migrates only in-repo consumers (the four lint actions).
- **Circuit breaker, retry-budget telemetry, distributed-systems
  patterns.** This is a local retry-with-backoff, not a service-mesh
  resiliency layer. Reach for `Resilience4j` / `Polly` shape when an
  actual SLO needs it.
- **Rewriting `Invoke-WithRetry`.** The PS-side primitive stays for
  PS consumers; the bash-side ships separately with intentionally
  parallel shape for cross-language readability. No attempt to share
  code across the language boundary.
- **Generalised "rerun the whole job" semantics.** This primitive
  retries one command, not a workflow step or job. Job-level reruns
  remain GitHub's responsibility.
- **Replacing existing inline retry loops outside the dockerised
  lint actions.** Anywhere else in GitHub-Common that already loops
  for retry (none today, but if any appear) is a separate migration.
