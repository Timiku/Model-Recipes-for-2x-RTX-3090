# reporoot.ps1 - the repo root as two assignments, derived from this
# script's own location (the shared scripts live at <repo>/_shared/scripts/,
# so the root is two levels up; no machine-specific path anywhere):
#
#   REPO=<the Windows path, normalized>
#   REPO_WSL=<the WSL2 form of it: /mnt/<drive>/<path with forward slashes>.
#            Only the drive letter is lowercased: /mnt/<drive> mount points
#            are lowercase, and the path itself stays as-is (the 9p mount
#            is case-sensitive).
#
# Called by the model-level bats (each sits at <repo>/<model>/vllm/), which
# need nothing but the ps1's location:
#
param([string]$From)

# The script's own directory, however this call arrived: an explicit
# argument (the test path), $PSScriptRoot (-File), or the invocation path.
$dir = $From
if (-not $dir) { $dir = $PSScriptRoot }
if (-not $dir) { $dir = Split-Path $MyInvocation.MyCommand.Path -Parent }
if (-not $dir) { throw 'reporoot.ps1: cannot determine its own location' }

$root = (Get-Item (Join-Path $dir '..\..')).FullName
Write-Output ('REPO=' + $root)
$drive = $root.Substring(0, 1).ToLower()
$rest  = $root.Substring(2) -replace '\\','/'
Write-Output ('REPO_WSL=/mnt/' + $drive + $rest)
