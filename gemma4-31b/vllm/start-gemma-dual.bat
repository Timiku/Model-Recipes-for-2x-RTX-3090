@echo off
setlocal EnableExtensions
title model-recipes serve - gemma4-31b / gemma-dual.yml
rem ---- the repo root, derived from this bat's own location (no machine ----
rem ---- specific path: the shared reporoot.ps1 sets REPO + REPO_WSL) ----
for /f "tokens=1,2 delims==" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\_shared\scripts\reporoot.ps1"') do (
    set "%%I=%%J"
)
set "D=Ubuntu"
if defined WSL_DISTRO set "D=%WSL_DISTRO%"
set "MODEL=gemma4-31b"
set "TIER=gemma-dual"
set "YML=gemma-dual.yml"
set "PORT=8032"
set "CNAME=gemma-serve"
set "WAIT=5"

echo ============================================================
echo  serve: %MODEL% / %YML%, the %TIER% tier
echo  port %PORT%, container %CNAME% - the two Tis - cards 0 and 2 - are
echo  held for the life of this session. Every other tier on this box
echo  (the qwen tiers, the gemma no-MTP sibling) pins the same two cards:
echo  park them before this boot or the preflight refuses.
echo.
echo  TO STOP: close this window - the watchdog drops the distro
echo  or run  stop.bat from the model folder.
echo  PRE-FLIGHT: a card held by a live tier (stable above 4 GB for 60 s)
echo  refuses the boot; a just-stopped tier is waited out automatically
echo  while its VRAM drains (up to 15 min). The MTP drafter arm is ON by
echo  default (SPEC_N=2); set SPEC_N=0 in its own config file to kill it.
echo ============================================================
echo.
timeout /t %WAIT%

rem ---- is the port already listening? ----
netstat -ano | findstr ":%PORT% " | findstr "LISTENING" >nul
if not errorlevel 1 (
    echo.
    echo Port %PORT% is already listening - stop the current tenant
    echo first with this model's stop.bat. If no window holds it, a
    echo stale listener from a wedged stop can remain: run stop.bat
    echo once more, and 'wsl --shutdown' clears the distro as the
    echo last resort.
    pause
    exit /b 1
)

rem ---- arm the watchdog - detached, its own window; the ps1 forces that ----
rem ---- window to normal, never minimized; confirms once, then stays quiet ---
start "model-recipes watchdog - %YML%" powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO%\_shared\scripts\model-recipes-watchdog.ps1" "serve.sh %MODEL% %TIER%" %D%

echo.
echo Booting - weight load + cudagraph capture; the first boot of the
echo v0.28.0 image re-JITs the caches, allow several minutes. One wsl
echo process serves both the boot and the logs; closing this window
echo later is the stop signal.
echo.
wsl -d %D% -- bash %REPO_WSL%/_shared/scripts/serve.sh %MODEL% %TIER%

echo.
echo ------------------------------------------------------------
echo The serve process has exited with code %ERRORLEVEL%. The verdict, as
echo recorded on the WSL side:
wsl -d %D% -- bash %REPO_WSL%/_shared/scripts/verdict.sh show %MODEL% %TIER%
echo ------------------------------------------------------------
echo Reading the verdict (the WSL-side status file is quoted above):
echo   READY         - the probe answered and a 1-token generation worked;
echo                   the tier is serving (exit code 0).
echo   REFUSED       - a live tier holds this tier's pair of cards (stable above 4 GB
echo                   for 60 s): stop it (its stop.bat), then re-run.
echo   DRAIN-TIMEOUT - a just-stopped tier was still shedding VRAM after
echo                   the drain window: re-run once nvidia-smi is clear.
echo   FATAL         - the WSL GPU stack never answered (cold start, or
echo                   the 'mount -a failed' line - the fstab is broken).
echo   BOOT FAILED / - the container log tail sits above this box; save
echo   TIMEOUT       the window's output, then run stop.bat to clean up.
echo   (no file)     - this run predates the status file; the log tail
echo                   above this box is the verdict.
echo ------------------------------------------------------------
echo.
echo [disarm] killing this run's watchdog - the WSL side stays up, so an
echo          immediate re-run of this bat finds a warm VM.
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*model-recipes-watchdog*' -and $_.CommandLine -like '*%MODEL%*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
pause
exit /b %ERRORLEVEL%
