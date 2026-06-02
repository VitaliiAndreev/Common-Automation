# retry composite action

Thin YAML wrapper around the [retry primitive](../../lib/retry.sh)
(see the repo's top-level
[Retry primitive](../../../README.md#retry-primitive) subsection for
the underlying contract). Wraps any bash command in a bounded retry
loop with default transient-failure classifiers so a CI step that
flakes on a Docker registry timeout, DNS blip, or HTTP 5xx recovers
automatically instead of failing the run.

## Index

- [Inputs](#inputs)
- [Usage](#usage)
- [For power users](#for-power-users)
- [How sourcing resolves](#how-sourcing-resolves)

## Inputs

| Input                | Required | Default                                                              | Meaning                                                                                                                       |
|----------------------|----------|----------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------|
| `command`            | yes      | -                                                                    | Bash command string. Passed verbatim to `bash -lc` so pipes, redirects, and `&&`/`\|\|` are honoured.                         |
| `max_attempts`       | no       | `5`                                                                  | Hard cap on attempts including the first try (exported as `RETRY_MAX_ATTEMPTS`).                                              |
| `transient_patterns` | no       | `classify_docker_registry:classify_network:classify_http_5xx`        | Colon-separated `<name>_classify` functions deciding which failures are retriable (exported as `RETRY_CLASSIFIERS`).          |

The default `transient_patterns` value matches the recommended set for
dockerised actions: Docker / OCI registry transients, generic network
errors, and HTTP 5xx responses. See the
[top-level Retry primitive subsection](../../../README.md#retry-primitive)
for the patterns each classifier matches.

The registry-transient set also covers Go context-deadline timeouts
(the `context deadline exceeded` wording the docker daemon and buildx
emit when an internal Go-context boundary fires before the underlying
TCP / TLS layer reports its own failure) alongside the existing
TCP / TLS / EOF / 5xx patterns.

## Usage

```yaml
- uses: VitaliiAndreev/GitHub-Common/.github/actions/retry@v1
  with:
    command: docker build -t example:ci .
```

Override the inputs when the defaults are wrong for the call site:

```yaml
- uses: VitaliiAndreev/GitHub-Common/.github/actions/retry@v1
  with:
    command: curl -sSfL https://example.test/api
    max_attempts: "3"
    transient_patterns: classify_network:classify_http_5xx
```

## For power users

The composite intentionally exposes only the three knobs above. If
you need a custom backoff strategy, a different wall-clock budget
(`RETRY_MAX_SECONDS`), or want to retry several commands inside one
step, source the primitive directly in a `run:` block instead:

```yaml
- name: build with custom backoff
  shell: bash
  env:
    RETRY_MAX_SECONDS: "600"
    RETRY_BACKOFF_STRATEGY: my_constant_backoff
    RETRY_CLASSIFIERS: classify_docker_registry
  run: |
    # shellcheck source=/dev/null
    source "${GITHUB_WORKSPACE}/.github/lib/retry.sh"
    my_constant_backoff() { echo "5.000"; }
    retry_command "build" -- docker build -t example .
```

## How sourcing resolves

The action's bash entry resolves `.github/lib/retry.sh` via the
locked env-var-primary / relative-path-fallback contract from
[problem.md](../../../docs/dev/implementation/22-bash-retry-primitive/problem.md):

- In a workflow, `action.yml` exports
  `GHCOMMON_REPO_ROOT=${{ github.action_path }}/../../..` so the
  resolved path is authoritative even if the action directory ever
  moves.
- Outside Actions (local pre-push runner, ad-hoc `bash` invocation),
  the env var is unset and `SCRIPT_DIR/../../..` resolves to the same
  file as long as the repo layout is intact.

Two resolution paths, one target, both deterministic.
