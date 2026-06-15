#!/usr/bin/env bats
# Unit tests for ansible-lint.sh - the composite action's helper that
# lints Ansible content. The most important contract is the auto-skip
# branch when no Ansible content exists (covered without docker so it
# stays green on any workstation); pass/fail outcomes and config-
# discovery are covered against the locally-built
# common-automation/ansible-lint image so the bar matches what consumers
# actually experience. Docker-dependent tests `skip` cleanly when the
# engine is unavailable so the suite remains usable without it.

SCRIPT="${BATS_TEST_DIRNAME}/ansible-lint.sh"

setup() {
    # Run each case from an isolated workdir so the fixture trees
    # cannot leak across tests and so PWD-based detection in the
    # script sees only what the test created.
    workdir="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${workdir}"
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        skip "docker not on PATH"
    fi
    if ! docker info >/dev/null 2>&1; then
        skip "docker daemon not running"
    fi
}

@test "auto-skips when no Ansible content exists" {
    # Pre-image-resolution branch - no docker required, so this test
    # locks the no-op contract even on bare workstations. An empty
    # workdir trivially has none of ansible.cfg/playbooks/roles.
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"skipping"* ]]
}

@test "auto-skips when only unrelated YAML is present" {
    # A repo with arbitrary YAML but no Ansible markers must still
    # auto-skip - the detection key is structural (ansible.cfg /
    # playbooks/ / roles/), not "any YAML".
    printf 'greeting: hello\n' > "${workdir}/data.yml"
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"skipping"* ]]
}

@test "exits 0 on a minimal valid playbook" {
    require_docker
    # Minimal playbook that satisfies the `production` profile:
    # explicit name, fqcn module, no-changed-when handled because
    # debug doesn't change state.
    mkdir -p "${workdir}/playbooks"
    cat > "${workdir}/playbooks/site.yml" <<'YAML'
---
- name: Smoke test play
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Print a message
      ansible.builtin.debug:
        msg: hello
YAML
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
}

@test "exits non-zero on a playbook with a known violation" {
    require_docker
    # `command` instead of a module + missing changed_when is a stable
    # double-violation across ansible-lint versions on the production
    # profile.
    mkdir -p "${workdir}/playbooks"
    cat > "${workdir}/playbooks/bad.yml" <<'YAML'
---
- name: Bad play
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Run a raw command
      ansible.builtin.command: /bin/true
YAML
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -ne 0 ]
}

make_docker_stub() {
    # Build a fake `docker` on PATH that:
    #  - fails `image inspect` so the build branch is exercised every run
    #    (deterministic; no dependence on host docker state),
    #  - delegates `build` to a per-test body file so each case decides
    #    success / transient-failure / permanent-failure deterministically,
    #  - succeeds `run` quietly so the post-build lint step does not
    #    actually try to exec a container.
    # The attempt counter lets the body read $BUILD_ATTEMPT for
    # progressive behaviour (fail-then-succeed).
    stub_dir="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${stub_dir}"
    counter="${BATS_TEST_TMPDIR}/build-attempts"
    : > "${counter}"
    body_file="${BATS_TEST_TMPDIR}/build-body.sh"
    printf '%s\n' "$1" > "${body_file}"
    cat > "${stub_dir}/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
    image)
        # image inspect -> 1 so the build branch always runs.
        exit 1
        ;;
    build)
        BUILD_ATTEMPT=\$(( \$(cat "${counter}" 2>/dev/null || echo 0) + 1 ))
        echo "\${BUILD_ATTEMPT}" > "${counter}"
        # shellcheck disable=SC1090
        source "${body_file}"
        ;;
    run)
        exit 0
        ;;
    info)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "${stub_dir}/docker"
    echo "${stub_dir}"
}

build_attempts() {
    cat "${BATS_TEST_TMPDIR}/build-attempts" 2>/dev/null || echo 0
}

seed_minimal_ansible_repo() {
    # Bypass the auto-skip branch so the retry / build / run pipeline
    # is exercised. Content is irrelevant - the docker run is stubbed.
    mkdir -p "${workdir}/playbooks"
    printf -- '---\n[]\n' > "${workdir}/playbooks/site.yml"
}

@test "retry: docker build succeeds first try -> exit 0, no retry diagnostic" {
    seed_minimal_ansible_repo
    stub_dir="$(make_docker_stub 'exit 0')"
    run env PATH="${stub_dir}:${PATH}" \
        RETRY_MAX_ATTEMPTS=3 RETRY_BACKOFF_INITIAL_SECONDS=0 \
        RETRY_BACKOFF_JITTER_RATIO=0 \
        bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
    [ "$(build_attempts)" -eq 1 ]
    [[ "${output}" != *"retry: ansible-lint docker build attempt"* ]]
}

@test "retry: transient docker build failure recovers on second attempt" {
    seed_minimal_ansible_repo
    # First attempt prints a default-classifier-matching signature and
    # fails; second attempt succeeds. Default classifiers (docker /
    # network / 5xx) are active, so the dial-tcp message is treated as
    # transient and the primitive retries.
    stub_dir="$(make_docker_stub 'if (( BUILD_ATTEMPT < 2 )); then echo "dial tcp 1.2.3.4:443: i/o timeout" >&2; exit 1; fi; exit 0')"
    run env PATH="${stub_dir}:${PATH}" \
        RETRY_MAX_ATTEMPTS=3 RETRY_BACKOFF_INITIAL_SECONDS=0 \
        RETRY_BACKOFF_JITTER_RATIO=0 \
        bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
    [ "$(build_attempts)" -eq 2 ]
    [[ "${output}" == *"retriable via classify_docker_registry"* ]]
}

@test "retry: permanent docker build failure exits immediately" {
    seed_minimal_ansible_repo
    # 'Permission denied' is not in any default classifier's pattern
    # set, so all three reject it and the primitive returns the build
    # exit code without further attempts.
    stub_dir="$(make_docker_stub 'echo "Permission denied" >&2; exit 13')"
    run env PATH="${stub_dir}:${PATH}" \
        RETRY_MAX_ATTEMPTS=5 RETRY_BACKOFF_INITIAL_SECONDS=0 \
        RETRY_BACKOFF_JITTER_RATIO=0 \
        bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 13 ]
    [ "$(build_attempts)" -eq 1 ]
    [[ "${output}" == *"permanent (exit 13)"* ]]
}

@test "honours a consumer-supplied .ansible-lint config" {
    require_docker
    # Same bad playbook as above, but a consumer config downgrades the
    # production profile to `min` which does not enforce
    # command-instead-of-module or no-changed-when. If the consumer
    # config is read the run passes; if the bundled production default
    # is used instead it fails. This proves the discovery path, not
    # ansible-lint internals.
    mkdir -p "${workdir}/playbooks"
    cat > "${workdir}/playbooks/bad.yml" <<'YAML'
---
- name: Bad play
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Run a raw command
      ansible.builtin.command: /bin/true
YAML
    cat > "${workdir}/.ansible-lint" <<'YAML'
profile: min
YAML
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
}
