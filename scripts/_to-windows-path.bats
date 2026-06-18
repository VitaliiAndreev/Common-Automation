#!/usr/bin/env bats
# Tests for _to-windows-path.sh - the sourced WSL->Windows path helper
# shared across repos. Two branches: wslpath present (convert) and
# wslpath absent (passthrough). Each is forced deterministically via a
# scratch PATH so the suite is identical on a WSL dev box and a bare
# Linux CI runner (where wslpath is genuinely absent).
# Run with: bats scripts/_to-windows-path.bats

SCRIPT="${BATS_TEST_DIRNAME}/_to-windows-path.sh"

setup() {
    # Scratch bin for the wslpath stub used by the convert-branch test;
    # an isolated dir keeps it off the real PATH for the other cases.
    SCRATCH_BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${SCRATCH_BIN}"
}

@test "sourcing defines _to_windows_path" {
    source "${SCRIPT}"
    declare -F _to_windows_path >/dev/null
}

@test "passthrough returns the input unchanged when wslpath is absent" {
    # Set PATH to the empty scratch bin inside the shell (not via env,
    # which would also lose the bash binary). command -v wslpath then
    # fails on every host - including a WSL dev box with a real
    # /usr/bin/wslpath - so the helper must echo its argument verbatim.
    # source uses an absolute path and printf is a builtin, so neither
    # needs PATH.
    run bash -c '
        PATH="$2"
        source "$1"
        _to_windows_path "/mnt/c/a_Code/x"
    ' _ "${SCRIPT}" "${SCRATCH_BIN}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "/mnt/c/a_Code/x" ]
}

@test "delegates to wslpath -w when wslpath is present" {
    # Stub wslpath on a scratch PATH so the convert branch is exercised
    # without a real WSL. The stub echoes a marker plus its argument so
    # the test can assert both that the branch ran and that -w "$1" was
    # forwarded.
    cat >"${SCRATCH_BIN}/wslpath" <<'STUB'
#!/usr/bin/env bash
# Expect: wslpath -w <path>
[ "$1" = "-w" ] || { echo "missing -w flag" >&2; exit 1; }
printf 'WIN:%s' "$2"
STUB
    chmod +x "${SCRATCH_BIN}/wslpath"

    run env PATH="${SCRATCH_BIN}:/usr/bin:/bin" bash -c '
        source "$1"
        _to_windows_path "/mnt/c/a_Code/x"
    ' _ "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "WIN:/mnt/c/a_Code/x" ]
}
