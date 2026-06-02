#!/usr/bin/env bash
# Default backoff strategy for the retry primitive: exponential growth
# with symmetric jitter. Industry-standard shape (AWS SDK, Google SRE
# book) - preserves the convergence guarantee while spreading retries
# across time so a thundering herd of consumers doesn't pile up on
# the same offsets during a real incident.
#
# This file lives in its own location under retry-strategies/ so it
# doubles as the worked example for consumers writing their own
# <name>_backoff functions. See ../retry.sh for the strategy contract
# and how the primitive locates / invokes registered strategies.

# Strategy contract (must hold for every registered <name>_backoff):
#   $1            retry index (1 for the first retry after attempt 1 failed)
#   $2            remaining wall-clock budget in seconds (advisory; the
#                 primitive caps the returned value to this regardless)
#   stdout        sleep duration in seconds, decimal allowed
#   exit 0        success; any non-zero propagates as a usage error
#
# Env vars (all optional; see ../retry.sh for documented defaults):
#   RETRY_BACKOFF_INITIAL_SECONDS  base sleep for the first retry
#   RETRY_BACKOFF_MAX_SECONDS      cap on the unjittered sleep
#   RETRY_BACKOFF_MULTIPLIER       growth factor per retry index
#   RETRY_BACKOFF_JITTER_RATIO     symmetric jitter band (0 = disabled)
#   RETRY_BACKOFF_JITTER_SEED      test-only deterministic seed
exponential_jitter_backoff() {
    local retry_index="$1"
    # $2 (remaining) is intentionally unused: the deadline cap lives
    # in the primitive so it applies uniformly to every strategy.
    # Strategies are free to use it for shaping (e.g. a "decorrelated
    # jitter" variant might want it) but the default does not.
    awk \
        -v r="${retry_index}" \
        -v initial="${RETRY_BACKOFF_INITIAL_SECONDS:-2}" \
        -v max_sleep="${RETRY_BACKOFF_MAX_SECONDS:-60}" \
        -v mult="${RETRY_BACKOFF_MULTIPLIER:-2}" \
        -v jitter="${RETRY_BACKOFF_JITTER_RATIO:-0.3}" \
        -v seed="${RETRY_BACKOFF_JITTER_SEED:-}" '
    BEGIN {
        base = initial * (mult ^ (r - 1))
        if (base > max_sleep) base = max_sleep

        # Seed once per call so a fixed RETRY_BACKOFF_JITTER_SEED plus
        # retry index r yields a reproducible jitter sample. Offsetting
        # by r stops every retry from picking the same fraction.
        if (seed != "") {
            srand(seed + r)
        } else {
            srand()
        }

        # rand() is [0,1); map to [-jitter, +jitter) so the sleep is
        # symmetric around base.
        delta = (rand() * 2 - 1) * jitter
        value = base * (1 + delta)
        if (value < 0) value = 0
        printf "%.3f", value
    }'
}
