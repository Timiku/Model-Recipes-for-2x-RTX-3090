@echo off
setlocal EnableExtensions
title model-recipes serve - gemma4-31b / gemma-dual-nomtp.yml
rem ---- the repo root, derived from this bat's own location (no machine ----
rem ---- specific path: the shared reporoot.ps1 sets REPO + REPO_WSL) ----
for /f "tokens=1,2 delims==" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\_shared\scripts\reporoot.ps1"') do (
    set "%%I=%%J"
)
set "D=Ubuntu"
if defined WSL_DISTRO set "D=%WSL_DISTRO%"
set "MODEL=gemma4-31b"
set "TIER=gemma-dual-nomtp"
set "YML=gemma-dual-nomtp.yml"
set "PORT=8032"
set "CNAME=gemma-serve-nomtp"

echo ============================================================
echo  serve: %MODEL% / %YML%, the %TIER% tier - the MTP-OFF / long-ctx shape
echo  port %PORT%, container %CNAME% - the two Tis - cards 0 and 2 - are
echo  held for the life of this session, same as the MTP-on sibling
echo  (port 8032, container gemma-serve-nomtp): park it before this boot or
echo  the preflight refuses.
echo  SHAPE: the drafter is OFF by this yml's own default (SPEC_N:-0), and
echo  the ctx is the source's proven 229376 @ util 0.95, HARD - this yml
echo  takes no MAX_MODEL_LEN knob at all (the MTP tier's 179040 line
echo  lives in its own config file and cannot reach this one). Set
echo  SPEC_N=2 in that same file for the sibling's drafter arm through
echo  this shape instead.
echo  TO STOP: stop.bat - parks this project; if the serve window dies
echo  mid-boot the bat's own [re-arm] box runs the pre-boot checks again,
echo  and the watchdog stays disarmed.
echo  PRE-FLIGHT: the two Tis must be FREE - if the 27B (or the MTP-on
echo  gemma sibling) still holds either card the up-script REFUSES at the
echo  card gate. Park it first (27B: its stop.bat; gemma: its stop.bat).
echo  On first boot a fresh WSL VM is needed (the 09-03 fstab wall).
echo  Booting - weight load + torch/Triton cache warm (cold ~5-7 min);
echo  subsequent boots are faster (warm caches, ~3 min). One wsl process
echo  serves both the boot and the logs; closing this window later is the
echo  stop signal.
echo ============================================================
echo.

rem ---- [0/2] the port must be free: a live listener on the host side of this
rem ---- tier's published port means the tier is already up - booting again
rem ---- is what started this whole mess in the first place.
set "PORTBUSY=0"
for /f "tokens=5" %%A in ('netstat -ano ^| findstr ":%PORT% " ^| findstr "LISTENING"') do (
    set "PORTBUSY=1"
)
if "%PORTBUSY%"=="1" (
    echo ============================================================
    echo  REFUSED: port %PORT% is already in use by:
    for /f "tokens=5" %%A in ('netstat -ano ^| findstr ":%PORT% " ^| findstr "LISTENING"') do (
        echo    PID %%A
    )
    echo  A previous boot of this tier may still be running, or that port is
    echo  serving something else entirely. Find the process above and stop it
    echo  - or close the still-open tier window - before booting here.
    echo ============================================================
    pause
    exit /b 1
)
rem ---- [1/2] arm the per-boot watchdog (detached; this bat stays the primary) ----
echo [1/2] arming the per-boot watchdog...
start "model-recipes watchdog - %YML%" powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO%\_shared\scripts\model-recipes-watchdog.ps1" "serve.sh %MODEL% %TIER%" %D%
echo   armed - it watches for this wsl process and cleans up if the window closes
echo.

rem ---- [2/2] the actual boot - quote-free wsl line (the CRT quote-join rule) ----
echo [2/2] booting %YML% (this is the long part)...
wsl -d %D% -- bash %REPO_WSL%/_shared/scripts/serve.sh %MODEL% %TIER%
set "RC=%ERRORLEVEL%"

rem ---- verdict - one shared mechanism, same as the 27B window ----
echo.
echo ============================================================
echo  verdict - %MODEL% / %YML%, the %TIER% tier
echo ============================================================
wsl -d %D% -- bash %REPO_WSL%/_shared/scripts/verdict.sh sig %MODEL% %TIER%
if "%RC%"=="0" (
    echo  verdict: READY - the API is up; the model is being served.
    echo  stop it with:  stop.bat
    goto :verdict-done
)
echo  verdict: BOOT-FAILED - read the detail box below.
echo.
echo ============================================================
echo  [re-arm] run the pre-boot checks again before retrying
echo ============================================================
echo  What to do, in order:
echo    1. Look at the last ~40 lines of the log the boot wrote to the WSL
echo       runtime area, for the actual error (a CUDA OOM, a missing weight,
echo       a bad card pin are all distinct - this box will not guess for you).
echo    2. If the error is a card-1 (display) contention, make sure NO other
echo       GPU consumer is running, then press a key and re-run this bat.
echo    3. If the error is the WSL interop / mount flap - a No-such-file
echo       error on the Windows drive mount - then the VM is the suspect: a full fresh VM
echo       wsl --shutdown from a separate window clears it - do it only
echo       after you have confirmed nothing else you need is running in WSL.
echo    4. If you see the same error three times in a row, stop retrying:
echo       capture the log and report it as a pattern, not a fluke.
echo.
echo  Press any key to run the pre-boot checks one more time...
pause >nul
echo.
echo re-running pre-flight checks...
wsl -d %D% -- bash %REPO_WSL%/_shared/scripts/verdict.sh show %MODEL% %TIER%
:verdict-done
echo.
rem ---- disarm the watchdog on FAILED boots (its auto-kill must not fire while
rem ---- we are reading the corpse; the next successful window re-arms its own) ----
if not "%RC%"=="0" (
    echo  disarming the watchdog for this failed boot - it will not kill a new boot on window close
    powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*%MODEL%*' -and $_.CommandLine -like '*-File*' -and $_.CommandLine -like '*watchdog*' } | ForEach-Object { Write-Host ('  disarmed ' + $_.ProcessId); Stop-Process -Id $_.ProcessId -Force }"
)
pause
exit /b %RC%
