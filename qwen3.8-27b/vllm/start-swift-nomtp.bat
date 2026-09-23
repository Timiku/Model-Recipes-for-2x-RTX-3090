@echo off
setlocal EnableExtensions
title model-recipes serve - qwen3.8-27b / swift-nomtp.yml (swift-nomtp tier)
rem ---- the repo root, derived from this bat's own location (no machine ----
rem ---- specific path: the shared reporoot.ps1 sets REPO + REPO_WSL) ----
for /f "tokens=1,2 delims==" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\_shared\scripts\reporoot.ps1"') do (
    set "%%I=%%J"
)
set "D=Ubuntu"
if defined WSL_DISTRO set "D=%WSL_DISTRO%"
set "MODEL=qwen3.8-27b"
set "TIER=swift-nomtp"
set "YML=swift-nomtp.yml"
set "PORT=8113"
set "CNAME=qwen-27b-swift-nomtp-serve"
set "WAIT=5"

echo ============================================================
echo  serve: %MODEL% / %YML%, the %TIER% tier
echo  port %PORT%, container %CNAME% - this tier holds its two cards
echo  for the life of this session.
echo  stance: SWIFT, DRAFTER OFF - the Swift checkpoint (W4A16,
echo          compressed-tensors, int8 embeddings) on the nomtp body:
echo          no speculative decoding, fp8 KV, the same serve shape
echo          as the nomtp tier. This is the diagnostic baseline for
echo          start-swift-mtp.bat (what the Swift weights do without
echo          the drafter) and the fallback if the drafter misbehaves.
echo          SPEC_N=<n> in swift-nomtp.env re-enables the
echo          built-in MTP head if ever wanted.
echo          Siblings: start-swift-mtp.bat (drafter ON, port 8113),
echo          start-mtp.bat (base checkpoint, port 8113) - SAME
echo          cards. Only one runs at a time; stop this tier with
echo          stop.bat (or close this window) before booting another.
echo.
echo  TO STOP: close this window - the watchdog drops the distro
echo  or run  stop.bat from the model folder.
echo  PRE-FLIGHT: a card held by a live tier (stable above 4 GB for 60 s)
echo  refuses the boot - park any other tenant first. A just-stopped tier
echo  is waited out automatically while its VRAM drains (up to 15 min).
echo ============================================================
echo.
timeout /t %WAIT%

rem ---- is the port already listening? another tier or a stale boot -----
netstat -ano | findstr ":%PORT% " | findstr "LISTENING" >nul
if not errorlevel 1 (
    echo.
    echo Port %PORT% is already listening - stop the current tenant
    echo first with its stop.bat - a previous boot of this tier that is
    echo still up holds the port too; find its window and close it.
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
