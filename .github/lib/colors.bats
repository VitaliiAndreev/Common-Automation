#!/usr/bin/env bats
# Unit tests for .github/lib/colors.sh.
# Run with: bats .github/lib/colors.bats

setup() {
    # Start from a known-clean colour env so a tester's own NO_COLOR /
    # FORCE_COLOR does not leak into the assertions below.
    unset NO_COLOR FORCE_COLOR
    # shellcheck source=./colors.sh
    source "${BATS_TEST_DIRNAME}/colors.sh"
}

@test "colorize wraps text in the colour code when FORCE_COLOR is set" {
    FORCE_COLOR=1 run colorize green "hello"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '\033[32mhello\033[0m')" ]
}

@test "colorize emits plain text when NO_COLOR is set, even on a forced path" {
    # NO_COLOR has no effect by itself here (tests are not a TTY), so pair it
    # with FORCE_COLOR to prove suppression beats the force flag.
    NO_COLOR=1 FORCE_COLOR=1 run colorize green "hello"
    [ "${status}" -eq 0 ]
    [ "${output}" = "hello" ]
}

@test "colorize emits plain text when colour is disabled (not a TTY, no force)" {
    run colorize green "hello"
    [ "${status}" -eq 0 ]
    [ "${output}" = "hello" ]
}

@test "colorize leaves text unchanged for an unknown colour name" {
    FORCE_COLOR=1 run colorize chartreuse "hello"
    [ "${status}" -eq 0 ]
    [ "${output}" = "hello" ]
}

@test "colorize joins multiple text arguments" {
    FORCE_COLOR=1 run colorize red "a" "b" "c"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '\033[31ma b c\033[0m')" ]
}

@test "colorize supports the full palette" {
    # name:code pairs via a heredoc (not declare -A) so the test itself runs
    # on bash 3.2 too. The heredoc keeps the while loop in the current shell,
    # so run's status/output are visible to the assertions.
    while IFS=: read -r name num; do
        FORCE_COLOR=1 run colorize "${name}" "x"
        [ "${status}" -eq 0 ]
        [ "${output}" = "$(printf '\033[%smx\033[0m' "${num}")" ]
    done <<'PAIRS'
reset:0
bold:1
dim:2
red:31
green:32
yellow:33
blue:34
magenta:35
cyan:36
PAIRS
}

@test "color_enabled reflects FORCE_COLOR and NO_COLOR" {
    FORCE_COLOR=1 run color_enabled
    [ "${status}" -eq 0 ]

    NO_COLOR=1 run color_enabled
    [ "${status}" -eq 1 ]

    # Neither set, and the test harness stdout is not a TTY -> disabled.
    run color_enabled
    [ "${status}" -eq 1 ]
}

@test "color_enabled honours the fd argument under the env overrides" {
    # The env overrides win regardless of which fd is queried; the fd only
    # decides the fallback TTY check (neither stdout nor stderr is a TTY in
    # the bats harness, so that fallback path is disabled either way).
    FORCE_COLOR=1 run color_enabled 2
    [ "${status}" -eq 0 ]

    NO_COLOR=1 run color_enabled 2
    [ "${status}" -eq 1 ]

    run color_enabled 2
    [ "${status}" -eq 1 ]
}

@test "colorize_fd wraps text in the colour code when FORCE_COLOR is set" {
    FORCE_COLOR=1 run colorize_fd 2 green "hello"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '\033[32mhello\033[0m')" ]
}

@test "colorize_fd emits plain text when colour is disabled (no force, not a TTY)" {
    run colorize_fd 2 green "hello"
    [ "${status}" -eq 0 ]
    [ "${output}" = "hello" ]
}

@test "colorize_fd leaves text unchanged for an unknown colour name" {
    FORCE_COLOR=1 run colorize_fd 2 chartreuse "hello"
    [ "${status}" -eq 0 ]
    [ "${output}" = "hello" ]
}

@test "colorize is the stdout-gated wrapper over colorize_fd (back-compatible)" {
    # colorize <name> <text> must behave exactly as colorize_fd 1 <name>.
    FORCE_COLOR=1 run colorize red "x"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '\033[31mx\033[0m')" ]
}
