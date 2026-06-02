#!/usr/bin/env bash
# Sourced retry primitive. Wraps an arbitrary command in a bounded
# retry loop so callers don't reinvent the same `until ... sleep ...`
# pattern. See docs/dev/implementation/22-bash-retry-primitive/ for
# the locked decisions this file implements.
#
# Step 4 scope: budget enforcement (step 1), pluggable backoff
# strategy (step 2), pluggable transient-failure classifiers
# (step 3), and shipped default classifiers covering Docker / OCI
# registry, generic network, and HTTP 5xx transients (step 4).
# Classifiers are shell functions named in RETRY_CLASSIFIERS; they
# inspect the captured exit code plus stdout/stderr files and decide
# retriable vs permanent. Empty list (the default) preserves the
# always-retry behaviour from steps 1-2.
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
#   RETRY_CLASSIFIERS               Colon-separated list of `<name>_classify`
#                                   shell functions. Each is asked whether a
#                                   failed attempt is retriable. ANY accept ->
#                                   retry; ALL reject -> return immediately.
#                                   Empty (default) means "always retry" so the
#                                   step-1/2 behaviour persists when no
#                                   classifier is opted into.
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

# Same auto-source pattern for shipped classifiers - keeping the two
# directories symmetric so the next built-in classifier (or strategy)
# follows the same drop-in-a-file convention with no primitive edit.
if [[ -d "${_RETRY_LIB_DIR}/retry-classifiers" ]]; then
    for _retry_classifier_file in "${_RETRY_LIB_DIR}/retry-classifiers/"*.sh; do
        [[ -e "${_retry_classifier_file}" ]] || continue
        # shellcheck source=/dev/null
        source "${_retry_classifier_file}"
    done
    unset _retry_classifier_file
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

    # Classifier list. Empty means "always retry" (steps 1-2 contract).
    # Anything else opts the caller into permanent-vs-transient triage:
    # at least one classifier must accept the failure before we sleep.
    local -a classifiers=()
    if [[ -n "${RETRY_CLASSIFIERS:-}" ]]; then
        IFS=':' read -ra classifiers <<< "${RETRY_CLASSIFIERS}"
    fi
    local have_classifiers=0
    (( ${#classifiers[@]} > 0 )) && have_classifiers=1

    # Capture directory only exists when at least one classifier is
    # configured. The zero-classifier path stays byte-for-byte the
    # step-2 path: no tee, no temp files, no extra child processes.
    # That keeps the cost of "I don't care about classification" at
    # zero. Cleanup uses a function-local RETURN trap so every exit
    # path (success, exhaustion, permanent rejection, usage error)
    # frees the directory without explicit per-branch wiring.
    local cap_dir=""
    if (( have_classifiers )); then
        cap_dir="$(mktemp -d)"
        # shellcheck disable=SC2064
        trap "rm -rf '${cap_dir}'" RETURN
    fi

    # Absolute deadline rather than a per-attempt timer so a sequence
    # of quick failures and short sleeps still adds up against one
    # shared budget - matches the "whichever ceiling fires first"
    # contract in problem.md.
    local deadline=$(( $(date +%s) + max_seconds ))
    local attempt=0
    local exit_code=0
    local matched_classifier=""

    while :; do
        attempt=$(( attempt + 1 ))
        matched_classifier=""

        if (( have_classifiers )); then
            # Tee the command's stdout/stderr to capture files while
            # still forwarding live output to the caller's fds, so
            # classifiers can inspect the text the user would see -
            # nothing is swallowed. The FDs target tee process
            # substitutions; closing them after the command exits
            # signals EOF to tee, and waiting on its PID ensures the
            # capture files are fully flushed before classifiers read
            # them.
            local stdout_cap="${cap_dir}/stdout"
            local stderr_cap="${cap_dir}/stderr"
            : > "${stdout_cap}"
            : > "${stderr_cap}"

            local out_fd err_fd tee_out_pid tee_err_pid
            # shellcheck disable=SC2312
            # SC2312: the tee here is intentionally backgrounded via
            # process substitution; its exit status is irrelevant
            # because we wait on its PID below.
            exec {out_fd}> >(tee "${stdout_cap}")
            tee_out_pid=$!
            # shellcheck disable=SC2312
            exec {err_fd}> >(tee "${stderr_cap}" >&2)
            tee_err_pid=$!

            # shellcheck disable=SC2261
            # SC2261: shellcheck doesn't track named-fd allocations
            # ({var}>) and so misreads `>&"$out_fd" 2>&"$err_fd"` as
            # two redirections competing for stderr. They target
            # distinct caller-allocated fds.
            "$@" 1>&"${out_fd}" 2>&"${err_fd}"
            exit_code=$?

            exec {out_fd}>&-
            exec {err_fd}>&-
            wait "${tee_out_pid}" "${tee_err_pid}" 2>/dev/null || true
        else
            # Inherit stdin/stdout/stderr verbatim - no capture, no
            # tee, identical to step 2.
            "$@"
            exit_code=$?
        fi

        if (( exit_code == 0 )); then
            return 0
        fi

        # Classifier triage runs before the attempts/deadline checks
        # because a permanent failure should fail fast - no point
        # spending another attempt slot or sleeping out the budget if
        # the error is, say, a syntax error.
        if (( have_classifiers )); then
            local classifier last_rejector="" last_rejector_stderr=""
            local classifier_err_file="${cap_dir}/classifier_err"
            for classifier in "${classifiers[@]}"; do
                # Unknown classifier is a usage error - mirroring the
                # unknown-strategy branch. Silently treating a typo as
                # "no match" would either hide bugs or flip permanent
                # failures into permanent passes depending on order.
                if ! declare -F "${classifier}" >/dev/null 2>&1; then
                    echo "retry: ${op_name} unknown classifier '${classifier}' (RETRY_CLASSIFIERS must list sourced shell functions)" >&2
                    return 2
                fi
                : > "${classifier_err_file}"
                if "${classifier}" "${exit_code}" "${stdout_cap}" "${stderr_cap}" 2>"${classifier_err_file}"; then
                    matched_classifier="${classifier}"
                    break
                fi
                last_rejector="${classifier}"
                last_rejector_stderr="$(cat "${classifier_err_file}" 2>/dev/null || true)"
            done

            if [[ -z "${matched_classifier}" ]]; then
                # All classifiers rejected - this is a permanent
                # failure. Name the last rejector and surface its
                # stderr (if any) so the caller can tell why the
                # decision was made without re-running with set -x.
                if [[ -n "${last_rejector_stderr}" ]]; then
                    echo "retry: ${op_name} attempt ${attempt} permanent (exit ${exit_code}); rejected by ${last_rejector}: ${last_rejector_stderr}" >&2
                else
                    echo "retry: ${op_name} attempt ${attempt} permanent (exit ${exit_code}); rejected by ${last_rejector}" >&2
                fi
                return "${exit_code}"
            fi
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

        # Two diagnostic shapes: the classifier-driven case names the
        # accepting classifier (so operators can see which heuristic
        # decided this was transient); the classifier-less case keeps
        # the step-1/2 wording for log-grep continuity.
        if [[ -n "${matched_classifier}" ]]; then
            echo "retry: ${op_name} attempt ${attempt} retriable via ${matched_classifier}, sleeping ${capped_sleep}s" >&2
        else
            echo "retry: ${op_name} attempt ${attempt} failed (exit ${exit_code}), retrying in ${capped_sleep}s" >&2
        fi
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
