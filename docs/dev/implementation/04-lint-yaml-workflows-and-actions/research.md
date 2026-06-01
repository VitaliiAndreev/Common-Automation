# Research: YAML / workflow linting

Goal: catch malformed or buggy workflow YAML before it reaches the
remote and burns a CI run. We have shellcheck on bash and bats on
behaviour; this is the parallel question for the YAML side.

## Index

- [Categories of issue worth catching](#categories-of-issue-worth-catching)
- [Tool survey](#tool-survey)
  - [actionlint](#actionlint)
  - [yamllint](#yamllint)
  - [Others worth knowing about, less central](#others-worth-knowing-about-less-central)
- [What actionlint would have caught in this project](#what-actionlint-would-have-caught-in-this-project)
- [Wiring sketch](#wiring-sketch)
- [Recommendation when we circle back](#recommendation-when-we-circle-back)

## Categories of issue worth catching

| Failure mode | Detected by |
|---|---|
| YAML syntax (indentation, unmatched quotes) | `yamllint`, also any sane parser |
| GitHub Actions schema (wrong keys, wrong types) | `actionlint` |
| `uses:` references to non-existent actions | `actionlint` (best-effort, no network) |
| `${{ }}` expression syntax / context errors | `actionlint` |
| Bash inside `run:` blocks | `actionlint` (embeds shellcheck) |
| `needs:` referring to non-existent jobs | `actionlint` |
| Action version pinning policy | `pin-github-action`, `ratchet` (separate concern) |

The killer insight: `actionlint` runs shellcheck on every `run: |`
block. So our strict bash bar applies *inside YAML* without us
having to extract every snippet into a `.sh`. That covers the bulk
of the YAML-side regression risk in one tool.

## Tool survey

### actionlint

- Author: rhysd (https://github.com/rhysd/actionlint)
- Single Go binary, also published as `rhysd/actionlint` Docker image.
- Used by Kubernetes, GitHub themselves, and most serious workflow-
  authoring projects.
- Covers categories 2-6 in the table above.
- Limitations:
  - Some `uses:` references cannot be verified without network access.
  - Some expression-context validations are best-effort.
  - Does not actually run the workflow - static analysis only.

### yamllint

- Python tool, mature, configurable.
- Catches indentation, line-length, trailing whitespace, missing
  document-start markers - the formatting layer below actionlint.
- Useful as a *layered* check if we care about YAML beyond just
  `.github/workflows/*.yml` (Dockerfile is not YAML; `.gitattributes`
  is not YAML; that leaves not much else in this repo today).
- Default rule set is opinionated (line-length 80). Most adopters
  ship a small `.yamllint` config to relax noisy rules.

### Others worth knowing about, less central

- **`act`** (nektos/act) - runs workflows locally in Docker.
  Heavyweight; reproduces issues rather than preventing them. Useful
  for debugging a failing workflow, not for pre-push linting.
- **`prettier` + YAML plugin** - formats YAML to a style. Style only,
  no semantic checks.
- **Marketplace "validate workflow" actions** - mostly thin wrappers
  around actionlint with weaker UX. Skip in favour of using actionlint
  directly.

## What actionlint would have caught in this project

Re-applying the tool mentally against this repo's recent workflow
history surfaces real bugs:

- `scan-paths` referenced inside a job step while the typed input was
  declared as `scan-path` (caught us once during the input rename).
- `if: github.event_name == 'workflow_call'` - a condition that can
  never be true because `event_name` reflects the caller's event when
  invoked via `workflow_call`. actionlint warns about this exact
  pattern.
- Quoting inside `${{ }}` expressions - common silent bug class.
- `needs:` referring to a non-existent job - typo-class bug.
- Bash issues inside `run: |` blocks - the same `[ ]` -> `[[ ]]` style
  finding strict shellcheck flagged in `assert-secret.sh`, but for
  inline workflow bash that we currently do not lint at all.

The inline-bash coverage is the part most easily lost without a
linter: bash hidden inside YAML never reaches our scripts/-level
shellcheck job.

## Wiring sketch

When we come back to this, the implementation is a small parallel of
how `shellcheck` was added to `run-tests.sh`:

```bash
# scripts/run-tests.sh - new section
run_actionlint() {
    echo "=== actionlint ==="
    if command -v actionlint >/dev/null 2>&1; then
        (cd "${repo_root}" && actionlint)
        return $?
    fi
    MSYS_NO_PATHCONV=1 docker run --rm \
        -v "${repo_root}:/repo" -w /repo \
        rhysd/actionlint:1.7.7
}

# ... call it the same way the others are called:
if ! run_actionlint; then failures+=("actionlint"); fi
```

```yaml
# .github/workflows/ci-bash.yml - new job
actionlint:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: docker://rhysd/actionlint:1.7.7
```

The `reviewdog/action-actionlint` wrapper is an alternative for the
CI step that surfaces results as PR-line annotations; it is nicer
UX but introduces another action dependency.

## Recommendation when we circle back

Adopt actionlint alone. Coverage-vs-friction ratio is the best of any
option here, and it slots into our existing local + CI dual-track
without inventing new patterns.

Defer yamllint until we have YAML that is not workflow YAML and find
ourselves wishing it were checked - currently there is none.

Image version pinning, image-update cadence, and shellcheck-rule
alignment between actionlint's embedded shellcheck and our standalone
shellcheck should all be settled at the same time as the wiring, to
avoid drift.
