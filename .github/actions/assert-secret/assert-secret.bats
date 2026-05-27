#!/usr/bin/env bats
# Unit tests for assert-secret.sh.
# Run with: bats actions/assert-secret/assert-secret.bats

SCRIPT="${BATS_TEST_DIRNAME}/assert-secret.sh"

@test "exits 0 when value is non-empty" {
    run "${SCRIPT}" "real-value" "MY_SECRET"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "exits 1 when value is empty string" {
    run "${SCRIPT}" "" "MY_SECRET"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"MY_SECRET secret is not set"* ]]
}

@test "exits 1 when value is spaces only" {
    run "${SCRIPT}" "   " "MY_SECRET"
    [ "${status}" -eq 1 ]
}

@test "exits 1 when value is tab only" {
    run "${SCRIPT}" $'\t' "MY_SECRET"
    [ "${status}" -eq 1 ]
}

@test "exits 1 when value is newline only" {
    run "${SCRIPT}" $'\n' "MY_SECRET"
    [ "${status}" -eq 1 ]
}

@test "exits 1 when value is mixed whitespace" {
    run "${SCRIPT}" $' \t\n ' "MY_SECRET"
    [ "${status}" -eq 1 ]
}

@test "error message includes the secret name" {
    run "${SCRIPT}" "" "PSGALLERY_API_KEY"
    [[ "${output}" == *"PSGALLERY_API_KEY"* ]]
}

@test "error message points to GitHub settings location" {
    run "${SCRIPT}" "" "ANY_NAME"
    [[ "${output}" == *"Settings -> Secrets and variables -> Actions"* ]]
}

@test "uses GitHub Actions error annotation format" {
    run "${SCRIPT}" "" "ANY_NAME"
    [[ "${output}" == "::error::"* ]]
}

@test "exits 2 when name argument is missing" {
    # Argument-handling guard; distinct exit code from the empty-secret case
    # so a misuse is distinguishable from a legitimate empty-secret failure.
    run "${SCRIPT}" "value"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing required <name> argument"* ]]
}

@test "value containing leading/trailing whitespace still passes if it has non-whitespace content" {
    run "${SCRIPT}" "  real-value  " "MY_SECRET"
    [ "${status}" -eq 0 ]
}

@test "value containing shell metacharacters does not break the script" {
    run "${SCRIPT}" '$(echo bad); rm -rf /' "MY_SECRET"
    [ "${status}" -eq 0 ]
}
