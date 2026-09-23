@echo off
setlocal EnableExtensions
title model-recipes bench - qwen3.8-27b
rem ---- repo root, from this bat's own location, via the shared reporoot.ps1 ----
for /f "tokens=1,2 delims==" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\_shared\scripts\reporoot.ps1"') do (
    set "%%I=%%J"
)
set "D=Ubuntu"
if defined WSL_DISTRO set "D=%WSL_DISTRO%"
set "MODEL=qwen3.8-27b"

rem ---- usage: bench.bat [port] [near-full] [full-out] --------------------
rem ----   no port: probe the tier .envs' ports in ascending order with the
rem ----   shared routecheck (a real HTTP request the tier must answer) and
rem ----   bench whichever answers. An explicit port pins it.
rem ----   near-full: the curated depth the records were taken at. Every
rem ----   qwen tier runs the 262144 window, so the one target is 250000
rem ----   (the old per-port map - 210000 on 8113 - was the 218955-window
rem ----   relic; the env cutover made every qwen tier 262144).
rem ----   full-out: the near-full sample length, default 512. A smaller
rem ----   value (32) is the quick pass for a slow deep-ctx tier; every
rem ----   record line prints gen=N, so a shortened run is always visible.
rem ---- The harness is the shared _shared\scripts\bench_speed.py, run
rem ---- inside the WSL distro (the tier's port is WSL-internal; the
rem ---- measurement must share its network namespace). The gate is the
rem ---- shared routecheck: exit 2 = refused = tier down; exit 3 = the
rem ---- port listens but never answers = a dead WSL relay slot, cleared
rem ---- by 'wsl --shutdown' (the 09-04 blackhole class).
rem ---- The tier must already be UP: start-mtp.bat, start-nomtp.bat,
rem ---- start-superfast.bat, start-kvarntier.bat,
rem ---- start-kvarnmtp.bat, or start-kvarndflash2.bat.
rem ---- This bat never boots, parks, or kills anything; it reads the live
rem ---- endpoint and writes the record to vllm\logs\bench\.

set "PORT=%~1"
set "NEARFULL=%~2"
set "FULLOUT=%~3"
if not defined FULLOUT set "FULLOUT=512"

where python >nul 2>nul
if errorlevel 1 (
    echo python was not found on PATH. The route gate is stdlib python, so
    echo it needs python on the PATH that runs this bat. Install it and re-run.
    if defined BENCH_NO_PAUSE exit /b 1
    pause
    exit /b 1
)

rem ---- no port given: probe the .env-declared ports, take the first live one
if not defined PORT for /f "delims=" %%P in ('powershell -NoProfile -Command "Get-ChildItem '%~dp0*.env' | ForEach-Object { Select-String -Path $_.FullName -Pattern '^PORT=(\d+)' } | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique"') do (
    python "%REPO%\_shared\scripts\routecheck.py" %%P >nul 2>nul
    if not errorlevel 1 if not defined PORT set "PORT=%%P"
)
if defined PORT (
    python "%REPO%\_shared\scripts\routecheck.py" %PORT% >nul 2>nul
    if errorlevel 3 goto route-dead
    if errorlevel 1 goto route-down
    goto route-ok
)

echo.
echo No %MODEL% tier is up: none of the .env-declared ports is answering.
echo Boot one first - start-mtp.bat, start-nomtp.bat, start-superfast.bat,
echo start-kvarntier.bat, start-kvarnmtp.bat or
echo start-kvarndflash2.bat - then re-run this bat ^(or pin the port:
echo bench.bat 8113^).
if defined BENCH_NO_PAUSE exit /b 1
pause
exit /b 1

:route-down
echo.
echo [bench] port %PORT% is not accepting - the tier is down. Boot it
echo         first ^(start-mtp.bat or its sibling^), then re-run this bat.
if defined BENCH_NO_PAUSE exit /b 1
pause
exit /b 1

:route-dead
echo.
echo [bench] port %PORT% listens but never answers - a dead WSL relay
echo         slot outlived the removed container. The clear: run
echo         'wsl --shutdown' in a terminal - a fresh VM rewrites the
echo         relay table ^(the tier is parked for that window anyway^) -
echo         then boot and re-run this bat.
if defined BENCH_NO_PAUSE exit /b 1
pause
exit /b 1

:route-ok
echo [bench] port %PORT% answers - the tier is up; running the shared bench.
if not defined NEARFULL set "NEARFULL=250000"

set "OUT=%REPO%\%MODEL%\vllm\logs\bench"
if not exist "%OUT%" mkdir "%OUT%"
for /f "tokens=1 delims=" %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "TS=%%T"
set "OUTFILE=%OUT%\bench-%MODEL%-%PORT%-%TS%.txt"

echo == bench: %MODEL%, port %PORT%, near-full %NEARFULL%, sample %FULLOUT% == > "%OUTFILE%"
echo    gate: routecheck ^(real HTTP^); harness: shared bench_speed.py in WSL distro %D% >> "%OUTFILE%"

echo.
echo Writing the record to %OUTFILE% ...
echo The near-full runs each pay the full prefill; expect a few minutes each.
echo.
wsl -d %D% -- python3 %REPO_WSL%/_shared/scripts/bench_speed.py %PORT% %NEARFULL% %FULLOUT% --label %MODEL% >> "%OUTFILE%" 2>&1

echo ------------------------------------------------------------
type "%OUTFILE%"
echo ------------------------------------------------------------
echo Done - the record above is also at:
echo   %OUTFILE%
echo.
echo The tier is left exactly as found. When you are ready:
echo stop.bat, then the next tier's start bat.
if defined BENCH_NO_PAUSE exit /b 0
pause
exit /b 0
