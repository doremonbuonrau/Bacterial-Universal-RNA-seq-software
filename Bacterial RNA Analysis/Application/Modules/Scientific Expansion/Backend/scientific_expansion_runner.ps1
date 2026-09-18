param(
    [Parameter(Mandatory = $true)]
    [string]$RequestPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $OutputEncoding

function Convert-ToWslPath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if ($Value -match '^([A-Za-z]):[\\/](.*)$') {
        $drive = $matches[1].ToLowerInvariant()
        $rest = $matches[2].Replace('\','/')
        return "/mnt/$drive/$rest"
    }
    if ($Value -match '^\\\\wsl(?:\.localhost|\$)?\\[^\\]+\\(.*)$') {
        return '/' + $matches[1].Replace('\','/')
    }
    return $Value.Replace('\','/')
}

function Get-DefaultDistro([string]$SuiteRoot) {
    $runtime = Join-Path $SuiteRoot 'Modules\Shared Runtime\wsl_runtime.ps1'
    if (Test-Path -LiteralPath $runtime -PathType Leaf) {
        try {
            . $runtime
            $resolved = Resolve-BraWslDistro -SuiteRoot $SuiteRoot -Purpose Core
            if ($resolved) { return $resolved }
        } catch { }
    }
    if ($env:BACTERIAL_RNA_WSL_DISTRO) { return [string]$env:BACTERIAL_RNA_WSL_DISTRO }
    throw 'No WSL2 Linux distribution could be resolved by the shared runtime.'
}

$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$backendWindows = [string]$request.backend
$backendDir = Split-Path -Parent $backendWindows
$suiteRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $backendDir))
$distro = [string]$request.distro
if ([string]::IsNullOrWhiteSpace($distro)) { $distro = Get-DefaultDistro $suiteRoot }
if (Test-Path -LiteralPath (Join-Path $suiteRoot 'Modules\Shared Runtime\wsl_runtime.ps1') -PathType Leaf) {
    try {
        . (Join-Path $suiteRoot 'Modules\Shared Runtime\wsl_runtime.ps1')
        Save-BraWslDistroSelection -SuiteRoot $suiteRoot -Distro $distro
    } catch { }
}
if (-not (Test-Path -LiteralPath $backendWindows -PathType Leaf)) { throw "Scientific expansion backend not found: $backendWindows" }
$backend = Convert-ToWslPath $backendWindows
$supervisor = Convert-ToWslPath (Join-Path $backendDir 'science_job.py')
$cancelPath = Convert-ToWslPath ([string]$request.cancel_path)

$arguments = New-Object System.Collections.Generic.List[string]
foreach ($arg in @($request.arguments)) {
    $value = [string]$arg
    if ($value -match '^[A-Za-z]:[\\/]') { $value = Convert-ToWslPath $value }
    [void]$arguments.Add($value)
}

# Invoke WSL with an argument array rather than building a bash command string.
# This is both safer for paths containing spaces/apostrophes and fully compatible
# with Windows PowerShell 5.1. It also eliminates the quote parser failure that
# previously surfaced as scientific_expansion_runner.ps1:36 in STRING, Pathway,
# Transcript Discovery and TU Architecture environment checks.
$conda = '/root/.local/share/prok-rnaseq/miniforge3/bin/conda'
$wslArgs = New-Object System.Collections.Generic.List[string]
foreach ($token in @('-d', $distro, '-u', 'root', '--', $conda, 'run', '--no-capture-output', '-n', 'prok-rnaseq', 'python', '-u', $supervisor, $backend, $cancelPath)) {
    [void]$wslArgs.Add([string]$token)
}
foreach ($arg in $arguments) { [void]$wslArgs.Add([string]$arg) }

# Windows PowerShell 5.1 can promote native stderr to an ErrorRecord when
# $ErrorActionPreference is Stop. WSL may emit a harmless localhost-proxy warning
# on stderr, so capture native output and judge success only by the process exit code.
$invokeArgs = [string[]]$wslArgs
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & wsl.exe @invokeArgs 2>&1 | ForEach-Object { [Console]::Out.WriteLine([string]$_) }
    $exit = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
exit $exit
