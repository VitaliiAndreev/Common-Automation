# action-validator composite action

Schema-validates every workflow YAML under `.github/workflows/` AND
every composite `action.yml` under `.github/actions/*/` via a pinned
in-repo Docker image (upstream `mpalmer/action-validator` has no
official image and its npm channel lags releases). Skips silently
with a `::notice::` when neither surface exists so the action is safe
to wire unconditionally into every consumer's `ci-yaml.yml`.

## Index

- [Retry behaviour](#retry-behaviour)
- [See also](#see-also)

## Retry behaviour

The `docker build` step that constructs the pinned image is wrapped
by [the retry primitive](../retry/README.md) with the default
classifier set (`classify_docker_registry:classify_network:classify_http_5xx`):
transient registry timeouts, DNS blips, and HTTP 5xx responses
recover automatically instead of failing the run. The `docker run`
step that actually executes action-validator is NOT wrapped - a
schema violation is a real failure, not transient, and must fail
fast.

## See also

- [Top-level Retry primitive subsection](../../../README.md#retry-primitive)
  for the primitive contract, env vars, and shipped classifiers.
- [retry composite action](../retry/README.md) for using the same
  retry semantics from a workflow `run:` step.
