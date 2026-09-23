@echo off
setlocal EnableExtensions
title model-recipes bench - qwen3.8-flash-next / the upstream bench client
rem ---- the repo root, derived from this bat's own location (no machine ----
rem ---- specific path: the shared reporoot.ps1 sets REPO + REPO_WSL) ----
for /f "tokens=1,2 delims==" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\_shared\scripts\reporoot.ps1"') do (
    set "%%I=%%J"
)
set "D=Ubuntu"
if defined WSL_DISTRO set "D=%WSL_DISTRO%"
set "MODEL=qwen3.8-flash-next"
set "TIER=mtp"
if not "%~1"=="" set "TIER=%~1"
set "CFG=%REPO%\%MODEL%\vllm\%TIER%.env"
set "PORT=8115"
for /f "delims=" %%O in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO%\_shared\scripts\mcfg-get.ps1" "%CFG%" PORT 2^>nul') do if not "%%O"=="" set "PORT=%%O"
rem ---- the window is read off the tier's machine delta so the long arm
rem      hits exactly the line the tier serves at (the C4 default) ----
set "WIN=256000"
for /f "delims=" %%W in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO%\_shared\scripts\mcfg-get.ps1" "%CFG%" MAX_MODEL_LEN 2^>nul') do if not "%%W"=="" set "WIN=%%W"

rem ---- one folder per run, stamped; the upstream client's JSONs land in it ----
set "A=%date:~4,2%"
set "B=%date:~7,2%"
set "C=%date:~10,4%"
set "P=%time:~0,2%"
set "P=%P: =0%"
set "Q=%time:~3,2%"
set "R=%time:~6,2%"
set "STAMP=%A%%B%%C%-%P%%Q%%R%"
set "RUNW=%REPO%\%MODEL%\vllm\audit\bench-runs\%STAMP%-upstream-%TIER%"
set "RUNX=%REPO_WSL%/%MODEL%/vllm/audit/bench-runs/%STAMP%-upstream-%TIER%"

echo ============================================================
echo  bench: %MODEL% - the UPSTREAM token-exact client
echo   scripts/benchmark_serving.py of the tree-anchored clone
echo   DominikBucko/qwen38-flash-next-2x3090 - repo-chat recipe,
echo   cache-salted prompts, streamed counts validated against the
echo   API usage. The three arms are the shapes the repo publishes,
echo   so this box's numbers sit directly beside their native box.
echo   arms:  short-decode  128 in  plus 4096 out, warm 1 run 3
echo          long-decode   %WIN%-4096 in plus 4096 out, run 3
echo          boundary      %WIN%-128 in plus 128 out, run 1
echo   log:   %RUNW%
echo   single-stream tier: run it with the assistant idle.
echo ============================================================
echo.

rem ---- the route: an actual HTTP request the tier must answer (the dead
rem      wslrelay slot accepts TCP and hangs; see bench.bat's note) ----
python "%REPO%\_shared\scripts\routecheck.py" %PORT%
if not errorlevel 1 goto route-ok
echo.
echo [bench] port %PORT% is not answering - start the tier first,
echo         then re-run this bat.
pause
goto bench-leave
:route-ok
echo [bench] the tier answers on %PORT% - running the upstream arms.
echo.
wsl -d %D% -- bash %REPO_WSL%/%MODEL%/vllm/scripts/bench-upstream.sh %RUNX% %PORT% %WIN% %TIER%
echo.
echo ============================================================
echo  bench done. The run folder:
echo      %RUNW%
echo  short-decode.json, long-decode.json, boundary.json - the repo's
echo  own schema. Run it again on the other tier (bench-upstream.bat
echo  nomtp) - same shapes, same order: that is the clean A/B.
echo ============================================================
if not defined BENCH_NO_PAUSE pause
:bench-leave
endlocal
exit /b 0
