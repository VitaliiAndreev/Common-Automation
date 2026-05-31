# Problem: Lint YAML workflows

## Index

- [What is changing](#what-is-changing)
- [Why](#why)
- [Solution approach](#solution-approach)
- [Out of scope](#out-of-scope)
- [References](#references)

## What is changing

Add two complementary static-analysis gates over the repo's GitHub
Actions YAML, wired into both the local pre-push runner
(`scripts/run-tests.sh`) and CI (new reusable workflow `ci-yaml.yml`).
Consumer repos pick it up the same way they pick up `ci-bash.yml`.

- `actionlint` lints workflow YAML under `.github/workflows/`.
- `action-validator` lints composite `action.yml` files under
  `.github/actions/`.

## Why

Workflow YAML currently has no automated check. Bash inside `run:`
blocks is invisible to our standalone shellcheck job. Schema errors,
bad `uses:`/`needs:` references, and broken `${{ }}` expressions only
surface when a CI run is wasted on the remote.

Composite `action.yml` files have the same exposure, sharpened by the
fact that this repo's product *is* composite actions: a malformed
`action.yml` here is consumer-facing breakage in every downstream
repo on the next reference. `actionlint` does not cover them - its
composite-action support is interface-level only (input/output names
checked via `uses:` references from workflows), and composite actions
not referenced by any local workflow go unchecked entirely. See
[rhysd/actionlint#401](https://github.com/rhysd/actionlint/issues/401).

A concrete recent example: a malformed `run:` line in
[.github/actions/assert-secret/action.yml](../../../.github/actions/assert-secret/action.yml)
broke every downstream consumer of `GitHub-Common@master` until it
was caught manually. A JSON-schema check against the official GitHub
Actions metadata schema would have flagged it.

## Solution approach

Off-the-shelf survey already done in
[research.md](research.md#tool-survey). Key findings:

- `actionlint` (rhysd) covers GitHub Actions workflow schema,
  `uses:`/`needs:` validation, `${{ }}` expression checks, AND
  embeds shellcheck on every `run: |` block.
- `action-validator` (mpalmer) validates composite action and
  workflow YAML against the official GitHub Actions JSON schemas.
  Single binary, complements actionlint on the surface actionlint
  cannot deeply check.
- `yamllint` adds a formatting layer (indentation, line length, etc.)
  but is most valuable for non-workflow YAML, of which this repo has
  none today.
- `composite-action-lint` (bettermarks) goes deeper than schema for
  composite actions, validating expressions inside their `steps:`.
  Smaller-community fork of actionlint internals; no past incident
  in this repo points at expression-typo bugs inside composite
  steps.
- Marketplace wrappers (`reviewdog/action-actionlint`, others) add
  another action dependency for marginal UX gain.

**Chosen direction: adopt `actionlint` and `action-validator`.**
Together they cover the concrete bug classes this repo has already
seen (workflow schema + expressions + inline bash + composite-action
schema) at minimal added surface. Both slot into the existing local
+ CI dual-track pattern with no new architecture - each gets a
pinned version in `versions.env`, a getter under `.github/lib/`, a
composite action under `.github/actions/`, and a slot in
`run-tests.sh` and `ci-yaml.yml`. Defer `composite-action-lint` and
`yamllint` until a real incident or new file class makes them worth
the additional surface.

## Out of scope

- `composite-action-lint` and other deep composite-step linters
  (deferred until an expression-typo incident inside a composite
  step actually occurs).
- `yamllint` and other formatting-only checks (deferred until non-
  workflow YAML appears in the repo).
- `act` for local workflow execution (debug tool, not a lint).
- Action-version pinning policy (`pin-github-action`, `ratchet`) - a
  separate concern, already handled by manual SHA pinning.
- Linting YAML outside `.github/` - none exists in this repo today.

## References

- [research.md](research.md) - off-the-shelf survey and wiring sketch.
- [scripts/run-tests.sh](../../../scripts/run-tests.sh) - local runner
  pattern to mirror.
- [.github/workflows/ci-bash.yml](../../../.github/workflows/ci-bash.yml)
  - reusable-workflow shape to mirror as `ci-yaml.yml`.
- [.github/lib/versions.env](../../../.github/lib/versions.env) - single
  source of truth for pinned tool versions.
- [action-validator](https://github.com/mpalmer/action-validator) -
  composite-action schema validator.
- [rhysd/actionlint#401](https://github.com/rhysd/actionlint/issues/401)
  - upstream confirmation that actionlint does not deeply lint
  composite actions.
