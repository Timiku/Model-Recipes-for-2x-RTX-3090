@echo off
setlocal EnableExtensions EnableDelayedExpansion
title model-recipes firewall - qwen3.8-27b
rem ---- the Windows firewall rules for this model's tier ports.          ----
rem ---- The install wizard runs without admin rights; this is the one   ----
rem ---- step that needs them, so it lives in its own bat: non-elevated,  ----
rem ---- it re-launches itself through a UAC prompt. A declined prompt    ----
rem ---- changes nothing on the box. Idempotent - a rule that is already  ----
rem ---- in place is reported, not re-added.                              ----
rem ---- adds carry profile=any: an unscoped rule goes silent when the   ----
rem ---- box's network profile rotates - this box's original rules did.  ----
rem ---- the port list is the shipped tiers: 8113 mtp/nomtp/swift, ----
rem ---- 8116 kvarntier/kvarnmtp, 8117 kvarndflash2.               ----
set "MODEL=qwen3.8-27b"
set "PORTS=8113 8116 8117"
rem ---- elevation: one powershell line; non-elevated, it re-launches     ----
rem ---- this same bat elevated (exit 42 marks the handoff)               ----
powershell -NoProfile -ExecutionPolicy Bypass -Command "if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){ Start-Process -FilePath '%~f0' -Verb RunAs; exit 42 }"
if errorlevel 1 goto :not-elevated
echo.
echo  windows firewall - the inbound rules for this model's tier ports:
set "FW_OK=1"
for %%P in (%PORTS%) do call :ensure %%P
echo.
if not defined FW_OK (
    echo  the adds were refused - run this bat from an admin window, or
    echo  add the rules by hand:
    for %%P in (%PORTS%) do call :print %%P
)
pause
exit /b 0

:ensure
set "FW_EXISTS="
for /f "delims=" %%O in ('netsh advfirewall firewall show rule name="model-recipes %MODEL% %1" 2^>nul ^| findstr /i "Rule Name:"') do set "FW_EXISTS=1"
if defined FW_EXISTS (
    echo    [ok] %1 - the rule is already in place
    exit /b 0
)
netsh advfirewall firewall add rule name="model-recipes %MODEL% %1" dir=in action=allow protocol=TCP localport=%1 profile=any >nul 2>nul
if errorlevel 1 (
    set "FW_OK="
    echo    [--] %1 - the add was refused
) else (
    echo    [ok] %1 - added
)
exit /b 0

:print
echo    netsh advfirewall firewall add rule name="model-recipes %MODEL% %1" dir=in action=allow protocol=TCP localport=%1 profile=any
exit /b 0

:not-elevated
echo.
echo  this step needs admin rights - a UAC prompt was offered when this
echo  window opened.
echo    accept   - the elevated window adds the rules, then closes itself
echo    decline  - nothing is changed; to add the rules by hand, run
echo               these from any admin window:
for %%P in (%PORTS%) do call :print %%P
pause
exit /b 0
