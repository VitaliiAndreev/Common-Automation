#!/usr/bin/env bash
# Fails with a clear message when a required secret value is empty
# or whitespace-only. Mirrors [string]::IsNullOrWhiteSpace semantics
# from the original pwsh implementation so calling workflows do not
# observe a behaviour change after the bash rewrite.
#
# Usage: assert-secret.sh <value> <name>
#   <value>  The secret value to check (typically passed via env to
#            avoid command-line exposure - see action.yml).
#   <name>   The secret name, used in the failure message so the
#            operator knows which secret to add.

set -euo pipefail

value="${1-}"
name="${2-}"

if [[ -z "${name}" ]]; then
    echo "::error::assert-secret.sh: missing required <name> argument" >&2
    exit 2
fi

# Strip all whitespace (spaces, tabs, newlines) to detect whitespace-only
# values the same way [string]::IsNullOrWhiteSpace does in .NET.
trimmed="$(printf '%s' "${value}" | tr -d '[:space:]')"

if [[ -z "${trimmed}" ]]; then
    echo "::error::${name} secret is not set. Add it under Settings -> Secrets and variables -> Actions." >&2
    exit 1
fi
