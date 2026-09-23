@echo off
setlocal EnableExtensions
title model-recipes uninstall - gemma4-31b
rem ---- the repo root, derived from this bat's own location (no machine ----
rem ---- specific path: the shared reporoot.ps1 sets REPO + REPO_WSL) ----
for /f "tokens=1,2 delims==" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\_shared\scripts\reporoot.ps1"') do (
    set "%%I=%%J"
)
set "D=Ubuntu"
if defined WSL_DISTRO set "D=%WSL_DISTRO%"
set "MODEL=gemma4-31b"
set "DEEP="
if /i "%~1"=="deep" set "DEEP=--deep"

echo ============================================================
echo  model-recipes UNINSTALL: %MODEL%
echo.
echo   will delete:
echo     - the WSL runtime area  %D%:~/model-recipes-rt/%MODEL%/
echo       (the JIT cache + the boot log - the only thing this model
echo       ever had in the distro)
echo     - the vllm image the package templates name, and only when
echo       no other model's package yml still references it
echo   will NOT touch:
echo     - any user-set WEIGHTS_DIR outside the runtime area (your data)
echo     - the Windows-side model folder - the package templates, the
echo       machine .envs, the patches, and the weights (confirm first)
echo     - the WSL distro itself, unless you pass "deep"
echo   add the argument  "deep"  to also wsl --terminate the distro
echo ============================================================
echo.
pause

wsl -d %D% -- bash %REPO_WSL%/_shared/scripts/uninstall-core.sh %MODEL% %DEEP%
if defined DEEP (
    echo   terminating the distro %D% ^(deep^):
    wsl -t %D%
)
pause
exit /b %ERRORLEVEL%
