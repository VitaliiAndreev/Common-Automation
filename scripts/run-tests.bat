@echo off
setlocal
rem Thin launcher so run-tests.sh can be double-clicked from Explorer.
rem _find-bash.bat resolves Git Bash robustly and sets %BASH%.
rem GHCOMMON_NO_PAUSE tells the .sh's EXIT trap to stay quiet - we
rem hold the cmd window via the `pause` below instead.
call "%~dp0_find-bash.bat" || exit /b 1
set GHCOMMON_NO_PAUSE=1
"%BASH%" "%~dp0run-tests.sh" %*
set rc=%errorlevel%
pause
exit /b %rc%
