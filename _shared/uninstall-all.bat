@echo off
setlocal EnableExtensions
title model-recipes uninstall all
rem ---- the repo root, derived from this bat's own location (no machine ----
rem ---- specific path: the shared reporoot.ps1 sets REPO + REPO_WSL) ----
for /f "tokens=1,2 delims==" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\reporoot.ps1"') do (
    set "%%I=%%J"
)
set "D=Ubuntu"
if defined WSL_DISTRO set "D=%WSL_DISTRO%"
set "DEEP="
if /i "%~1"=="deep" set "DEEP=--deep"

echo ============================================================
echo  model-recipes UNINSTALL ALL - every model on this box
echo.
echo   will delete, for every model under the repo:
echo     - the tiers (compose-down each, verified against the cards)
echo     - the WSL runtime area  %D%:~/model-recipes-rt/<model>/
echo     - the vllm images (all of them - this is the box-level nuke)
echo   will NOT touch:
echo     - any user-set WEIGHTS_DIR (your data)
echo     - the Windows-side model folders - the package templates, the
echo       machine .envs, the weights, the patches (confirm to remove)
echo     - the WSL distro itself, unless you pass "deep"
echo   add the argument  "deep"  to also wsl --terminate the distro
echo ============================================================
echo.
pause

wsl -d %D% -- bash %REPO_WSL%/_shared/scripts/uninstall-all-core.sh %DEEP%
if defined DEEP (
    echo   terminating the distro %D% ^(deep^):
    wsl -t %D%
)
pause
exit /b %ERRORLEVEL%
