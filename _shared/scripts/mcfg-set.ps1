# mcfg-set.ps1 - set keys in a machine .env file.
#
# The two-tier wizard's write primitive, in PowerShell so a stock Windows box
# (Windows PowerShell 5.1) can run it with no Python dependency. For each
# "KEY VALUE" argument, if a KEY= line exists its value is rewritten in place;
# a not-yet-present key is appended at the end; a missing file is created.
# The rest of the file (every other key, the comment header) is left intact -
# this is a line editor, not a round-trip.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File mcfg-set.ps1 <env> KEY VALUE [KEY VALUE ...]
#
# Value quoting (the same rule the seeded .envs use, so a re-set key and a
# hand-authored one render the same): a bare alnum/dot/dash/slash/colon value
# is written bare; an empty value is written bare-empty (KEY=); anything else
# with no quote/backslash/dollar/backtick is double-quoted; anything with one
# of those is single-quoted (bash idiom; an embedded ' uses the close-reopen
# '...'\'...' idiom - note a single-quoted value's ' is not compose-clean, so
# avoid quoting quote characters in values).

param(
    [Parameter(Mandatory)] [string] $File,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Rest
)

$ErrorActionPreference = 'Stop'

if ($Rest.Count -lt 2 -or ($Rest.Count % 2) -ne 0) {
    Write-Error "usage: mcfg-set.ps1 <machine.env> KEY VALUE [KEY VALUE ...]"
    exit 2
}
$pairs = @()
for ($i = 0; $i -lt $Rest.Count; $i += 2) { $pairs += , @($Rest[$i], $Rest[$i + 1]) }

function Format-EnvValue([string]$v) {
    if ($v -eq '') { return '' }
    if ($v -match '^[A-Za-z0-9._:/-]+$') { return $v }
    foreach ($c in $v.ToCharArray()) {
        if ($c -eq "'" -or $c -eq '"' -or $c -eq '\' -or $c -eq '$' -or $c -eq '`') {
            return "'" + $v.Replace("'", "'\\''") + "'"
        }
    }
    return '"' + $v + '"'
}

$lines = @()
if (Test-Path $File) { $lines = [System.IO.File]::ReadAllLines($File) }
$out = New-Object System.Collections.Generic.List[string]
$done = @{}
foreach ($line in $lines) {
    $t = $line.Trim()
    $replaced = $false
    if ($t -ne '' -and -not $t.StartsWith('#')) {
        $i = $t.IndexOf('=')
        if ($i -ge 1) {
            $k = $t.Substring(0, $i).Trim()
            foreach ($p in $pairs) {
                if ($p[0] -eq $k -and -not $done.ContainsKey($p[0])) {
                    $out.Add(($p[0] + '=') + (Format-EnvValue $p[1]))
                    $done[$p[0]] = $true
                    $replaced = $true
                    break
                }
            }
        }
    }
    if (-not $replaced) { $out.Add($line) }
}
foreach ($p in $pairs) {
    if (-not $done.ContainsKey($p[0])) {
        $out.Add(($p[0] + '=') + (Format-EnvValue $p[1]))
    }
}
# LF endings, not platform default: this file is sourced by bash on the WSL
# side (set -a; . file) and compose interpolates from it. CRLF would put a
# literal \r into every value (BIND_HOST='0.0.0.0\r' -> 'invalid IP address').
[System.IO.File]::WriteAllLines($File, $out, (New-Object System.Text.UTF8Encoding($false)))
$lf = [IO.File]::ReadAllText($File) -replace "\r\n", "\n"
[IO.File]::WriteAllText($File, $lf, (New-Object System.Text.UTF8Encoding($false)))
exit 0
