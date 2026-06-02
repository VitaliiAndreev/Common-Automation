#!/usr/bin/env bash
# Default classifier for HTTP 5xx server errors that surface as text
# in a tool's captured output. 5xx is the canonical "server-side
# transient" - the request was well-formed, the server failed to
# serve it. Retrying is the IETF-recommended behaviour (RFC 9110
# section 15.6). 4xx is deliberately not matched: those are
# permanent for the caller.
#
# This file lives under retry-classifiers/ so retry.sh sources it
# automatically on load. See ../retry.sh for the classifier contract.

# Patterns covered (case-insensitive grep):
#   - HTTP/<version> 5xx     (curl -v, wget, generic HTTP responses)
#   - Server Error: 5xx      (high-level CLI tools' human-readable form)
classify_http_5xx() {
    local _exit_code="$1" stdout_file="$2" stderr_file="$3"
    # Single -E regex with alternation rather than repeated `-e` flags:
    # mingw / git-bash grep aborts (SIGABRT) on `-q` + multiple `-e`
    # patterns when scanning more than one file, which is exactly the
    # call shape the classifier contract requires.
    grep -E -i -q \
        'HTTP/[0-9.]+ 5[0-9][0-9]|Server Error: 5[0-9][0-9]' \
        "${stdout_file}" "${stderr_file}"
}
