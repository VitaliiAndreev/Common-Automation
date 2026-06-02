# actionlint composite action

Lints a consumer repo's GitHub Actions surface: every workflow YAML
under `.github/workflows/` (composite actions are linted transitively
via `uses:` references from those workflows). Uses the pinned upstream
`rhysd/actionlint:<version>` Docker image directly - unlike the
sibling lint actions, there is no in-repo Dockerfile because upstream
publishes exact-version tags that satisfy the repo's pin contract.
Skips silently with a `::notice::` when no workflows exist so the
action is safe to wire unconditionally into every consumer's
`ci-yaml.yml`.

## Index

- [Retry behaviour](#retry-behaviour)
- [See also](#see-also)

## Retry behaviour

The `docker pull` step that fetches the pinned upstream image on
first use is wrapped by [the retry primitive](../retry/README.md)
with the default classifier set
(`classify_docker_registry:classify_network:classify_http_5xx`):
transient registry timeouts, DNS blips, and HTTP 5xx responses
recover automatically instead of failing the run. The `docker run`
step that actually executes actionlint is NOT wrapped - a lint
violation is a real failure, not transient, and must fail fast. The
pull only runs on a `docker image inspect` miss, so cached runs skip
the retry path entirely.

## See also

- [Top-level Retry primitive subsection](../../../README.md#retry-primitive)
  for the primitive contract, env vars, and shipped classifiers.
- [retry composite action](../retry/README.md) for using the same
  retry semantics from a workflow `run:` step.
