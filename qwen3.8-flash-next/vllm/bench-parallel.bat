@echo off
setlocal EnableExtensions EnableDelayedExpansion
title model-recipes bench-parallel - qwen3.8-flash-next
rem ---- repo root, from this bat's own location, via the shared reporoot.ps1 ----
for /f "tokens=1,2 delims==" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\_shared\scripts\reporoot.ps1"') do (
    set "%%I=%%J"
)
set "D=Ubuntu"
if defined WSL_DISTRO set "D=%WSL_DISTRO%"
set "MODEL=qwen3.8-flash-next"

rem ---- usage: bench-parallel.bat [port] [max-n] [tokens] ------------------
rem ----   no port: 0 = the shared climber probes the .env-declared ports
rem ----   and benches whichever tier is up. An explicit port pins it.
rem ----   max-n: the top of the concurrency climb. It fires 2, 4, 8, 16, ...
rem ----   up to max-n, so max-n 8 measures 2, 4 and 8 at once. Default 8.
rem ----   tokens: the prompt size per stream. Default 16000; raise it to
rem ----   stress a deep prefix-cache resume. The tier must already be up;
rem ----   this bat never boots it.
rem ---- The climber is the shared _shared\scripts\bench_parallel.py, run
rem ---- inside the WSL distro.

set "PORT=%~1"
if "%PORT%"=="" set "PORT=0"
set "MAXN=%~2"
if "%MAXN%"=="" set "MAXN=8"
set "TOK=%~3"
if "%TOK%"=="" set "TOK=16000"

rem ---- the candidate ports: the .env-declared PORT= lines, sorted, unique --
set "PORTS="
for /f "delims=" %%P in ('powershell -NoProfile -Command "Get-ChildItem '%~dp0*.env' | ForEach-Object { Select-String -Path $_.FullName -Pattern '^PORT=(\d+)' } | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique"') do set "PORTS=!PORTS!,%%P"
if defined PORTS set "PORTS=%PORTS:~1%"

set "OUT=%REPO%\%MODEL%\vllm\logs\bench"
if not exist "%OUT%" mkdir "%OUT%"
for /f "tokens=1 delims=" %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "TS=%%T"
set "OUTFILE=%OUT%\bench-parallel-%MODEL%-%PORT%-%TS%.txt"

echo ============================================================
echo  bench-parallel: %MODEL%
echo  climbs concurrent streams 2, 4, 8, 16, ... up to max-n %MAXN%,
echo  firing that many completions at once at each level and checking
echo  that every stream returns cleanly and the engine is still up.
echo  A level that breaks is the ceiling; the climb stops there.
echo  port: %PORT%   0 = whichever %MODEL% tier is up
echo  candidate ports: %PORTS%
echo  record: %OUTFILE%
echo ============================================================
echo.
echo The tier must already be up: start-mtp.bat or start-nomtp.bat.
echo This bat never boots, parks, or kills anything.
echo.
echo == bench-parallel: %MODEL%, port %PORT%, max-n %MAXN%, tokens %TOK% == > "%OUTFILE%"
wsl -d %D% -- python3 %REPO_WSL%/_shared/scripts/bench_parallel.py --port %PORT% --ports %PORTS% --max-n %MAXN% --tokens %TOK% --label %MODEL% >> "%OUTFILE%" 2>&1
echo ------------------------------------------------------------
type "%OUTFILE%"
echo ------------------------------------------------------------
echo Done - the record above is also at:
echo   %OUTFILE%
if defined BENCH_NO_PAUSE exit /b 0
pause
exit /b 0
