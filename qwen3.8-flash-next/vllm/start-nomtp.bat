@echo off
setlocal EnableExtensions
title model-recipes serve - qwen3.8-flash-next / nomtp.yml (the drafter-off tier)
rem ---- the repo root, derived from this bat's own location (no machine ----
rem ---- specific path: the shared reporoot.ps1 sets REPO + REPO_WSL) ----
for /f "tokens=1,2 delims==" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\_shared\scripts\reporoot.ps1"') do (
    set "%%I=%%J"
)
set "D=Ubuntu"
if defined WSL_DISTRO set "D=%WSL_DISTRO%"
set "MODEL=qwen3.8-flash-next"
set "TIER=nomtp"
set "YML=nomtp.yml"
set "PORT=8116"
set "CNAME=qwen38-flashnext-nomtp-serve"
set "WAIT=5"

echo ============================================================
echo  serve: %MODEL% / %YML%, the %TIER% tier
echo  port %PORT%, container %CNAME% - both cards are held for the
echo  life of this session.
echo  stance: MTP off - MTP_DEPTH=0 with its coupled 1600 retention, the
echo          K=0 arm the wrapper honors by omitting the speculative config
echo          - via the machine .env, vllm\nomtp.env. Same proven
echo          rung otherwise (t24): the 256,000 window, the vendor's
echo          4.13 GiB KV pool, the 30 GiB/rank offload, 84 hot slots,
echo          port 8116. The MTP tier is start-mtp.bat, port 8115.
echo.
echo  TO STOP: close this window - the watchdog drops the distro
echo  or run  stop.bat from the model folder.
echo  PRE-FLIGHT: a card held by a live tier - stable above 4 GB for 60 s -
echo  refuses the boot; park any other tenant first. A just-stopped tier is
echo  waited out automatically while its VRAM drains - up to 15 min.
echo ============================================================
echo.
timeout /t %WAIT%

rem ---- is the port already listening? another tier or a stale boot -----
netstat -ano | findstr ":%PORT% " | findstr "LISTENING" >nul
if not errorlevel 1 (
    echo.
    echo Port %PORT% is already listening - stop the current tenant
    echo first with its stop.bat. If no window holds it, a stale
    echo listener from a wedged stop can remain: run this model's
    echo stop.bat once more, and 'wsl --shutdown' clears the distro
    echo as the last resort.
    pause
    exit /b 1
)

rem ---- arm the watchdog - detached, its own window; the ps1 forces that ----
rem ---- window to normal, never minimized; confirms once, then stays quiet ---
start "model-recipes watchdog - %YML%" powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO%\_shared\scripts\model-recipes-watchdog.ps1" "serve.sh %MODEL% %TIER%" %D%

echo.
echo Booting - the PLE table staging, the UVA expert tier, weight load and
echo cudagraph capture; the first boot (PLE table write-through) runs well past
echo ten minutes. One wsl process serves both the boot and the logs;
echo closing this window later is the stop signal.
echo.
wsl -d %D% -- bash %REPO_WSL%/_shared/scripts/serve.sh %MODEL% %TIER%

echo.
echo ------------------------------------------------------------
echo The serve process has exited with code %ERRORLEVEL%. The verdict, as
echo recorded on the WSL side:
wsl -d %D% -- bash %REPO_WSL%/_shared/scripts/verdict.sh show %MODEL% %TIER%
echo ------------------------------------------------------------
echo Reading the verdict - the WSL-side status file is quoted above:
echo   READY         - the probe answered and a 1-token generation worked;
echo                   the tier is serving - exit code 0.
echo   REFUSED       - a live tier holds this tier's pair of cards - stable
echo                   above 4 GB for 60 s. Stop it, then re-run.
echo   DRAIN-TIMEOUT - a just-stopped tier was still shedding VRAM after
echo                   the drain window: re-run once nvidia-smi is clear.
echo   FATAL         - the WSL GPU stack never answered - cold start, or
echo                   the 'mount -a failed' line - the fstab is broken.
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
