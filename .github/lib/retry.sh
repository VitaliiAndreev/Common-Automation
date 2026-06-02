#!/usr/bin/env bash
# Sourced retry primitive. Wraps an arbitrary command in a bounded
# retry loop so callers don't reinvent the same `until ... sleep ...`
# pattern. See docs/dev/implementation/22-bash-retry-primitive/ for
# the locked decisions this file implements.
#
# Step 2 scope: budget enforcement (step 1) plus pluggable backoff
# strategy. The default `exponential_jitter_backoff` ships at
# `.github/lib/retry-strategies/exponential-jitter.sh` and is sourced
# automatically on load; consumers register their own
# `<name>_backoff` function and select it via RETRY_BACKOFF_STRATEGY.
# Classifiers (steps 3-4) replace the always-retry branch in later
# commits.
#
# Usage (in a composite action's *.sh, where SCRIPT_DIR is
# `.github/actions/<name>/`):
#
#   # shellcheck source=../../lib/retry.sh
#   source "${SCRIPT_DIR}/../../lib/retry.sh"
#   retry_command "docker build" -- docker build -t foo .
#
# Env vars (read by retry_command, optional):
#
#   RETRY_MAX_ATTEMPTS              Max attempts including first try. Default 5.
#   RETRY_MAX_SECONDS               Wall-clock budget across all attempts. Default 300.
#   RETRY_BACKOFF_STRATEGY          Name of a `<name>_backoff` function to call
#                                   between attempts. Default exponential_jitter_backoff.
#
# GHCOMMON_LIB_DIR (test-only) overrides the directory used to source
# shipped strategies / classifiers; defaults to the dir holding this
# file. See `retry-strategies/exponential-jitter.sh` for the default
# strategy's env vars.

# Locate the lib directory so shipped strategies and classifiers can
# be sourced relative to this file. GHCOMMON_LIB_DIR overrides the
# auto-detected path - tests use that to point at fixture directories
# without forking the primitive.
_RETRY_LIB_DIR="${GHCOMMON_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Auto-source every shipped strategy on load so callers get the
# defaults without having to source each file individually. Consumers
# register additional strategies by sourcing their own file and
# setting RETRY_BACKOFF_STRATEGY to its function name. The glob is
# guarded so a missing directory doesn't error out.
if [[ -d "${_RETRY_LIB_DIR}/retry-strategies" ]]; then
    for _retry_strategy_file in "${_RETRY_LIB_DIR}/retry-strategies/"*.sh; do
        [[ -e "${_retry_strategy_file}" ]] || continue
        # shellcheck source=/dev/null
        source "${_retry_strategy_file}"
    done
    unset _retry_strategy_file
fi

# Runs <cmd...> repeatedly until it succeeds, the attempt count is
# exhausted, or the wall-clock deadline is hit - whichever fires first.
# Returns 0 on success, the command's last non-zero exit on exhaustion,
# or 2 on usage error. Output is passthrough: stdin/stdout/stderr of
# the wrapped command reach the caller unchanged; only this function's
# own diagnostics carry the `retry:` prefix and go to stderr.
retry_command() {
    # Argument shape: <op-name> -- <command...>. op-name is required
    # so diagnostics name the failing operation; `--` separates it
    # from the command vector so the command can contain arbitrary
    # flags without ambiguity.
    if [[ $# -lt 1 || -z "${1:-}" || "${1}" == "--" ]]; then
        echo "retry: usage: retry_command <op-name> -- <command...>" >&2
        return 2
    fi
    local op_name="$1"
    shift

    if [[ $# -lt 1 || "${1}" != "--" ]]; then
        echo "retry: usage: retry_command <op-name> -- <command...>" >&2
        return 2
    fi
    shift

    if [[ $# -lt 1 ]]; then
        echo "retry: usage: retry_command <op-name> -- <command...>" >&2
        return 2
    fi

    local max_attempts="${RETRY_MAX_ATTEMPTS:-5}"
    local max_seconds="${RETRY_MAX_SECONDS:-300}"
    local strategy="${RETRY_BACKOFF_STRATEGY:-exponential_jitter_backoff}"

    # Absolute deadline rather than a per-attempt timer so a sequence
    # of quick failures and short sleeps still adds up against one
    # shared budget - matches the "whichever ceiling fires first"
    # contract in problem.md.
    local deadline=$(( $(date +%s) + max_seconds ))
    local attempt=0
    local exit_code=0

    while :; do
        attempt=$(( attempt + 1 ))

        # Inherit stdin/stdout/stderr - no capture in step 2; the
        # classifier step (3) introduces tee'd capture for inspection
        # without breaking this passthrough contract.
        "$@"
        exit_code=$?

        if (( exit_code == 0 )); then
            return 0
        fi

        if (( attempt >= max_attempts )); then
            echo "retry: ${op_name} exhausted attempts (${max_attempts})" >&2
            return "${exit_code}"
        fi

        # Deadline check uses `>=` so RETRY_MAX_SECONDS=0 means "no
        # retry" (deadline equals start; the first failed attempt
        # is already past it).
        local now
        now=$(date +%s)
        if (( now >= deadline )); then
            echo "retry: ${op_name} exhausted seconds (${max_seconds})" >&2
            return "${exit_code}"
        fi

        # Validate the registered strategy is callable before invoking
        # it. Otherwise a typo'd RETRY_BACKOFF_STRATEGY would silently
        # fail through `"$strategy"` with a "command not found" message
        # that doesn't name the env var - this branch gives the user
        # a single, actionable line.
        if ! declare -F "${strategy}" >/dev/null 2>&1; then
            echo "retry: ${op_name} unknown backoff strategy '${strategy}' (RETRY_BACKOFF_STRATEGY must name a sourced shell function)" >&2
            return 2
        fi

        # Retry index = the number of failed attempts so far. The
        # strategy gets the remaining wall-clock budget as advisory
        # context; the primitive still caps the returned value to it
        # so a misbehaving strategy can't sleep past the deadline.
        local remaining=$(( deadline - now ))
        local raw_sleep capped_sleep
        raw_sleep="$("${strategy}" "${attempt}" "${remaining}")"
        capped_sleep="$(_retry_cap_sleep "${raw_sleep}" "${remaining}")"

        echo "retry: ${op_name} attempt ${attempt} failed (exit ${exit_code}), retrying in ${capped_sleep}s" >&2
        sleep "${capped_sleep}"
    done
}

# Clamps a sleep duration so it never exceeds the remaining budget.
# The cap lives in the primitive (not in each strategy) so every
# registered strategy inherits it for free - keeping the strategy
# contract minimal.
_retry_cap_sleep() {
    local value="$1"
    local remaining="$2"
    awk -v v="${value}" -v r="${remaining}" \
        'BEGIN {
            if (v + 0 < 0) v = 0
            if (r + 0 >= 0 && v + 0 > r + 0) v = r
            printf "%.3f", v
        }'
}
