@echo off
setlocal EnableExtensions
title model-recipes serve - qwen3.8-27b / superfast.yml
rem ---- the repo root, derived from this bat's own location (no machine ----
rem ---- specific path: the shared reporoot.ps1 sets REPO + REPO_WSL) ----
for /f "tokens=1,2 delims==" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\_shared\scripts\reporoot.ps1"') do (
    set "%%I=%%J"
)
set "D=Ubuntu"
if defined WSL_DISTRO set "D=%WSL_DISTRO%"
set "MODEL=qwen3.8-27b"
set "TIER=superfast"
set "YML=superfast.yml"
set "PORT=8104"
set "CNAME=qwen-27b-superfast-serve"
set "WAIT=5"

echo ============================================================
echo  serve: %MODEL% / %YML%, the %TIER% tier
echo  port %PORT%, container %CNAME% - the two Tis - cards 0 and 1 - are
echo  held for the life of this session. Port %PORT% and the container name
echo  belong to this tier: only one superfast runs at a time, and the
echo  preflight refuses a boot while any other tier holds the cards.
echo  STANCE: the box's machine .env, vllm\superfast.env, carries
echo  this tier's shape: the dflash2 drafter, its batched-token window,
echo  and the 8192-batch prefill knee.
echo.
echo  TO STOP: close this window - the watchdog drops the distro
echo  or run  stop.bat from the model folder.
echo  PRE-FLIGHT: a card holding more than 4GB of VRAM refuses the
echo  boot - park any other tenant first.
echo ============================================================
echo.
timeout /t %WAIT%

rem ---- is the port already listening? ----
netstat -ano | findstr ":%PORT% " | findstr "LISTENING" >nul
if not errorlevel 1 (
    echo.
    echo Port %PORT% is already listening - stop the current superfast
    echo first with its stop.bat before booting its twin.
    pause
    exit /b 1
)

rem ---- arm the watchdog - detached, its own window; the ps1 forces that ----
rem ---- window to normal, never minimized; confirms once, then stays quiet ---
start "model-recipes watchdog - %YML%" powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO%\_shared\scripts\model-recipes-watchdog.ps1" "serve.sh %MODEL% %TIER%" %D%

echo.
echo Booting - patch apply + weight load + cudagraph capture; first boots run
echo to several minutes. One wsl process serves both the boot and the logs;
echo closing this window later is the stop signal.
echo.
wsl -d %D% -- bash %REPO_WSL%/_shared/scripts/serve.sh %MODEL% %TIER%

echo.
echo ------------------------------------------------------------
echo The serve process has exited with code %ERRORLEVEL%; the watchdog will
echo terminate the distro to clean up. If anything looks wrong: run
echo stop.bat, then save this window's output for diagnosis.
echo ------------------------------------------------------------
pause
exit /b %ERRORLEVEL%
