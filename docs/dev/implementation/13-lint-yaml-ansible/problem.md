# Problem: Lint generic YAML and Ansible content

## Index

- [What is changing](#what-is-changing)
- [Why](#why)
- [Solution approach](#solution-approach)
- [Out of scope](#out-of-scope)
- [References](#references)

## What is changing

Add two complementary static-analysis gates over non-workflow YAML and
Ansible content, wired into both the local pre-push runner
(`scripts/run-tests.sh`) and CI. Consumer repos pick the new coverage up
the same way they pick up `ci-yaml.yml` and `ci-bash.yml` today.

- `yamllint` lints generic YAML anywhere outside `.github/workflows/`
  and `.github/actions/` (those two surfaces are already covered by
  `actionlint` + `action-validator`).
- `ansible-lint` lints Ansible content: `playbooks/`, `roles/`,
  `inventory/`, and `ansible.cfg`. Pulls `yamllint` in as a transitive
  dependency, applying Ansible-aware rules on top.

Delivery vehicle: two new jobs in the existing `ci-yaml.yml` reusable
workflow. Ansible content is YAML, so it belongs alongside the other
YAML linters. The `ansible-lint` job auto-skips when no Ansible
content is present in the caller repo, the same way the existing
`actionlint` and `action-validator` jobs auto-skip when their target
directories do not exist - so non-Ansible consumers pay nothing.

## Why

Feature 04 deferred `yamllint` and other non-workflow YAML coverage
"until non-workflow YAML appears in the repo." That trigger has now
fired in a sibling repo:
[Infrastructure-VM-Ansible](../../../../Infrastructure-VM-Ansible)
ships `ansible.cfg`, `requirements.yml`, a generated inventory layer,
and (per its feature 02 plan) playbooks, roles, and Jinja templates.
None of that surface is reachable by `actionlint` or
`action-validator`, both of which are scoped to GitHub Actions YAML.

Concrete bug classes a malformed Ansible YAML or generic YAML file
would produce today, none of which any current Common-Automation lint
catches:

- A typo in `requirements.yml` (`anisble.posix` instead of
  `ansible.posix`) silently fails at `ansible-galaxy install` time on
  every operator's first bootstrap.
- A misnamed role var (`groupsName` instead of `groupName`) per the
  schema in Infrastructure-VM-Ansible's feature 02 surfaces as a
  runtime KeyError mid-play, after partial mutation of the target VM.
- An indentation mistake in a playbook turns one task into a child of
  another, silently. Ansible accepts the resulting YAML; the play
  succeeds with the wrong semantics.
- `ansible-lint` rules around `risky-shell-pipe`, `command-instead-of-
  module`, `no-changed-when`, and others catch known idempotence and
  drift smells that are easy to author and slow to debug at runtime.

Because the Ansible repo is the first non-workflow-YAML consumer in
the Common-Automation ecosystem and other repos are likely to follow
(`Infrastructure-GitHubRunners` has YAML config; future toolchain
repos will too), the right place to add the coverage is here, not in
the consumer.

## Solution approach

### Candidates considered

| Tool | Source | License | Maintenance | Fit | Integration cost |
|---|---|---|---|---|---|
| [yamllint](https://github.com/adrienverge/yamllint) | OSS, adrienverge | GPL-3.0 | Active, regular releases | Generic YAML: indentation, line length, document markers, duplicate keys | Single Python package, `pip install yamllint`; container image available |
| [ansible-lint](https://github.com/ansible/ansible-lint) | OSS, Ansible/Red Hat | GPL-3.0 | Active, official Ansible project | Ansible semantics: role layout, deprecated modules, idempotence smells, var naming. Pulls in yamllint | Python package; requires ansible-core; container image available |
| [spectral](https://github.com/stoplightio/spectral) | OSS, Stoplight | Apache-2.0 | Active | OpenAPI/AsyncAPI-focused; generic JSON/YAML possible with custom rulesets | Heavier than needed for our YAML surface |
| [prettier --check](https://prettier.io/) | OSS, Vercel | MIT | Active | Formatting only; no semantic checks | Adds Node toolchain to runner |
| [Ansible Galaxy `ansible-test sanity`](https://docs.ansible.com/ansible/latest/dev_guide/testing_sanity.html) | Official | GPL-3.0 | Active | Designed for collections, not application repos | Heavyweight, collection-shaped only |

### Chosen direction: adopt `yamllint` and `ansible-lint`

Together they cover both the generic-YAML formatting layer (the
problem feature 04 deferred) and the Ansible-semantic layer (the new
problem the Ansible repo introduces). Both slot into the existing
local + CI dual-track pattern with no new architecture - each gets a
pinned version in `.github/lib/versions.env`, a getter script under
`.github/lib/`, a composite action under `.github/actions/`, and a
slot in `scripts/run-tests.sh`. `ansible-lint` ships with `yamllint`
as a dependency, but the two are wired separately so a repo that has
generic YAML but no Ansible content picks up `yamllint` alone without
pulling in the Ansible toolchain.

### Workflow layout decision

Both new jobs land in the existing `ci-yaml.yml`. The split axis in
this repo is **language**, not framework: `ci-bash.yml` covers bash,
`ci-yaml.yml` covers YAML. Ansible content is YAML, so a framework-
axis split (`ci-ansible.yml`) would be a category error - it would
also imply future `ci-k8s.yml`, `ci-helm.yml`, `ci-openapi.yml`, none
of which scales as a workflow proliferation strategy.

The "non-Ansible repos pay for the Ansible toolchain" worry is
neutralised by the same auto-skip pattern the existing jobs already
use: `actionlint` and `action-validator` no-op when their target
directories are missing. `ansible-lint` gets the same treatment -
the composite action checks for `ansible.cfg` / `playbooks/` /
`roles/` and skips with a clear log line when none are present. Cost
to a non-Ansible repo: one extra job that runs `test -e` and exits 0.

Resulting shape - one line for every consumer:

```yaml
jobs:
  yaml:
    uses: VitaliiAndreev/Common-Automation/.github/workflows/ci-yaml.yml@master
```

`ci-yaml.yml` ends with four jobs:

- `actionlint` (existing) - workflow semantics, embedded shellcheck.
- `action-validator` (existing) - composite + workflow schema.
- `yamllint` (new) - generic YAML over the repo root, excluding
  `.github/workflows/` and `.github/actions/` (already covered) and
  build artefacts (`.venv/`, `collections/`, `node_modules/`).
- `ansible-lint` (new) - runs from the repo root when Ansible
  content is detected; skips otherwise.

### First downstream consumer

[Infrastructure-VM-Ansible](../../../../Infrastructure-VM-Ansible)
adds a `.github/workflows/ci.yml` calling `ci-yaml.yml` once this
feature ships - the same single-line wiring every other consumer
uses. That repo's feature 02 step
1 (scaffolding) is the surface those linters will run against on day
one; the bar must pass on that surface from the first run, the same
way feature 04 set the bar for `actionlint`/`action-validator`.

## Out of scope

- Linting Jinja templates beyond what `ansible-lint` covers
  natively (no separate `j2lint` adoption today; revisit if a
  template-specific incident occurs).
- `spectral`, OpenAPI linting, and other domain-specific YAML linters
  (no OpenAPI/AsyncAPI surface in the ecosystem yet).
- Formatting-only tools (`prettier`, `yamlfmt`). `yamllint` flags
  formatting drift; auto-formatting is a separate, opinionated
  concern.
- `ansible-test sanity` for collections (this ecosystem ships
  application Ansible, not Galaxy collections).
- Wiring the new workflows into `Infrastructure-VM-Ansible`'s CI -
  tracked separately as part of that repo's feature 02.

## References

- [Feature 04 - lint YML workflows](../04-lint-YML-workflows/problem.md)
  - prior decision that deferred `yamllint` until this trigger fired.
- [.github/workflows/ci-yaml.yml](../../../.github/workflows/ci-yaml.yml)
  - existing workflow this feature extends.
- [.github/workflows/ci-bash.yml](../../../.github/workflows/ci-bash.yml)
  - reusable-workflow shape to mirror as `ci-ansible.yml`.
- [.github/lib/versions.env](../../../.github/lib/versions.env)
  - single source of truth for pinned tool versions.
- [Infrastructure-VM-Ansible feature 02 plan](../../../../Infrastructure-VM-Ansible/docs/dev/implementation/02-groups-users-sudoers-creation/plan.md)
  - the first downstream consumer driving this work.
- [yamllint](https://github.com/adrienverge/yamllint) - generic YAML
  linter.
- [ansible-lint](https://github.com/ansible/ansible-lint) - Ansible-
  semantic linter; ships yamllint as a dependency.
