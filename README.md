# GitHub-Common

Shared, tech-agnostic GitHub Actions composite actions and reusable workflows.

Lives outside any single language ecosystem so it can be consumed by
PowerShell, .NET, and future stacks without dragging tooling along.

## Index

- [Actions](#actions)
- [Local development](#local-development)
- [Consuming](#consuming)
- [Layout](#layout)

## Actions

| Action                                          | Purpose                                                           |
|-------------------------------------------------|-------------------------------------------------------------------|
| `.github/actions/assert-secret/`                | Fails a job with a clear message when a required secret is empty. |
| `.github/actions/test-bats/`                    | Installs bats-core and runs every *.bats suite under a given path. |
| `.github/actions/build-ssh-test-image/`         | Builds the SSH target Docker image used by integration tests.     |
| `.github/actions/shellcheck-bash/`              | Runs strict shellcheck on every *.sh under a given directory.     |
| `.github/actions/actionlint/`                   | Lints GitHub Actions workflows and composite actions via pinned rhysd/actionlint. |
| `.github/actions/action-validator/`             | Schema-validates workflows and composite `action.yml` files via pinned mpalmer/action-validator. |

## Local development

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

### Running tests

```bash
./scripts/run-tests.sh
```

`scripts/run-tests.sh` uses native `bats` if installed, otherwise falls
back to Docker (`bats/bats:1.11.0`, same image CI uses). It also runs
`actionlint` over every workflow via the pinned `rhysd/actionlint`
image, and `action-validator` over every workflow and composite
`action.yml` via a pinned image built from the `mpalmer/action-validator`
release binary (Docker required for both checks). Run it before pushing
to catch failures locally. Windows users can double-click
`scripts/run-tests.bat` for the same result.

## Consuming

### Atomic actions

Reference any action directly from another repo's workflow:

```yaml
- uses: VitaliiAndreev/GitHub-Common/.github/actions/assert-secret@v1
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
    uses: VitaliiAndreev/GitHub-Common/.github/workflows/ci-bash.yml@v1
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
    uses: VitaliiAndreev/GitHub-Common/.github/workflows/ci-yaml.yml@v1
```

No inputs - both underlying composite actions self-resolve their
pinned versions. The workflow runs `actionlint` and `action-validator`
as parallel jobs; either underlying directory may be absent.

### Pinning

Use `@v1` for the stable tag once published; pin to `@master` during
iteration, or to a SHA for maximum reproducibility.

## Layout

```
GitHub-Common/
├── .github/
│   ├── actions/
│   │   ├── assert-secret/
│   │   │   ├── action.yml               # composite, invokes the .sh
│   │   │   ├── assert-secret.sh         # logic
│   │   │   └── assert-secret.bats       # unit tests
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
│   │   │   └── shellcheck-bash.sh       # logic (also sourced by scripts/run-tests.sh)
│   │   ├── actionlint/
│   │   │   ├── action.yml               # composite, invokes the .sh
│   │   │   ├── actionlint.sh            # logic (docker rhysd/actionlint, pinned)
│   │   │   └── actionlint.bats          # unit tests
│   │   └── action-validator/
│   │       ├── action.yml               # composite, invokes the .sh
│   │       ├── action-validator.sh      # logic (in-repo Docker image, pinned binary)
│   │       ├── action-validator.bats    # unit tests
│   │       └── Dockerfile               # bundles mpalmer/action-validator release binary
│   ├── lib/                             # shared shell helpers (no maintainer-only deps)
│   │   ├── versions.env                 # single source of truth for tool versions
│   │   ├── get-bats-version.sh          # resolves bats version (override or versions.env)
│   │   ├── get-actionlint-version.sh    # resolves actionlint version (override or versions.env)
│   │   ├── get-action-validator-version.sh  # resolves action-validator version (override or versions.env)
│   │   ├── get-yamllint-version.sh      # resolves yamllint version (override or versions.env)
│   │   └── fix-sh-executable.sh         # shared +x fix engine (hook + runner reuse it)
│   └── workflows/
│       ├── ci-bash.yml                  # lint + bats + +x gate on PR/push + workflow_call
│       └── ci-yaml.yml                  # actionlint + action-validator on PR/push + workflow_call
├── .githooks/
│   └── pre-commit                       # auto-+x staged .sh files (via .github/lib)
├── scripts/
│   ├── run-tests.sh                     # local bats runner (native or Docker)
│   ├── run-tests.bat                    # double-clickable Windows launcher
│   ├── setup-hooks.sh                   # one-time: wire up .githooks/
│   ├── setup-hooks.bat                  # double-clickable Windows launcher
│   ├── fix-permissions.sh               # repo-wide manual +x heal for tracked .sh
│   ├── fix-permissions.bat              # double-clickable Windows launcher
│   ├── _find-bash.bat                   # resolves Git Bash (not WSL) for the launchers
│   └── _hold-window.sh                  # sourced: keep window open on double-click exit
└── README.md
```
