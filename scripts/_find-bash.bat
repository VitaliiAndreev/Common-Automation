@echo off
rem Resolves Git Bash regardless of install location and exposes it in
rem the caller's environment as %BASH%. Exits non-zero on failure so
rem the caller can short-circuit with `|| exit /b 1` after CALL.
rem
rem Why this is not a one-liner: PATH-lookup `bash` on Windows resolves
rem to WSL bash (System32 launcher), which tries to exec /bin/bash
rem inside the default distro - that fails when the distro is
rem docker-desktop or otherwise minimal. We derive Git Bash from
rem git.exe instead. `where git` may return several entries depending
rem on install layout - mingw64/bin/git.exe and cmd/git.exe both
rem happen on the same install - so we probe multiple offsets from
rem the first hit:
rem
rem   git.exe layout                bash.exe location
rem   -----------------------------  ---------------------------------
rem   <root>\cmd\git.exe             <root>\bin\bash.exe (+ usr\bin)
rem   <root>\bin\git.exe             <root>\bin\bash.exe (+ usr\bin)
rem   <root>\mingw64\bin\git.exe     <root>\bin\bash.exe (+ usr\bin)

for /f "delims=" %%i in ('where git.exe 2^>nul') do (
    set "GITDIR=%%~dpi"
    goto :gitfound
)
echo ERROR: git.exe not found on PATH.
echo Install Git for Windows from https://git-scm.com/download/win
exit /b 1

:gitfound
set "BASH=%GITDIR%..\bin\bash.exe"
if not exist "%BASH%" set "BASH=%GITDIR%..\usr\bin\bash.exe"
if not exist "%BASH%" set "BASH=%GITDIR%..\..\bin\bash.exe"
if not exist "%BASH%" set "BASH=%GITDIR%..\..\usr\bin\bash.exe"
if not exist "%BASH%" (
    echo ERROR: bash.exe not found relative to git at %GITDIR%
    exit /b 1
)
exit /b 0
