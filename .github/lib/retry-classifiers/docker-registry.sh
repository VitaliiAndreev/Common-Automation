#!/usr/bin/env bash
# Default classifier for Docker / OCI registry transients. Matches the
# error strings the docker client and BuildKit emit when a pull, push,
# or manifest probe can't reach the registry (DNS lookup ok, but TCP
# refused / timing out, TLS handshake hung, 5xx from the registry,
# or a truncated response). These are exactly the failures that flaked
# the ansible-lint action runs that motivated this primitive - none
# of them is a real problem with the image being built, so retrying
# is the right behaviour.
#
# This file lives under retry-classifiers/ so retry.sh sources it
# automatically on load. See ../retry.sh for the classifier contract
# and how the primitive locates / invokes registered classifiers.

# Patterns covered (case-insensitive grep):
#   - dial tcp .*: i/o timeout
#   - dial tcp .*: connection refused
#   - failed to do request: Head .* dial tcp
#   - received unexpected HTTP status: 5[0-9][0-9]   (docker pulls)
#   - TLS handshake timeout
#   - unexpected EOF                                  (truncated response)
#   - context deadline exceeded                       (Go ctx timeout: daemon / buildx)
classify_docker_registry() {
    local _exit_code="$1" stdout_file="$2" stderr_file="$3"
    # Both streams are scanned: docker writes most progress to stderr
    # but some compose / buildx variants put registry diagnostics on
    # stdout, so checking only one would miss real transients.
    # Single -E regex with alternation rather than repeated `-e` flags:
    # mingw / git-bash grep aborts (SIGABRT) on `-q` + multiple `-e`
    # patterns when scanning more than one file, which is exactly the
    # call shape the classifier contract requires.
    grep -E -i -q \
        'dial tcp .*: i/o timeout|dial tcp .*: connection refused|failed to do request: Head .* dial tcp|received unexpected HTTP status: 5[0-9][0-9]|TLS handshake timeout|unexpected EOF|context deadline exceeded' \
        "${stdout_file}" "${stderr_file}"
}
