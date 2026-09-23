# model-recipes-watchdog -- the shared (model-agnostic) watchdog body.
#
# Why this exists: closing the start-*.bat window kills the Windows-side
# wsl.exe process, but WSL2 would otherwise keep the docker container running
# inside the distro, holding both GPUs. This watchdog (detached, own window)
# waits for the marker wsl.exe to disappear, then terminates the distro.
#
# It only reacts to wsl.exe whose command line contains the Marker argument
# (the bat passes the exact `serve.sh <model> <tier>` string of its own
# session, so two models' watchdogs never cross-fire).
#
# Side effect, by design: terminating the distro kills everything else running
# in that Ubuntu too (single-purpose box).
#
# The window is VISIBLE, on purpose: it opens in normal (never minimized)
# state and prints its armed banner. It prints one more line when it first
# sees the serve process (nobody should be left guessing), then stays silent
# while it waits - the window's presence IS the status; it prints again only
# to report the action it took, and holds that report open for you to read.
#
# NOTE: this file is deliberately pure ASCII. Windows PowerShell 5.1 reads a
# BOM-less file as the local code page, and a UTF-8 curly quote decoded as a
# CP1252 quote character silently breaks string state.
#
# Arming:  start "model-recipes watchdog - <yml>" powershell -NoProfile
#          -ExecutionPolicy Bypass -File <this file> "<marker>" <distro>
# Killing:  stop.bat kills every process whose command line matches
#          '*model-recipes-watchdog*' (this file's name is the marker).

param(
    [Parameter(Position=0, Mandatory=$true)][string]$Marker,
    [Parameter(Position=1)][string]$Distro = 'Ubuntu'
)

$ErrorActionPreference = 'SilentlyContinue'

# ---- never open minimized/hidden, whatever Windows decided to remember ----
try {
    Add-Type -Namespace Win32 -Name ConsoleFix -MemberDefinition @'
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
'@
    [Win32.ConsoleFix]::ShowWindow([Win32.ConsoleFix]::GetConsoleWindow(), 9) | Out-Null  # SW_SHOWNORMAL
} catch { }

Write-Host "=============================================================="
Write-Host " model-recipes watchdog -- ARMED"
Write-Host " watching:   wsl.exe  *$Marker*"
Write-Host " action:     two consecutive misses (3 s apart) then"
Write-Host "               wsl --terminate $Distro"
Write-Host " stopping:   close the serve window, or run stop.bat"
Write-Host " it prints once more when it has the serve process in view,"
Write-Host " then stays silent - the window's presence is the status."
Write-Host "=============================================================="
Write-Host "[$([datetime]::Now -f 'HH:mm:ss')] grace period: 10 s while the bat arms the serve call..."
Start-Sleep -Seconds 10

function Test-Alive {
    $w = Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" |
         Where-Object { $_.CommandLine -like "*$Marker*" }
    return [bool]$w
}

$miss = 0
$seen = $false
while ($true) {
    if (Test-Alive) {
        $miss = 0
        if (-not $seen) {
            $seen = $true
            Write-Host "[$([datetime]::Now -f 'HH:mm:ss')] serve process confirmed alive - watching; silent from here until it stops."
        }
    } else {
        $miss++
        if (-not $seen -and $miss -eq 1) {
            Write-Host "[$([datetime]::Now -f 'HH:mm:ss')] serve process not seen yet (one more miss and I act)..."
        }
    }
    if ($miss -ge 2) {
        Write-Host "--------------------------------------------------------------"
        if ($seen) {
            Write-Host "[$([datetime]::Now -f 'HH:mm:ss')] serve process confirmed gone -- terminating distro $Distro ..."
        } else {
            Write-Host "[$([datetime]::Now -f 'HH:mm:ss')] serve process never appeared (boot stopped short of the wsl call?) -- terminating distro $Distro ..."
        }
        wsl --terminate $Distro
        Write-Host " done: $Distro terminated. The GPUs are free."
        Write-Host "--------------------------------------------------------------"
        Write-Host " (this window stays open for the report; press Enter to close)"
        $null = Read-Host
        exit 0
    }
    Start-Sleep -Seconds 3
}
