# Shared by the Open interactive report action. No analysis environment needed.
function Update-BraPlotReports {
    param(
        [Parameter(Mandatory=$true)][string]$ResultDirectory,
        [Parameter(Mandatory=$true)][string]$RuntimeSource
    )
    $source = [System.IO.File]::ReadAllText($RuntimeSource)
    # Read the canonical raw JS literal used by write_plot; never execute Python
    # or parse/recalculate the saved figure data during this upgrade.
    $runtimeMatch = [regex]::Match($source, '(?s)selection_script = r"""(<script>.*?</script>)"""')
    if (-not $runtimeMatch.Success) { throw 'The plot renderer is missing from this installation. Re-extract the complete v28 package.' }
    $runtime = $runtimeMatch.Groups[1].Value
    $version = [regex]::Match($runtime, 'BRA_SELECTION_RUNTIME_VERSION: \d+').Value
    if (-not $version) { throw 'The installed plot renderer has no version identifier.' }
    $pattern = '(?s)<script(?:\s[^>]*)?>\s*(?:// BRA_SELECTION_RUNTIME_VERSION: \d+\s*)?\(\(\)=>\{\s*const graph=\(\)=>document\.querySelector\(''\.plotly-graph-div''\);.*?</script>'
    $count = 0
    foreach ($plot in Get-ChildItem -LiteralPath $ResultDirectory -Recurse -File -Filter '*interactive.html') {
        $html = [System.IO.File]::ReadAllText($plot.FullName)
        if ($html.Contains($version)) { continue }
        $match = [regex]::Match($html, $pattern)
        if (-not $match.Success) { continue }
        $updated = $html.Remove($match.Index, $match.Length).Insert($match.Index, $runtime)
        $temporary = $plot.FullName + '.updating-' + [Guid]::NewGuid().ToString('N')
        $backup = $plot.FullName + '.pre-v28.bak'
        try {
            [System.IO.File]::WriteAllText($temporary, $updated, (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::Replace($temporary, $plot.FullName, $(if ([System.IO.File]::Exists($backup)) {$null} else {$backup}))
            $count++
        } finally {
            if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
        }
    }
    return $count
}
