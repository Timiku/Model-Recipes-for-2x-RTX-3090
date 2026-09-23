@echo off
setlocal EnableExtensions EnableDelayedExpansion
title model-recipes install - qwen3.8-flash-next
rem ---- the repo root, derived from this bat's own location (no machine ----
rem ---- specific path: the shared reporoot.ps1 sets REPO + REPO_WSL) ----
for /f "tokens=1,2 delims==" %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\_shared\scripts\reporoot.ps1"') do (
    set "%%I=%%J"
)
set "D=Ubuntu"
if defined WSL_DISTRO set "D=%WSL_DISTRO%"
set "MODEL=qwen3.8-flash-next"
rem The two tier machine .envs this model's wizard keeps in step (two-tier
rem config: the box's DEVICE_PAIR / BIND_HOST / WEIGHTS_DIR live here, beside the
rem bats; the package templates in vllm\package\ are applied silently at boot).
set "MCFG=%REPO%\_shared\scripts\mcfg-set.ps1"
set "MGET=%REPO%\_shared\scripts\mcfg-get.ps1"

echo ============================================================
echo  model-recipes install: %MODEL%
echo  before stage 0 - the box prereqs, with a continue gate
echo  stage 0 - this window: the Windows-side environment gate
echo  the wizard - the box's machine .envs, keep-or-change on each
echo  stages 1-5 in WSL:  env, runtime area, images, weights, manifest
echo ============================================================
echo.

rem ============================================================
rem  prerequisites - what the box must bring before continuing
rem ============================================================
set "HAVE_DISTRO="
set "HAVE_SYS="
set "HAVE_DOCKER="
set "HAVE_NVRUN="
set "HAVE_COMPOSE="
set "HAVE_DRV="

