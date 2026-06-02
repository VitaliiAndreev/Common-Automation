# ansible-lint composite action

Lints Ansible content (playbooks, roles, `ansible.cfg`) via a pinned
in-repo Docker image. Auto-skips with a `::notice::` when none of
`ansible.cfg`, `playbooks/`, or `roles/` exists at the repo root so
the action is safe to wire unconditionally into every consumer's
`ci-yaml.yml`.

## Index

- [Retry behaviour](#retry-behaviour)
- [See also](#see-also)

## Retry behaviour

The `docker build` step that constructs the pinned image is wrapped
by [the retry primitive](../retry/README.md) with the default
classifier set (`classify_docker_registry:classify_network:classify_http_5xx`):
transient registry timeouts, DNS blips, and HTTP 5xx responses
recover automatically instead of failing the run. The `docker run`
step that actually executes ansible-lint is NOT wrapped - a lint
violation is a real failure, not transient, and must fail fast.

## See also

- [Top-level Retry primitive subsection](../../../README.md#retry-primitive)
  for the primitive contract, env vars, and shipped classifiers.
- [retry composite action](../retry/README.md) for using the same
  retry semantics from a workflow `run:` step.
