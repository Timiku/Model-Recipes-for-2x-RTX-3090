# mcfg-get.ps1 - read one key's value from a machine .env file.
#
# The two-tier wizard's read primitive (the mirror of mcfg-set.ps1). Prints the
# key's value (quotes stripped) if the key is present, or nothing if it is not -
# so a machine .env with no live value for a knob reads as unset and the wizard
# falls back to the package default.
#
# The file is plain docker compose .env format: KEY=value lines, full-line
# comments, single or double quoted values (the seeded .envs quote nothing
# exotic; a value with spaces or backslashes is single-quoted).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File mcfg-get.ps1 <env> KEY [KEY ...]

param(
    [Parameter(Mandatory)] [string] $File,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Rest
)

if (-not (Test-Path $File)) { exit 1 }
$want = New-Object System.Collections.Generic.HashSet[string]
foreach ($k in $Rest) { [void]$want.Add($k) }

$found = @{}
foreach ($line in [System.IO.File]::ReadAllLines($File)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -lt 1) { continue }
    $k = $t.Substring(0, $i).Trim()
    if (-not $want.Contains($k)) { continue }
    if ($found.ContainsKey($k)) { continue }
    $v = $t.Substring($i + 1).Trim()
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[$v.Length - 1] -eq '"') -or ($v[0] -eq "'" -and $v[$v.Length - 1] -eq "'"))) {
        $v = $v.Substring(1, $v.Length - 2)
    }
    $found[$k] = $v
}
foreach ($k in $Rest) {
    if ($found.ContainsKey($k)) { Write-Output $found[$k] }
}
exit 0
