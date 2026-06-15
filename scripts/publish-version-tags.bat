@echo off
setlocal
rem Thin launcher so publish-version-tags.sh can be double-clicked from
rem Explorer. _find-bash.bat resolves Git Bash robustly and sets %BASH%.
rem COMMON_AUTOMATION_NO_PAUSE tells the .sh's EXIT trap to stay quiet - we
rem hold the cmd window via the `pause` below instead.
call "%~dp0_find-bash.bat" || exit /b 1
set COMMON_AUTOMATION_NO_PAUSE=1
"%BASH%" "%~dp0publish-version-tags.sh" %*
set rc=%errorlevel%
pause
exit /b %rc%
