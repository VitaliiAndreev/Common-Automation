# Common-Automation

Shared, tech-agnostic GitHub Actions composite actions and reusable workflows.

Lives outside any single language ecosystem so it can be consumed by
PowerShell, .NET, and future stacks without dragging tooling along.

## Index

- [Actions](#actions)
- [Retry primitive](#retry-primitive)
- [Local development](#local-development)
  - [One-time setup after clone](#one-time-setup-after-clone)
  - [Running checks and tests locally](#running-checks-and-tests-locally)
- [Consuming](#consuming)
- [Layout](#layout)

## Actions

**Linting & validation**

| Action                                          | Purpose                                                           |
|-------------------------------------------------|-------------------------------------------------------------------|
| `.github/actions/shellcheck-bash/`              | Runs strict shellcheck on every *.sh under a given directory.     |
| `.github/actions/actionlint/`                   | Lints GitHub Actions workflows and composite actions via pinned rhysd/actionlint. |
| `.github/actions/action-validator/`             | Schema-validates workflows and composite `action.yml` files via pinned mpalmer/action-validator. |
| `.github/actions/yamllint/`                     | Lints plain YAML (Ansible, dependabot, mkdocs, ...) outside the actionlint / action-validator surface, via pinned yamllint. |
| `.github/actions/ansible-lint/`                 | Lints Ansible content (playbooks, roles, ansible.cfg) via pinned ansible-lint; auto-skips when none of those exist. |

**Test infrastructure**

| Action                                          | Purpose                                                           |
|-------------------------------------------------|-------------------------------------------------------------------|
| `.github/actions/test-bats/`                    | Installs bats-core and runs every *.bats suite under a given path. |
| `.github/actions/build-ssh-test-image/`         | Builds the SSH target Docker image used by integration tests.     |

**CI utilities**

| Action                                          | Purpose                                                           |
|-------------------------------------------------|-------------------------------------------------------------------|
| `.github/actions/assert-secret/`                | Fails a job with a clear message when a required secret is empty. |
| `.github/actions/check-sh-executable/`          | Fails a job when any tracked `*.sh` is missing the executable bit. |
| `.github/actions/retry/`                        | Wraps an arbitrary bash command in the [retry primitive](#retry-primitive) with default transient classifiers. |

**Release**

| Action                                          | Purpose                                                           |
|-------------------------------------------------|-------------------------------------------------------------------|
| `.github/actions/create-github-release/`        | Creates a GitHub Release for a tag, body taken from the matching `CHANGELOG.md` section (Keep a Changelog). Stack-agnostic - any artifact stream (PowerShell module, NuGet, ZIP, ...) reuses it; fails if the version has no changelog section. Optional `files` input (newline-separated) attaches release assets. |

## Retry primitive

`.github/lib/retry.sh` is a sourced helper that wraps any command in
a bounded retry loop, so callers (including the dockerised lint
actions in this repo) don't reimplement the same `until ... sleep ...`
pattern when a transient failure - Docker registry timeout, DNS
blip, HTTP 5xx - flakes a CI run. It lives alongside the other
production sourced helpers (`fix-sh-executable.sh`,
`get-*-version.sh`).

Signature:

```bash
# shellcheck source=.github/lib/retry.sh
source "${REPO_ROOT}/.github/lib/retry.sh"
retry_command "docker build" -- docker build -t foo .
```

The first argument is an operation name used in diagnostics. `--`
separates it from the command vector so the wrapped command can
carry arbitrary flags.

Configuration env vars (defaults shown):

| Env var               | Default | Meaning                                              |
|-----------------------|---------|------------------------------------------------------|
| `RETRY_MAX_ATTEMPTS`  | `5`     | Hard cap on attempts including the first try.        |
| `RETRY_MAX_SECONDS`   | `300`   | Wall-clock budget across all attempts.               |

Between attempts the primitive calls a **backoff strategy** to
compute the sleep duration. The strategy is a shell function whose
name is held in `RETRY_BACKOFF_STRATEGY`; the primitive itself only
calls it and caps the returned value to the remaining wall-clock
budget. This indirection means a future caller needing a different
shape (constant / linear / decorrelated jitter) registers a function
and points the env var at it - no edits to the primitive.

Strategy contract:

| `$1`  | Retry index (1 for the first retry after attempt 1 fails). |
| `$2`  | Remaining wall-clock budget in seconds (advisory).         |
| stdout | Sleep duration in seconds (decimals allowed).             |
| exit  | 0 on success; non-zero is a usage error.                   |

The primitive caps the returned value to `$2` automatically, so a
strategy can't sleep past the deadline by accident.

The shipped default is `exponential_jitter_backoff`, which lives
in its own file at
`.github/lib/retry-strategies/exponential-jitter.sh` and is sourced
automatically when `retry.sh` is loaded. The file doubles as the
worked example for consumers writing their own strategies. The
function follows the AWS SDK and Google SRE-book baseline: for
retry index `R`, the unjittered interval is
`min(INITIAL * MULTIPLIER^(R-1), MAX)`; jitter then multiplies by
`1 + uniform(-RATIO, +RATIO)`. Its knobs:

| Env var                          | Default | Meaning                                                  |
|----------------------------------|---------|----------------------------------------------------------|
| `RETRY_BACKOFF_INITIAL_SECONDS`  | `2`     | Base sleep after the first failed attempt.               |
| `RETRY_BACKOFF_MAX_SECONDS`      | `60`    | Cap on the unjittered sleep, applied before jitter.      |
| `RETRY_BACKOFF_MULTIPLIER`       | `2`     | Growth factor per retry index.                           |
| `RETRY_BACKOFF_JITTER_RATIO`     | `0.3`   | Symmetric jitter band (`0.3` = +/-30%). `0` disables.    |

Registering a custom strategy:

```bash
# In a file sourced before retry_command runs:
my_constant_backoff() {
    # $1 = retry index, $2 = remaining seconds (ignored here).
    echo "5.000"
}
export -f my_constant_backoff
export RETRY_BACKOFF_STRATEGY=my_constant_backoff
```

Between the failed attempt and the backoff sleep, the primitive runs
**classifiers** to decide whether the failure is worth retrying at
all. A classifier is a shell function named `<name>_classify`
listed in `RETRY_CLASSIFIERS` (colon-separated). Each is invoked with
the failed attempt's exit code, the path to its captured stdout, and
the path to its captured stderr; it returns 0 to mark the failure
retriable and non-zero to mark it permanent. Default is an empty
list, which preserves the always-retry behaviour described above -
opt in to triage by setting the env var.

Classifier contract:

| `$1`   | Exit code from the failed attempt.                       |
| `$2`   | Path to a file containing the attempt's stdout.          |
| `$3`   | Path to a file containing the attempt's stderr.          |
| exit 0 | Failure is retriable.                                    |
| exit !0 | Failure is permanent (its stderr is surfaced verbatim). |

Multiple classifiers OR: any accept triggers a retry; all reject
makes the primitive return the failed exit code immediately, naming
the last rejector and its stderr in the `retry:` diagnostic so the
reason is visible without re-running. While classifiers are active,
the wrapped command's stdout / stderr are tee'd to capture files for
inspection AND still forwarded to the caller's fds in real time - no
swallowing.

Three default classifiers ship out of the box, each living in its
own file under `.github/lib/retry-classifiers/` and sourced
automatically when `retry.sh` is loaded. All three match
case-insensitively against the captured stdout *and* stderr - which
fd carries the error varies by tool, so scanning both keeps the
classifier from missing real transients.

| Classifier                  | Patterns it accepts as retriable                                                                                                                                                                                                  |
|-----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `classify_docker_registry`  | `dial tcp .*: i/o timeout`, `dial tcp .*: connection refused`, `failed to do request: Head .* dial tcp`, `received unexpected HTTP status: 5[0-9][0-9]`, `TLS handshake timeout`, `unexpected EOF`, `context deadline exceeded`.   |
| `classify_network`          | `Temporary failure in name resolution`, `Could not resolve host`, `Connection timed out`, `Connection reset by peer`, `Network is unreachable`.                                                                                    |
| `classify_http_5xx`         | `HTTP/<version> 5[0-9][0-9]`, `Server Error: 5[0-9][0-9]`. 4xx is deliberately not matched - those are permanent for the caller (RFC 9110 section 15.6).                                                                            |

Recommended default for dockerised actions (the value the composite
action in step 5 ships with):

```bash
export RETRY_CLASSIFIERS=classify_docker_registry:classify_network:classify_http_5xx
```

The four in-repo lint actions (ansible-lint, yamllint, actionlint,
action-validator) adopt this default in steps 6-9.

Output is passthrough: the wrapped command's stdout / stderr reach
the caller verbatim. Only the primitive's own messages carry the
`retry:` prefix, and they always go to stderr.

### Composite action

For workflows that prefer a YAML target over sourcing the primitive
in a `run:` block, `.github/actions/retry/` is a thin pass-through
exposing three inputs (`command`, `max_attempts`, `transient_patterns`).
The defaults match the recommended dockerised-action set above. See
[`.github/actions/retry/README.md`](.github/actions/retry/README.md)
for the input contract and worked example. One-line usage:

```yaml
- uses: Klark-Morrigan/Common-Automation/.github/actions/retry@v1
  with:
    command: docker build -t example:ci .
```



Production bash (composite-action logic) is extracted into `*.sh`
files alongside each action and unit-tested with
[bats-core](https://github.com/bats-core/bats-core). Static analysis
is `shellcheck` at its strictest setting (`--severity=style
--enable=all`).

Runner bash (maintainer-side dev scripts) lives under `scripts/` and
shares the same lint bar.

### One-time setup after clone

```bash
./scripts/setup-hooks.sh
```

Wires the repo-checked-in pre-commit hook (`.githooks/pre-commit`),
which auto-fixes the executable bit on `.sh` files. Without this
step, files authored on Windows commit as mode 0644 and CI catches
them later - the hook just turns "push, fail, fix, re-push" into
"commit silently succeeds."

### Running checks and tests locally

```bash
./scripts/run-ci-yaml-and-bash.sh
```

`scripts/run-ci-yaml-and-bash.sh` is the orchestrator: the single
"run everything locally" entry point. It runs both the lint half and
the test half against the target repo and reports a combined
pass/fail. It is the local equivalent of the `ci-yaml.yml` +
`ci-bash.yml` workflows, so a green run here means CI should pass too.
Run it before pushing to catch failures locally. Windows users can
double-click `scripts/run-ci-yaml-and-bash.bat` for the same result.

The work is split across three `_`-prefixed building blocks the
orchestrator sources and runs; the underscore marks them as internal
to the runner set rather than entry points. Each can also be invoked
in isolation when you only care about one half:

- `scripts/_run-common.sh` - shared setup: resolves the target repo
  and arms the hold-window pause on double-click exit. Sourced by the
  three entry scripts below rather than run directly.
- `scripts/_run-lint-yaml-and-bash.sh` - the lint half. Runs
  `shellcheck` (production `.github`, runner `scripts/`, git hooks),
  `check-sh-executable`, `actionlint`, `action-validator`, `yamllint`,
  and `ansible-lint`. Each check auto-skips when its surface is absent,
  so a repo with only some of these still passes cleanly. Docker is
  required for the dockerised linters.
- `scripts/_run-tests-bash.sh` - the test half. Runs every `*.bats`
  suite via native `bats` if installed, otherwise the pinned Docker
  image (`bats/bats:1.11.0`, the same image CI uses).

All three honour `COMMON_AUTOMATION_TARGET_REPO`, which points them at
a repo other than this one. That is how consuming repos run the same
lint + bats recipe against themselves: they ship thin shims of the
same names that set the variable and delegate here, so the runner
logic lives in one place.

## Consuming

### Atomic actions

Reference any action directly from another repo's workflow:

```yaml
- uses: Klark-Morrigan/Common-Automation/.github/actions/assert-secret@v1
  with:
    value: ${{ secrets.PSGALLERY_API_KEY }}
    name: PSGALLERY_API_KEY
```

### Reusable workflow: ci-bash

For repos that want the same lint + bats recipe applied to their own
bash, call the `ci-bash.yml` reusable workflow:

```yaml
jobs:
  bash:
    uses: Klark-Morrigan/Common-Automation/.github/workflows/ci-bash.yml@v1
```

No inputs needed by default - the workflow scans the caller's
`.github/actions/` (production) and `scripts/` (runner) directories.
Missing directories are skipped silently, so a repo that has only one
or the other still works without configuration.

Override `bats-version` if you need to pin to a specific bats release.

### Reusable workflow: ci-yaml

For the same lint recipe applied to a repo's GitHub Actions YAML
(workflows + composite `action.yml` files), call the `ci-yaml.yml`
reusable workflow:

```yaml
jobs:
  yaml:
    uses: Klark-Morrigan/Common-Automation/.github/workflows/ci-yaml.yml@v1
```

No inputs - all four underlying composite actions self-resolve
their pinned versions. The workflow runs `actionlint`,
`action-validator`, `yamllint`, and `ansible-lint` as parallel
jobs. Each underlying surface may be absent: actionlint and
action-validator skip silently when `.github/workflows/` or
`.github/actions/` is empty; yamllint skips when no plain YAML
exists outside those trees; ansible-lint skips when none of
`ansible.cfg`, `playbooks/`, `roles/` exist at the repo root.
That auto-skip is what lets a single reusable workflow serve
every consumer without per-repo configuration.

### Pinning

Use `@v1` for the stable tag once published; pin to `@master` during
iteration, or to a SHA for maximum reproducibility.

## Layout

```
Common-Automation/
├── .github/
│   ├── actions/
│   │   ├── assert-secret/
│   │   │   ├── action.yml               # composite, invokes the .sh
│   │   │   └── assert-secret.bats       # unit tests
│   │   │   ├── assert-secret.sh         # logic
│   │   ├── test-bats/
│   │   │   └── action.yml               # composite: install bats-core, run --recursive
│   │   ├── build-ssh-test-image/
│   │   │   ├── action.yml               # composite (Docker buildx + cache)
│   │   │   └── Dockerfile               # Ubuntu 24.04 + openssh-server
│   │   ├── check-sh-executable/
│   │   │   ├── action.yml               # composite, invokes the .sh
│   │   │   └── check-sh-executable.sh   # CI gate: fail on tracked .sh missing +x
│   │   ├── shellcheck-bash/
│   │   │   ├── action.yml               # composite, invokes the .sh
│   │   │   └── shellcheck-bash.sh       # logic (also sourced by the lint runner)
│   │   ├── actionlint/
│   │   │   ├── action.yml               # composite, invokes the .sh
│   │   │   └── actionlint.bats          # unit tests
│   │   │   ├── actionlint.sh            # logic (docker rhysd/actionlint, pinned)
│   │   ├── action-validator/
│   │   │   ├── action.yml               # composite, invokes the .sh
│   │   │   ├── action-validator.bats    # unit tests
│   │   │   ├── action-validator.sh      # logic (in-repo Docker image, pinned binary)
│   │   │   └── Dockerfile               # bundles mpalmer/action-validator release binary
│   │   ├── yamllint/
│   │   │   ├── action.yml               # composite, invokes the .sh
│   │   │   └── Dockerfile               # pip-installs pinned yamllint from PyPI
│   │   │   ├── yamllint.bats            # unit tests
│   │   │   ├── yamllint.config.yml      # bundled default ruleset (when consumer has none)
│   │   │   ├── yamllint.sh              # logic (in-repo Docker image, pinned yamllint)
│   │   ├── retry/
│   │   │   ├── action.yml               # composite, invokes retry-action.sh
│   │   │   ├── README.md                # input contract + power-user pointer
│   │   │   ├── retry-action.bats        # end-to-end tests for the composite
│   │   │   └── retry-action.sh          # sources retry.sh, calls retry_command
│   │   └── ansible-lint/
│   │       ├── action.yml               # composite, invokes the .sh
│   │       └── Dockerfile               # pip-installs pinned ansible-lint + ansible-core
│   │       ├── ansible-lint.bats        # unit tests
│   │       ├── ansible-lint.config.yml  # bundled default (`production` profile)
│   │       ├── ansible-lint.sh          # logic (auto-skip + in-repo Docker image, pinned)
│   ├── lib/                             # shared shell helpers (no maintainer-only deps)
│   │   ├── colors.sh                    # ANSI colour helper (sourced; TTY/NO_COLOR-gated colorize)
│   │   ├── fix-sh-executable.sh         # shared +x fix engine (hook + runner reuse it)
│   │   ├── get-actionlint-version.sh    # resolves actionlint version (override or versions.env)
│   │   ├── get-action-validator-version.sh  # resolves action-validator version (override or versions.env)
│   │   ├── get-ansible-lint-version.sh  # resolves ansible-lint version (override or versions.env)
│   │   ├── get-bats-version.sh          # resolves bats version (override or versions.env)
│   │   ├── get-yamllint-version.sh      # resolves yamllint version (override or versions.env)
│   │   ├── retry.sh                     # retry primitive (sourced; auto-loads shipped strategies)
│   │   ├── retry-classifiers/           # one <name>_classify per file; sourced on load
│   │   │   ├── docker-registry.sh       # docker / OCI registry transients
│   │   │   ├── http-5xx.sh              # HTTP 5xx in tool output
│   │   │   └── network.sh               # generic network transients (DNS, conn reset, ...)
│   │   ├── retry-strategies/            # one <name>_backoff per file; sourced on load
│   │   │   └── exponential-jitter.sh    # default strategy: exponential growth + symmetric jitter
│   │   ├── versions.env                 # single source of truth for tool versions
│   └── workflows/
│       ├── ci-bash.yml                  # lint + bats + +x gate on PR/push + workflow_call
│       └── ci-yaml.yml                  # actionlint + action-validator on PR/push + workflow_call
├── .githooks/
│   └── pre-commit                       # auto-+x staged .sh files (via .github/lib)
├── scripts/
│   ├── _find-bash.bat                   # resolves Git Bash (not WSL) for the launchers
│   └── _hold-window.sh                  # sourced: keep window open on double-click exit
│   ├── _run-common.sh                   # sourced: resolve target repo, arm hold-window pause
│   ├── _run-lint-yaml-and-bash.sh       # lint half: shellcheck/actionlint/yamllint/... (auto-skip)
│   ├── _run-tests-bash.sh               # test half: every *.bats suite (native or Docker)
│   ├── _to-windows-path.sh              # sourced cross-repo: WSL->Windows path conversion for pwsh.exe args
│   ├── run-ci-yaml-and-bash.sh          # orchestrator: lint + test, combined pass/fail (run everything)
│   ├── run-ci-yaml-and-bash.bat         # double-clickable Windows launcher for the orchestrator
│   ├── fix-permissions.sh               # repo-wide manual +x heal for tracked .sh + .githooks/ (extra pathspecs via args)
│   ├── fix-permissions.bat              # double-clickable Windows launcher
│   ├── setup-hooks.sh                   # one-time: wire up .githooks/
│   ├── setup-hooks.bat                  # double-clickable Windows launcher
└── README.md
```
