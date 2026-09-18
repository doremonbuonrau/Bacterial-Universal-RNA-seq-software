[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$preferenceFile = Join-Path $PSScriptRoot ".opdetect_wsl_distro"

function Get-CleanWslOutput {
    param([object[]]$Lines)
    return @($Lines | ForEach-Object {
        ([string]$_).Replace(([char]0).ToString(), [string]::Empty).Trim()
    } | Where-Object { $_ })
}

$installed = @(Get-CleanWslOutput (& wsl.exe --list --quiet 2>$null))
$distro = $null
if (Test-Path -LiteralPath $preferenceFile) {
    $saved = (Get-Content -LiteralPath $preferenceFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($saved -and $installed -contains $saved) { $distro = $saved }
}
if (-not $distro) {
    foreach ($candidate in @('OpDetect-Ubuntu', 'Ubuntu-24.04', 'Ubuntu', 'Debian')) {
        if ($installed -contains $candidate) { $distro = $candidate; break }
    }
}
if (-not $distro) {
    $distro = $installed | Where-Object { $_ -match '(?i)ubuntu|debian' } | Select-Object -First 1
}
if (-not $distro) {
    throw "No compatible Ubuntu or Debian WSL distribution was found. Open OpDetect.exe and choose Install or repair."
}

Write-Host "Opening $distro as Linux root..."
& wsl.exe -d $distro -u root -- bash -lc 'cd /root/opdetect_pipeline 2>/dev/null || cd /root; exec bash'
