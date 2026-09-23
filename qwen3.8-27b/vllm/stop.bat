@echo off
setlocal EnableExtensions
title model-recipes stop - qwen3.8-27b
rem ---- the repo root, derived from this bat's own location (no machine ----
rem ---- specific path: the shared reporoot.ps1 sets REPO + REPO_WSL) ----
for /f "tokens=1,2 delims==" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\_shared\scripts\reporoot.ps1"') do (
    set "%%I=%%J"
)
set "D=Ubuntu"
if defined WSL_DISTRO set "D=%WSL_DISTRO%"
set "MODEL=qwen3.8-27b"

echo ============================================================
echo  stop: every tier of %MODEL%
echo   [1/2] kill any armed watchdog instance of this project
echo   [2/2] compose-down each tier (package yml + its machine .env),
echo          verify the pinned cards and the ports release - up to 60s
echo ============================================================
echo.

rem ---- [1/2] the watchdogs - this project's; matched by this ps1's file name ----
echo [1/2] killing watchdogs...
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*model-recipes-watchdog*' -and $_.CommandLine -like '*-File*' } | ForEach-Object { Write-Host ('   killed ' + $_.ProcessId); Stop-Process -Id $_.ProcessId -Force }"

rem ---- [2/2] the tiers ----
echo [2/2] tearing down the tiers...
wsl -d %D% -- bash %REPO_WSL%/_shared/scripts/down.sh %MODEL%
if not errorlevel 1 goto :down-done
rem a cold WSL session can start before the Windows drive mount settles - the
rem "No such file or directory" flap; one bounded retry after it does
echo   first pass failed - giving the drive mount 5 s, one retry
timeout /t 5 >nul
wsl -d %D% -- bash %REPO_WSL%/_shared/scripts/down.sh %MODEL%
:down-done
echo.
pause
exit /b %ERRORLEVEL%
