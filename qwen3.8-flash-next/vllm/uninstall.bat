@echo off
setlocal EnableExtensions
title model-recipes uninstall - qwen3.8-flash-next
rem ---- the repo root, derived from this bat's own location (no machine ----
rem ---- specific path: the shared reporoot.ps1 sets REPO + REPO_WSL) ----
for /f "tokens=1,2 delims==" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\_shared\scripts\reporoot.ps1"') do (
    set "%%I=%%J"
)
set "D=Ubuntu"
if defined WSL_DISTRO set "D=%WSL_DISTRO%"
set "MODEL=qwen3.8-flash-next"
set "DEEP="
if /i "%~1"=="deep" set "DEEP=--deep"

echo ============================================================
echo  model-recipes UNINSTALL: %MODEL%
echo.
echo   will delete:
echo     - the WSL runtime area  %D%:~/model-recipes-rt/%MODEL%/
echo       (the JIT cache, the boot log, and the PLE table file - the
echo       disk tier's first boot writes 48.5 GiB there; removing it
echo       costs one table recompute on the next first boot)
echo     - the vllm image the package templates name, and only when
echo       no other model's package yml still references it; plus the
echo       vendor base image this model's Dockerfile pins and pulls
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

rem ---- the vendor base the Dockerfile pins is this model's own fact: ----
rem ---- uninstall-core prunes the locked build; the base pull drops here ----
for /f "tokens=2" %%B in ('findstr /b /c:"FROM " "%~dp0Dockerfile"') do (
    echo   pruning the vendor base image the build pinned:
    wsl -d %D% -- docker rmi %%B 2>nul
)
if defined DEEP (
    echo   terminating the distro %D% ^(deep^):
    wsl -t %D%
)
pause
exit /b %ERRORLEVEL%
