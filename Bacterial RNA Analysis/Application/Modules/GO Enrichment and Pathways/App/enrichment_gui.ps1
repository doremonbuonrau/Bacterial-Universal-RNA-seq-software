# Standalone Functional Enrichment and Co-expression Networks application
$global:BacterialRNAAnalysisDownstreamModule = 'enrichment'
$startupLog = [string]$env:BRA_STARTUP_LOG
$embeddedLaunch = $false
try {
    $embeddedLaunch = $null -ne (Get-Variable -Name BacterialRNAAnalysisEmbeddedHost -Scope Global -ValueOnly -ErrorAction Stop)
} catch { }
try {
    $modulesRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $sharedGui = Join-Path $modulesRoot 'Shared Downstream Components\App\downstream_gui.ps1'
    if (-not (Test-Path -LiteralPath $sharedGui -PathType Leaf)) { throw "Shared analysis components were not found: $sharedGui" }
    & $sharedGui
}
catch {
    $details = @(
        "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] Functional Enrichment and Co-expression Networks application failed to start"
        $_.Exception.ToString()
        ($_ | Out-String)
        ($_.ScriptStackTrace | Out-String)
    ) -join "`r`n"
    if ($startupLog) {
        try {
            $encoding = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($startupLog, $details, $encoding)
        } catch { }
    }
    if ($embeddedLaunch) { throw }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [void][System.Windows.Forms.MessageBox]::Show(
            "The application could not start.`r`n`r`n$($_.Exception.Message)`r`n`r`nStartup log:`r`n$startupLog",
            'Functional Enrichment and Co-expression Networks',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    } catch { }
    exit 1
}
finally {
    Remove-Variable -Name BacterialRNAAnalysisDownstreamModule -Scope Global -ErrorAction SilentlyContinue
}
