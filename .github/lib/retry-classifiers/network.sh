#!/usr/bin/env bash
# Default classifier for generic network transients - the OS-level
# error strings produced by glibc, busybox, and most CLI tools when
# DNS or connection setup fails for non-application-specific reasons.
# These complement classify_docker_registry: the docker classifier
# matches docker / OCI client wording, this one matches the underlying
# socket / resolver errors that surface from any tool (curl, git,
# apt, pip, etc.).
#
# This file lives under retry-classifiers/ so retry.sh sources it
# automatically on load. See ../retry.sh for the classifier contract.

# Patterns covered (case-insensitive grep):
#   - Temporary failure in name resolution
#   - Could not resolve host
#   - Connection timed out
#   - Connection reset by peer
#   - Network is unreachable
classify_network() {
    local _exit_code="$1" stdout_file="$2" stderr_file="$3"
    # Both streams are scanned: which fd carries the error message
    # varies by tool (curl uses stderr, some Python tools fold to
    # stdout under tee'd buffering), so checking only one would miss
    # real transients.
    # Single -E regex with alternation rather than repeated `-e` flags:
    # mingw / git-bash grep aborts (SIGABRT) on `-q` + multiple `-e`
    # patterns when scanning more than one file, which is exactly the
    # call shape the classifier contract requires.
    grep -E -i -q \
        'Temporary failure in name resolution|Could not resolve host|Connection timed out|Connection reset by peer|Network is unreachable' \
        "${stdout_file}" "${stderr_file}"
}
