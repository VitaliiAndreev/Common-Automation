# yamllint composite action

Lints plain YAML (every `*.yml` / `*.yaml` outside the curated exclude
list covering workflows, composite actions, and non-source trees) via
a pinned in-repo Docker image. Skips silently with a `::notice::` when
no eligible files exist so the action is safe to wire unconditionally
into every consumer's `ci-yaml.yml`.

## Index

- [Retry behaviour](#retry-behaviour)
- [See also](#see-also)

## Retry behaviour

The `docker build` step that constructs the pinned image is wrapped
by [the retry primitive](../retry/README.md) with the default
classifier set (`classify_docker_registry:classify_network:classify_http_5xx`):
transient registry timeouts, DNS blips, and HTTP 5xx responses
recover automatically instead of failing the run. The `docker run`
step that actually executes yamllint is NOT wrapped - a lint
violation is a real failure, not transient, and must fail fast.

## See also

- [Top-level Retry primitive subsection](../../../README.md#retry-primitive)
  for the primitive contract, env vars, and shipped classifiers.
- [retry composite action](../retry/README.md) for using the same
  retry semantics from a workflow `run:` step.