echo  prereqs - the [NO] lines below; 3-5 get auto-fixed by the env setup
echo  below when you continue, the rest are your to-do before continuing:
echo.
wsl -d %D% -- echo PING < nul >nul 2>nul
if not errorlevel 1 (
    set "HAVE_DISTRO=1"
    echo   [ok] 1. WSL with the distro %D%
) else (
    echo   [NO] 1. WSL with the distro %D%
)
wsl -d %D% -- systemctl is-system-running < nul >nul 2>nul
if not errorlevel 1 set "HAVE_SYS=1"
wsl -d %D% -- docker info < nul >nul 2>nul
if not errorlevel 1 set "HAVE_DOCKER=1"
wsl -d %D% -- docker info < nul 2>nul | findstr /i nvidia >nul
if not errorlevel 1 set "HAVE_NVRUN=1"
wsl -d %D% -- docker compose version < nul >nul 2>nul
if not errorlevel 1 set "HAVE_COMPOSE=1"
nvidia-smi -L < nul 2>nul | findstr /c:"GPU" >nul
if not errorlevel 1 set "HAVE_DRV=1"
if defined HAVE_SYS echo   [ok] 2. systemd in the distro
if not defined HAVE_SYS echo   [NO] 2. systemd in the distro
if defined HAVE_DOCKER echo   [ok] 3. docker in the distro
if not defined HAVE_DOCKER echo   [NO] 3. docker in the distro
if defined HAVE_NVRUN echo   [ok] 4. nvidia runtime for docker
if not defined HAVE_NVRUN echo   [NO] 4. nvidia runtime for docker
if defined HAVE_COMPOSE echo   [ok] 5. compose plugin for docker
if not defined HAVE_COMPOSE echo   [NO] 5. compose plugin for docker
if defined HAVE_DRV echo   [ok] 6. Windows NVIDIA driver
if not defined HAVE_DRV echo   [NO] 6. Windows NVIDIA driver
if defined HAVE_DRV (
    echo   [--] 7. GPU layout - the tiers run cards 0,1 by default
    echo        repoint the pair via the DEVICE_PAIR step below
    nvidia-smi -L < nul
) else (
    echo   [NO] 7. GPU layout - nvidia-smi missing, nothing to show
)
if defined HAVE_DISTRO (
    echo   [--] 8. disk in the distro - the built image wants ~40 GB, and
    echo        the disk tier's first boot writes a further 48.5 GiB PLE
    echo        table here. To stay on the RAM tier instead, blank
    echo        VLLM_PLE_DISK_OFFLOAD_DIR in the machine .env:
    wsl -d %D% -- df -h / < nul 2>nul
) else (
    echo   [--] 8. disk in the distro - not checked, no distro yet
)
echo   [--] 9. weights - stage 4 verifies the folders and stops with the
echo        documented source if one is missing
echo.
echo  [y] continue into stages 1-5   [f] print fixes for every NO line
set /p GO="  [a] abort - enter = continue: "
if /i "!GO:~0,1!"=="f" goto :fixes
if /i "!GO:~0,1!"=="a" goto :abort
goto :stages
:stages
rem ---- the device pair: the tickbox-style picker (pick two cards) ----
set "PAIR_STAND="
for /f "delims=" %%A in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%MGET%" "%~dp0mtp.env" DEVICE_PAIR 2^>nul') do set "PAIR_STAND=%%A"
echo.
echo  device pair - the two cards every tier runs on - tensor-parallel-2
echo  needs both, so the picker takes exactly two picks. Standing pair:
if defined PAIR_STAND (
    echo   %PAIR_STAND%  ^(a re-run keeps it unless you change it^)
) else (
    echo   none set yet - the package default is 0,1
)
set "PAIR_KEEP="
set "PAIR="
call "%REPO%\_shared\scripts\pickpair.bat"
if defined PAIR goto :dev-write
goto :dev-done
:dev-write
for %%T in (mtp nomtp) do powershell -NoProfile -ExecutionPolicy Bypass -File "%MCFG%" "%~dp0%%T.env" DEVICE_PAIR "!PAIR!" >nul
echo   written DEVICE_PAIR=!PAIR! to both tier machine .envs
goto :dev-done
:dev-done
rem ---- the serve bind: the raw address the tier binds to ----
set "BIND_STAND="
for /f "delims=" %%A in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%MGET%" "%~dp0mtp.env" BIND_HOST 2^>nul') do set "BIND_STAND=%%A"
set "SB_VAL="
echo.
echo  serve bind - the raw address the tier binds to when it is up:
echo    0.0.0.0    every interface inside the distro; the LAN reaches it
echo               once firewall.bat has added the inbound rules
echo    127.0.0.1  the loopback only - the package default here (on a
echo                 mirrored-mode WSL the Windows host's own localhost does)
echo    some IP      only that address
if defined BIND_STAND (
    echo   standing bind: %BIND_STAND%  ^(a re-run keeps it unless you change it^)
)
set /p SB="  [enter] keep the bind    [o]pen (0.0.0.0)  [l]ocal (127.0.0.1)  [a] concrete address: "
if /i "!SB:~0,1!"=="o" set "SB_VAL=0.0.0.0"
if /i "!SB:~0,1!"=="l" set "SB_VAL=127.0.0.1"
if /i "!SB:~0,1!"=="a" goto :bind-addr
if defined SB_VAL goto :bind-write
goto :bind-done
:bind-addr
set "ADDR="
set /p ADDR="  address (enter = 0.0.0.0): "
if defined ADDR (
    set "SB_VAL=!ADDR!"
    goto :bind-write
)
echo   no address given - the standing bind is kept; nothing was written
goto :bind-done
:bind-write
powershell -NoProfile -ExecutionPolicy Bypass -File "%MCFG%" "%~dp0mtp.env" BIND_HOST "!SB_VAL!" >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%MCFG%" "%~dp0nomtp.env" BIND_HOST "!SB_VAL!" >nul
echo   written BIND_HOST=!SB_VAL! to both tier machine .envs
:bind-done
rem ---- the firewall: the inbound rules for the tier ports live in     ----
rem ---- firewall.bat in this folder - the one step that needs admin    ----
rem ---- rights; it asks for its own, and the tier boots either way      ----
echo.
echo  windows firewall - run firewall.bat in this folder to add the
echo  inbound rules for the tier ports; it asks for its own admin rights.
echo  The tier boots either way - until the rules are in, the LAN simply
echo  cannot reach it.
rem ---- the weights path: where stage 4 verifies + fetches missing folders ----
set "WD_STAND="
for /f "delims=" %%A in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%MGET%" "%~dp0mtp.env" WEIGHTS_DIR 2^>nul') do set "WD_STAND=%%A"
set "WD_VAL="
echo.
echo  weights download path - stage 4 verifies the weight folders here and,
echo  if a model ships a fetch script, downloads any missing folder - this
echo  model's checkpoint is ~121 GiB, so plan the Windows-side disk:
if defined WD_STAND (
    echo   standing path: %WD_STAND%  ^(a re-run keeps it unless you change it^)
) else (
    echo   no path set yet - stage 4 falls back to the model's own weights folder
)
set /p WD="  [enter] keep the path    [c] change the download path: "
if /i "!WD:~0,1!"=="c" goto :wd-choose
goto :wd-done
:wd-choose
set /p WDPATH="  path (as seen from WSL, e.g. /home/<user>/models or /mnt/d/models): "
if defined WDPATH (
    set "WD_VAL=!WDPATH!"
    goto :wd-write
)
echo   no path given - the standing path is kept; nothing was written
goto :wd-done
:wd-write
powershell -NoProfile -ExecutionPolicy Bypass -File "%MCFG%" "%~dp0mtp.env" WEIGHTS_DIR "!WD_VAL!" >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%MCFG%" "%~dp0nomtp.env" WEIGHTS_DIR "!WD_VAL!" >nul
echo   written WEIGHTS_DIR=!WD_VAL! to both tier machine .envs
:wd-done
rem ---- stage 0: the WSL distro must exist (backstop) ----
wsl -d %D% -- echo PING < nul >nul 2>nul
if errorlevel 1 (
    echo  FATAL: the distro is the one non-optional prereq; its fix is
    echo  line 1 above. Fix it, then re-run this.
    pause
    exit /b 1
)

rem ---- stage 0b: docker + the nvidia runtime + the compose plugin, root ----
rem ---- (wsl -u root: no password, no Windows admin; idempotent) ----
set "NEEDS_ENV=1"
wsl -d %D% -- docker info < nul >nul 2>nul
if not errorlevel 1 (
    wsl -d %D% -- docker info < nul 2>nul | findstr /i nvidia >nul
    if not errorlevel 1 (
        wsl -d %D% -- docker compose version < nul >nul 2>nul
        if not errorlevel 1 set "NEEDS_ENV="
    )
)
if defined NEEDS_ENV (
    echo.
    echo  env setup: docker, the nvidia runtime, and/or the compose plugin are missing in %D%.
    echo  The install runs through the distro's root account - wsl -u root
    echo  needs no password and no Windows admin rights; a few minutes.
    set "WSLUSER="
    for /f %%U in ('wsl -d %D% -- id -un ^< nul 2^>nul') do set "WSLUSER=%%U"
    wsl -d %D% -u root -- bash "%REPO_WSL%/_shared/scripts/env-setup.sh" "!WSLUSER!"
    if errorlevel 1 (
        echo  the env setup stopped; the lines above name the manual fix.
        echo  Sort it out and re-run this wizard - every step is idempotent.
        pause
        exit /b 1
    )
    wsl -d %D% -u root -- docker info < nul 2>nul | findstr /i nvidia >nul
    if errorlevel 1 (
        echo  the nvidia runtime is still missing after the env setup; the
        echo  lines above carry the manual checklist.
        pause
        exit /b 1
    )
    echo  docker, the nvidia runtime, and the compose plugin are in place; on to the stages.
)
echo.
rem ---- the locked image: this model does not run a stock vllm image. ----
rem ---- The community stack's build is in vllm\Dockerfile; the vendor  ----
rem ---- base pulls on the first run, the build itself takes minutes.   ----
rem ---- A re-install finds the image present and skips the build.      ----
wsl -d %D% -- docker image inspect qwen38-flash-next-2x3090:locked < nul >nul 2>nul
if errorlevel 1 (
    echo  stage 0c: the locked image qwen38-flash-next-2x3090:locked is missing.
    echo  building it from vllm\Dockerfile - the vendor base pulls first, a
    echo  multi-GB pull plus a short build. One wsl call, no inline logic.
    wsl -d %D% -- docker build -t qwen38-flash-next-2x3090:locked %REPO_WSL%/qwen3.8-flash-next/vllm
    if errorlevel 1 (
        echo  the image build failed - the lines above name the step.
        echo  Sort it out and re-run this wizard; every step is idempotent.
        pause
        exit /b 1
    )
)
echo.
wsl -d %D% -- bash %REPO_WSL%/_shared/scripts/install-core.sh %MODEL% < nul
echo.
echo install exit code %ERRORLEVEL% - 0 = the model is ready to boot;
echo  anything else ends with the exact step that needs your hands.
pause
exit /b %ERRORLEVEL%

rem ============================================================
:fixes
echo.
echo  fixes for the NO lines:
if not defined HAVE_DISTRO (
    echo   1. wsl --install -d %D%
    echo      if wsl itself is missing: Settings, Apps, Optional features,
    echo      add Windows Subsystem for Linux, then the install line above
    echo      then enable systemd: create C:\Users\%USERNAME%\.wslconfig
    echo      with the two lines [wsl2] and systemd=true
    echo      then: wsl --shutdown, and re-run this install
)
if defined HAVE_DISTRO (
    if not defined HAVE_SYS (
        echo   2. create C:\Users\%USERNAME%\.wslconfig with the two lines
        echo      [wsl2] and systemd=true; then wsl --shutdown; re-run
    )
    if not defined HAVE_DOCKER (
        echo   3. the wizard installs docker itself via the distro's root
        echo      account - wsl -u root needs no password or admin. Only if
        echo      that path failed on your box:
        echo      sudo apt update
        echo      sudo apt install -y docker.io
        echo      sudo systemctl enable --now docker
    )
    if not defined HAVE_NVRUN (
        echo   4. the wizard installs the nvidia runtime the same way - the
        echo      NVIDIA WSL repo plus nvidia-container-toolkit. Only if
        echo      that path failed on your box:
        echo      sudo apt install -y nvidia-container-toolkit
        echo      sudo nvidia-ctk runtime configure --runtime=docker
        echo      sudo systemctl restart docker
    )
    if not defined HAVE_COMPOSE (
        echo   5. the wizard installs the compose plugin the same way -
        echo      docker-compose-v2 from the distro's repos. Only if that
        echo      path failed on your box:
        echo      sudo apt update
        echo      sudo apt install -y docker-compose-v2
    )
)
if not defined HAVE_DRV (
    echo   6. update the Windows NVIDIA driver from nvidia.com; WSL2 runs
    echo      the Windows driver, the distro side is automatic
)
echo   7. no install-side fix: if 0,1 is not your serving pair, set
echo      DEVICE_PAIR in the device-pair step on the next run
echo   8. free disk space inside the distro if the line above is thin
echo   9. no install-side fix: stage 4 stops with the source and the
echo      exact command when a weights folder is missing
echo.
pause
exit /b 1

rem ============================================================
:abort
echo.
echo  aborted before any stage ran; nothing on the box was changed.
pause
exit /b 1
