#!/usr/bin/env bash
# Converts a WSL/Linux path to a Windows path for arguments handed to a
# Windows process (pwsh.exe, cmd.exe, ...).
#
# A script running inside WSL with the repo on the Windows filesystem
# sees Linux paths (/mnt/c/...). pwsh.exe -File cannot open that form and
# exits 64 ("file not found"), surfacing as an opaque "<script> exited
# 64". Any path a Windows process consumes must therefore be the Windows
# form (C:\...), which is what wslpath -w produces.
#
# wslpath is always present under WSL, the only place this conversion is
# needed. The passthrough fallback keeps non-WSL shells working (test
# harnesses whose pwsh.exe stub ignores the path it receives), so sourcing
# this helper never hard-depends on wslpath being installed.
#
# Consumed cross-repo: this is the single source of truth, sourced by
# sibling repos (e.g. Infrastructure-Vm-Ansible/ops). Those callers
# resolve it from the Common-Automation sibling checkout by default and
# override the root via COMMON_AUTOMATION_ROOT in their bats suites, where
# CI checks the sibling out under a different path than the dev layout.

_to_windows_path() {
    if command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$1"
    else
        printf '%s' "$1"
    fi
}
