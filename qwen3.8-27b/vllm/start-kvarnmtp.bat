@echo off
setlocal EnableExtensions
title model-recipes serve - qwen3.8-27b / kvarnmtp.yml (KVarN + MTP tier)
rem ---- the repo root, derived from this bat's own location (no machine ----
rem ---- specific path: the shared reporoot.ps1 sets REPO + REPO_WSL) ----
for /f "tokens=1,2 delims==" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\_shared\scripts\reporoot.ps1"') do (
    set "%%I=%%J"
)
set "D=Ubuntu"
if defined WSL_DISTRO set "D=%WSL_DISTRO%"
set "MODEL=qwen3.8-27b"
set "TIER=kvarnmtp"
set "YML=kvarnmtp.yml"
set "PORT=8116"
set "CNAME=qwen-27b-kvarnmtp-serve"
set "WAIT=5"

echo ============================================================
echo  serve: %MODEL% / %YML%, the %TIER% tier
echo  port %PORT%, container %CNAME% - this tier holds its two cards
echo  for the life of this session.
echo  stance: KVarN int4 KV cache (kvarn_k4v2_g128) WITH the built-in MTP
echo          drafter at n=4 - the concurrent integer-KV shape.
echo          measured 09-14: pool 1,113,340 tokens, 4.25x; the ladder
echo          n=1/2/4/8 = 34.9 / 47.6 / 59.7 / 60.8 tok/s against the fp8
echo          MTP tier's 34.2 / 44.9 / 45.2 / 59.1; acceptance at fp8
echo          parity; PPL 5.3320 against fp8's 5.3041, +0.5 percent.
echo          The bundle installer refuses boot on patch drift.
echo          NOTE KVarN + MTP + prefix caching was reported upstream to
echo          corrupt prompt_logprobs; it did NOT reproduce on 0.29.0 here
echo          with the cache ON, and the PPL above is that check.
echo          NOTE long-ctx concurrency: past about 200k per stream, ONE
echo          stream at a time on this lane is the measured rule; the
echo          shipped cap of 4 is for moderate context. Serve deep-ctx
echo          concurrency on kvarntier.bat - drafter off - or the fp8 tiers.
echo          Siblings: start-kvarntier.bat - SAME port, SAME cards, the
echo          drafter OFF and 1,450,530 tokens - only one of the two runs
echo          at a time. Also start-kvarndflash2.bat and
echo          start-nomtp.bat.
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
