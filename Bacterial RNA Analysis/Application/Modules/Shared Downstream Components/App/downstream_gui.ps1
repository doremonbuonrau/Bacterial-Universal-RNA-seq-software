# Shared WinForms implementation for three standalone bacterial analysis applications
# Differential Expression, GO Enrichment and Pathways, and Co-expression and Networks

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ModuleRoot = Split-Path -Parent $script:AppDir
$script:Runner = Join-Path $script:AppDir 'run_downstream.sh'
$script:SetupScript = Join-Path $script:AppDir 'setup_downstream.sh'
$script:CheckScript = Join-Path $script:AppDir 'check_downstream.sh'
$script:SupervisorScript = Join-Path $script:AppDir 'run_supervised_job.sh'
$script:StopSupervisorScript = Join-Path $script:AppDir 'stop_supervised_job.sh'
$script:VisualizationStudioScript = Join-Path (Join-Path $script:ModuleRoot 'Python') 'visualization_studio.py'
$script:ManualWorkbookScript = Join-Path (Join-Path $script:ModuleRoot 'Python') 'manual_input_workbook.py'
$script:VisualizationStudioLauncher = Join-Path $script:AppDir 'launch_visualization_studio.sh'
$script:StudioProcesses = New-Object System.Collections.ArrayList
$script:JobProcess = $null
$script:JobTimer = $null
$script:JobLogPath = ''
$script:JobLogLength = 0
$script:JobWrapperPath = ''
$script:JobToken = ''
$script:JobDistro = ''
$script:JobLinuxPidFile = ''
$script:JobStopRequested = $false
$script:JobMode = ''
$script:JobOutput = ''
$script:LastDEOutput = ''
$script:LastEnrichmentOutput = ''
$script:LastNetworkOutput = ''
$script:LastFunctionalOutput = ''
$script:AdvancedPackageOptions = @{}
$script:EmbeddedHost = $null
try { $script:EmbeddedHost = Get-Variable -Name BacterialRNAAnalysisEmbeddedHost -Scope Global -ValueOnly -ErrorAction Stop } catch { }
$script:EmbeddedMode = $null -ne $script:EmbeddedHost
$script:AutoLoadLatestRnaSeq = $false
try { $script:AutoLoadLatestRnaSeq = [bool](Get-Variable -Name BacterialRNAAnalysisAutoLoadLatestRnaSeq -Scope Global -ValueOnly -ErrorAction Stop) } catch { }
$script:SuiteRequestedClose = $false
$script:SuiteLifecycleTimer = $null
$script:SuiteShutdownSignal = [string]$env:BRA_SHUTDOWN_SIGNAL
$script:SuiteReadySignal = [string]$env:BRA_READY_SIGNAL
$script:SuiteParentPid = 0
if ($env:BRA_PARENT_PID -match '^\d+$') { $script:SuiteParentPid = [int]$env:BRA_PARENT_PID }
$script:InitialTab = 'de'
try {
    $requested = Get-Variable -Name BacterialRNAAnalysisDownstreamModule -Scope Global -ValueOnly -ErrorAction Stop
    if ([string]$requested -in @('de', 'enrichment', 'network')) { $script:InitialTab = [string]$requested }
} catch {
    try {
        $requested = Get-Variable -Name BacterialRNAAnalysisDownstreamTab -Scope Global -ValueOnly -ErrorAction Stop
        if ([string]$requested -in @('de', 'enrichment', 'network')) { $script:InitialTab = [string]$requested }
    } catch { }
}
# Co-expression now lives inside the functional-analysis workspace.  Legacy
# network launchers open the combined page instead of a separate duplicate GUI.
if ($script:InitialTab -eq 'network') { $script:InitialTab = 'enrichment' }
$script:SingleModuleMode = $true
$script:ModulesRoot = Split-Path -Parent $script:ModuleRoot
$script:ApplicationRoot = Split-Path -Parent $script:ModulesRoot
$script:PersistentLogDir = Join-Path $script:ApplicationRoot 'Logs'
$script:SharedStateDir = Join-Path $script:ModulesRoot 'Shared Analysis State'
$script:ExamplesDir = Join-Path $script:ModuleRoot 'Examples'
$script:ManualWorkbookExamplesDir = Join-Path $script:ExamplesDir 'Manual input workbooks'
foreach ($folder in @($script:PersistentLogDir, $script:SharedStateDir)) {
    try { [void][System.IO.Directory]::CreateDirectory($folder) } catch { }
}
switch ($script:InitialTab) {
    'enrichment' {
        $script:ModuleDisplayName = 'Functional Enrichment and Co-expression Networks'
        $script:ModuleSubtitle = 'GO/pathway interpretation, automatic co-expression modules, hubs, traits, and regulatory networks in one workspace.'
        $script:InstructionPath = Join-Path $script:ModulesRoot 'GO Enrichment and Pathways\Documentation\Instructions.html'
    }
    'network' {
        $script:ModuleDisplayName = 'Co-expression and Networks'
        $script:ModuleSubtitle = 'Bacterial co-expression modules, candidate hubs, traits, and predicted regulatory edges.'
        $script:InstructionPath = Join-Path $script:ModulesRoot 'Co-expression and Networks\Documentation\Instructions.html'
    }
    default {
        $script:ModuleDisplayName = 'Differential Expression'
        $script:ModuleSubtitle = 'Count-based statistical comparison of replicated bacterial RNA-seq conditions.'
        $script:InstructionPath = Join-Path $script:ModulesRoot 'Differential Expression\Documentation\Instructions.html'
    }
}

# Differential Expression uses a non-destructive, DE-only environment check/repair.
# GO and Network keep the established shared installer unchanged.
if ($script:InitialTab -eq 'de') {
    $script:SetupScript = Join-Path $script:AppDir 'setup_de.sh'
    $script:CheckScript = Join-Path $script:AppDir 'check_de.sh'
}

function Save-SharedAnalysisOutput([string]$Kind, [string]$OutputPath) {
    if (-not $OutputPath) { return }
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $script:SharedStateDir ("last_$Kind`_output.txt")), $OutputPath, $encoding)
    } catch { }
}

function Get-LatestRnaSeqAnalysisReady {
    $pointer = Join-Path $script:SharedStateDir 'last_rnaseq_output.txt'
    if (-not (Test-Path -LiteralPath $pointer -PathType Leaf)) { return '' }
    try {
        $value = (Get-Content -LiteralPath $pointer -Raw).Trim()
        if ($value -and (Test-Path -LiteralPath $value -PathType Container)) { return $value }
    } catch { }
    return ''
}

function Select-LatestRnaSeqCountMatrix([string]$AnalysisReadyPath) {
    $countRoots = @(@(
        (Join-Path $AnalysisReadyPath 'intermediate\Count tables'),
        (Join-Path $AnalysisReadyPath 'intermediate\Counts'),
        (Join-Path $AnalysisReadyPath 'Intermediate files\Count tables'),
        (Join-Path $AnalysisReadyPath 'counts')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    if ($countRoots.Count -eq 0) { return '' }
    $candidates = @($countRoots | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Recurse -File -ErrorAction SilentlyContinue
    } | Where-Object { ($_.Name -replace '_', ' ') -like '* raw counts.tsv' } | Sort-Object FullName -Unique)
    if ($candidates.Count -eq 1) { return $candidates[0].FullName }
    if ($candidates.Count -gt 1) {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Choose the latest RNA-seq raw count matrix'
        $dialog.InitialDirectory = $countRoots[0]
        $dialog.Filter = 'Raw count matrices (*.tsv)|*.tsv|All files (*.*)|*.*'
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
    }
    return ''
}

function Get-ScanCandidateFiles([string]$Root) {
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    try {
        return @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Extension.ToLowerInvariant() -in @('.tsv','.txt','.csv','.gmt','.xlsx')
        })
    } catch { return @() }
}

$script:DEHandoffContainerName = 'Inputs for other modules'
$script:DEHandoffFolderNames = @(
    'GO Enrichment and Pathways Input',
    'Co-expression and Networks Input',
    'Pathway Database Analysis Input',
    'STRING Protein Associations Input'
)

function Resolve-DEHandoffFolder([string]$SelectedRoot, [string]$HandoffName) {
    if ([string]::IsNullOrWhiteSpace($SelectedRoot)) { return '' }
    $root = $SelectedRoot.TrimEnd([char[]]@('\','/'))
    $baseName = [System.IO.Path]::GetFileName($root)
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($baseName -ieq $HandoffName) { [void]$candidates.Add($root) }
    if ($script:DEHandoffFolderNames -contains $baseName) {
        $siblingRoot = Split-Path -Parent $root
        if ($siblingRoot) { [void]$candidates.Add((Join-Path $siblingRoot $HandoffName)) }
    }
    if ($baseName -ieq $script:DEHandoffContainerName) {
        [void]$candidates.Add((Join-Path $root $HandoffName))
    }
    [void]$candidates.Add((Join-Path (Join-Path $root $script:DEHandoffContainerName) $HandoffName))
    # Legacy 1.9.77 analyses placed each handoff directly at the DE root.
    [void]$candidates.Add((Join-Path $root $HandoffName))
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
    }
    return $candidates[0]
}

function Find-ScannedFile {
    param([object[]]$Files, [string[]]$ExactNames = @(), [string[]]$WildcardNames = @())
    foreach ($name in $ExactNames) {
        $match = @($Files | Where-Object { $_.Name -ieq $name } | Sort-Object @{Expression={
            # Prefer files beneath the current compact intermediate folder;
            # when several downstream analyses exist, prefer the newest matching
            # table and then use the full path as a deterministic tie-breaker.
            if ($_.FullName -match '[\\/]intermediate[\\/]') { 0 } else { 1 }
        }}, @{Expression={$_.LastWriteTimeUtc}; Descending=$true}, FullName)
        if ($match.Count) { return $match[0].FullName }
    }
    foreach ($pattern in $WildcardNames) {
        $match = @($Files | Where-Object { $_.Name -like $pattern } | Sort-Object @{Expression={ if ($_.FullName -match '[\\/]intermediate[\\/]') { 0 } else { 1 } }}, @{Expression={$_.LastWriteTimeUtc}; Descending=$true}, FullName)
        if ($match.Count) { return $match[0].FullName }
    }
    return ''
}

function Scan-DownstreamResultFolder([string]$Mode) {
    $description = switch ($Mode) {
        'de' { 'Select the completed RNA Processing Results folder to scan for raw counts, sample metadata, and gene coordinates' }
        'enrichment' { 'Select the Differential Expression or Functional Enrichment results folder to scan for all combined-analysis inputs' }
        'network' { 'Select the Differential Expression or Co-expression results folder to scan for normalized expression and metadata' }
        default { 'Select the analysis results folder to scan' }
    }
    $folder = Select-OutputFolder $description
    if (-not $folder) { return }
    $scanRoot = $folder
    if ($Mode -eq 'enrichment' -and [System.IO.Path]::GetFileName($folder) -in $script:DEHandoffFolderNames) {
        $parentInputRoot = Split-Path -Parent $folder
        if ($parentInputRoot) { $scanRoot = $parentInputRoot }
    }
    # Force collection semantics even when the scan returns exactly one file.
    # PowerShell otherwise unwraps one-item arrays into a scalar FileInfo object.
    $files = @(Get-ScanCandidateFiles $scanRoot)
    if ($files.Count -eq 0) {
        Show-Error "No compatible analysis tables were found under:`r`n$folder"
        return
    }
    # Keep downstream outputs as siblings of the scanned result folder so a
    # compact RNA Processing Results root is not cluttered by later analyses.
    $suggestedOutputRoot = Split-Path -Parent $folder
    $selectedFolderName = [System.IO.Path]::GetFileName($folder)
    if ($selectedFolderName -in $script:DEHandoffFolderNames) {
        $handoffParent = Split-Path -Parent $folder
        $deRoot = if ([System.IO.Path]::GetFileName($handoffParent) -ieq $script:DEHandoffContainerName) { Split-Path -Parent $handoffParent } else { $handoffParent }
        $projectRoot = if ($deRoot) { Split-Path -Parent $deRoot } else { '' }
        if ($projectRoot) { $suggestedOutputRoot = $projectRoot }
    } elseif ($selectedFolderName -ieq $script:DEHandoffContainerName) {
        $deRoot = Split-Path -Parent $folder
        $projectRoot = if ($deRoot) { Split-Path -Parent $deRoot } else { '' }
        if ($projectRoot) { $suggestedOutputRoot = $projectRoot }
    }
    if (-not $suggestedOutputRoot) { $suggestedOutputRoot = $folder }

    switch ($Mode) {
        'de' {
            $counts = Find-ScannedFile $files @('short_featurecounts_raw_counts.tsv','featurecounts_raw_counts.tsv','long_featurecounts_raw_counts.tsv','raw_counts.tsv') @('*raw_counts.tsv','*raw counts.tsv')
            $metadata = Find-ScannedFile $files @('sample_metadata.tsv','sample metadata.tsv','metadata.tsv') @('*sample*metadata*.tsv','*sample*metadata*.csv')
            $coordinates = Find-ScannedFile $files @('gene_coordinates.tsv','gene coordinates.tsv','differential_expression_igv_track_data.tsv','gene_metadata.tsv','gene metadata.tsv','features.saf') @('*gene*coordinates*.tsv','*igv*track*data*.tsv','*gene*metadata*.tsv','features.saf')
            if ($counts) { $deCountText.Text = $counts }
            if ($metadata) { Load-DEMetadataControls $metadata }
            if ($coordinates) { $deAnnotationText.Text = $coordinates }
            if (-not $deOutputText.Text.Trim()) { $deOutputText.Text = $suggestedOutputRoot }
            $missing = @()
            if (-not $counts) { $missing += 'raw integer count matrix' }
            if (-not $metadata) { $missing += 'sample metadata' }
            $message = "RNA Processing folder scanned:`r`n$folder`r`n`r`nCounts: $(if($counts){$counts}else{'NOT FOUND'})`r`nMetadata: $(if($metadata){$metadata}else{'NOT FOUND'})`r`nGene coordinates: $(if($coordinates){$coordinates}else{'not found (optional)'})"
            if ($missing.Count) { $message += "`r`n`r`nPlease provide manually: " + ($missing -join ', ') }
            Show-Message $message 'Differential Expression input scan'
        }
        'enrichment' {
            $goHandoff = Resolve-DEHandoffFolder $folder 'GO Enrichment and Pathways Input'
            $handoffDE = Join-Path $goHandoff 'differential expression.tsv'
            $handoffUniverse = Join-Path $goHandoff 'gene universe.tsv'
            $deResult = if (Test-Path -LiteralPath $handoffDE -PathType Leaf) { $handoffDE } else { Find-ScannedFile $files @('differential_expression.tsv','differential expression.tsv') @('*differential*expression*.tsv') }
            $mapping = Find-ScannedFile $files @('term2gene.tsv','term_to_gene.tsv','gene_to_term.tsv') @('*term2gene*.tsv','*term*gene*.tsv','*gene*term*.tsv','*.gmt')
            $universe = if (Test-Path -LiteralPath $handoffUniverse -PathType Leaf) { $handoffUniverse } else { Find-ScannedFile $files @('gene_universe_used.tsv','tested_gene_universe.tsv','gene universe.tsv') @('*gene*universe*.tsv') }
            $networkHandoff = Resolve-DEHandoffFolder $folder 'Co-expression and Networks Input'
            $handoffExpression = Join-Path $networkHandoff 'normalized counts.tsv'
            $handoffMetadata = Join-Path $networkHandoff 'sample metadata.tsv'
            $expression = if (Test-Path -LiteralPath $handoffExpression -PathType Leaf) { $handoffExpression } else { Find-ScannedFile $files @('normalized_counts.tsv','normalized counts.tsv') @('*normalized*counts*.tsv','*normalized*expression*.tsv') }
            $metadata = if (Test-Path -LiteralPath $handoffMetadata -PathType Leaf) { $handoffMetadata } else { Find-ScannedFile $files @('analysis_metadata.tsv','sample_metadata.tsv','sample metadata.tsv') @('*analysis*metadata*.tsv','*sample*metadata*.tsv') }
            $regulators = Find-ScannedFile $files @('regulators.tsv','regulator_list.tsv') @('*regulator*.tsv')
            if ($deResult) { $enrichResultText.Text = $deResult }
            if ($mapping) { $enrichMappingText.Text = $mapping; if ($enrichOfflineMapping) { $enrichOfflineMapping.Checked = $true } }
            if ($universe) { $enrichUniverseText.Text = $universe }
            if ($expression) { $networkExprText.Text = $expression }
            if ($metadata) {
                $networkMetadataText.Text = $metadata
                $headers = @(Get-TableHeaders $metadata)
                Fill-Combo $networkSampleColumnCombo $headers $(if ($headers.Count) { $headers[0] } else { '' })
            }
            if ($regulators) { $networkRegulatorText.Text = $regulators }
            if (-not $enrichOutputText.Text.Trim()) { $enrichOutputText.Text = $suggestedOutputRoot }
            $message = "DE / functional folder scanned:`r`n$folder`r`n`r`nDifferential-expression result: $(if($deResult){$deResult}else{'NOT FOUND'})`r`nNormalized expression: $(if($expression){$expression}else{'NOT FOUND'})`r`nSample metadata: $(if($metadata){$metadata}else{'NOT FOUND'})`r`nGene-to-term mapping: $(if($mapping){$mapping}else{'not found - online annotation remains selected by default'})`r`nCustom universe: $(if($universe){$universe}else{'not found (optional)'})`r`nRegulator list: $(if($regulators){$regulators}else{'not found (optional; GENIE3 only)'})"
            if (-not $deResult -or -not $expression -or -not $metadata) {
                $message += "`r`n`r`nThe required files that were not found remain available as manual Browse fields in section 1."
            }
            Show-Message $message 'Combined functional-analysis input scan'
        }
        'network' {
            $networkHandoff = Resolve-DEHandoffFolder $folder 'Co-expression and Networks Input'
            $handoffExpression = Join-Path $networkHandoff 'normalized counts.tsv'
            $handoffMetadata = Join-Path $networkHandoff 'sample metadata.tsv'
            $expression = if (Test-Path -LiteralPath $handoffExpression -PathType Leaf) { $handoffExpression } else { Find-ScannedFile $files @('normalized_counts.tsv','normalized counts.tsv') @('*normalized*counts*.tsv','*normalized*expression*.tsv') }
            $metadata = if (Test-Path -LiteralPath $handoffMetadata -PathType Leaf) { $handoffMetadata } else { Find-ScannedFile $files @('analysis_metadata.tsv','sample_metadata.tsv','sample metadata.tsv') @('*analysis*metadata*.tsv','*sample*metadata*.tsv') }
            $regulators = Find-ScannedFile $files @('regulators.tsv','regulator_list.tsv') @('*regulator*.tsv')
            if ($expression) { $networkExprText.Text = $expression }
            if ($metadata) {
                $networkMetadataText.Text = $metadata
                $headers = @(Get-TableHeaders $metadata)
                Fill-Combo $networkSampleColumnCombo $headers $(if ($headers.Count) { $headers[0] } else { '' })
            }
            if ($regulators) { $networkRegulatorText.Text = $regulators }
            if (-not $networkOutputText.Text.Trim()) { $networkOutputText.Text = $suggestedOutputRoot }
            $message = "DE / co-expression folder scanned:`r`n$folder`r`n`r`nNormalized expression: $(if($expression){$expression}else{'NOT FOUND - run Differential Expression first or browse manually'})`r`nSample metadata: $(if($metadata){$metadata}else{'NOT FOUND'})`r`nRegulator list: $(if($regulators){$regulators}else{'not found (optional; only needed for GENIE3)'})"
            Show-Message $message 'Network input scan'
        }
    }
}

function Load-DEMetadataControls([string]$MetadataPath) {
    if (-not $MetadataPath -or -not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) { return }
    $deMetadataText.Text = $MetadataPath
    $headers = @(Get-TableHeaders $MetadataPath)
    Fill-Combo $deSampleColumnCombo $headers $(if ($headers.Count) { $headers[0] } else { '' })
    Fill-Combo $deConditionCombo $headers $(if ($headers.Count -gt 1) { $headers[1] } else { '' })
    Fill-Combo $deBatchCombo (@('None') + $headers) 'None'
}

function Get-SharedAnalysisOutput([string]$Kind) {
    $pointer = Join-Path $script:SharedStateDir ("last_$Kind`_output.txt")
    if (-not (Test-Path -LiteralPath $pointer -PathType Leaf)) { return '' }
    try {
        $value = (Get-Content -LiteralPath $pointer -Raw).Trim()
        if ($value -and (Test-Path -LiteralPath $value -PathType Container)) { return $value }
    } catch { }
    return ''
}

function Find-AnalysisDataFile([string]$OutputDirectory, [string]$FileName) {
    if ([string]::IsNullOrWhiteSpace($OutputDirectory) -or [string]::IsNullOrWhiteSpace($FileName)) { return '' }
    $displayName = ($FileName -replace '_', ' ')
    $handoffCandidates = @()
    switch ($FileName.ToLowerInvariant()) {
        'differential_expression.tsv' {
            $handoffCandidates += (Join-Path (Join-Path (Join-Path $OutputDirectory $script:DEHandoffContainerName) 'GO Enrichment and Pathways Input') 'differential expression.tsv')
            $handoffCandidates += (Join-Path (Join-Path $OutputDirectory 'GO Enrichment and Pathways Input') 'differential expression.tsv')
        }
        'normalized_counts.tsv' {
            $handoffCandidates += (Join-Path (Join-Path (Join-Path $OutputDirectory $script:DEHandoffContainerName) 'Co-expression and Networks Input') 'normalized counts.tsv')
            $handoffCandidates += (Join-Path (Join-Path $OutputDirectory 'Co-expression and Networks Input') 'normalized counts.tsv')
        }
        'analysis_metadata.tsv' {
            $handoffCandidates += (Join-Path (Join-Path (Join-Path $OutputDirectory $script:DEHandoffContainerName) 'Co-expression and Networks Input') 'sample metadata.tsv')
            $handoffCandidates += (Join-Path (Join-Path $OutputDirectory 'Co-expression and Networks Input') 'sample metadata.tsv')
        }
    }
    $candidates = @(
        $handoffCandidates
        (Join-Path $OutputDirectory $FileName)
        (Join-Path $OutputDirectory $displayName)
        (Join-Path (Join-Path $OutputDirectory 'Intermediate files') $FileName)
        (Join-Path (Join-Path $OutputDirectory 'Intermediate files') $displayName)
        (Join-Path (Join-Path (Join-Path $OutputDirectory 'Technical details') 'Data tables') $FileName)
        (Join-Path (Join-Path (Join-Path $OutputDirectory 'Technical details') 'Data tables') $displayName)
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ''
}

function Get-OrganizedAnalysisOutput([string]$Mode, [string]$SelectedDirectory, [string]$Engine = '') {
    $root = [string]$SelectedDirectory
    if ([string]::IsNullOrWhiteSpace($root)) { return '' }
    $root = $root.Trim()
    $pathRoot = [System.IO.Path]::GetPathRoot($root)
    if (-not $pathRoot -or $root.Length -gt $pathRoot.Length) {
        $root = $root.TrimEnd([char[]]@('\','/'))
    }
    $folderName = switch ($Mode) {
        'de' {
            switch ($Engine.ToLowerInvariant()) {
                'deseq2' { 'DESeq2 analysis' }
                'edger' { 'edgeR analysis' }
                default { 'limma-voom analysis' }
            }
        }
        'enrichment' { 'GO analysis' }
        'network' { 'Co-expression analysis' }
        'combined' { 'Functional enrichment and co-expression analysis' }
        default { 'Analysis results' }
    }
    $leaf = [System.IO.Path]::GetFileName($root)
    $recognized = switch ($Mode) {
        'de' { @('DESeq2 analysis','edgeR analysis','limma-voom analysis','Differential expression analysis') }
        'enrichment' { @('GO analysis','Enrichment analysis') }
        'network' { @('Co-expression analysis','Network analysis') }
        'combined' { @('Functional enrichment and co-expression analysis','GO analysis','Enrichment analysis','Co-expression analysis','Network analysis') }
        default { @($folderName) }
    }
    if ($Mode -eq 'combined' -and $recognized -contains $leaf) {
        if ($leaf -eq $folderName) { return $root }
        return (Join-Path (Split-Path -Parent $root) $folderName)
    }
    if ($leaf -eq $folderName -or $leaf -in @('Differential expression analysis','Enrichment analysis','Network analysis')) { return $root }
    if ($Mode -eq 'de' -and $recognized -contains $leaf) {
        return (Join-Path (Split-Path -Parent $root) $folderName)
    }
    return (Join-Path $root $folderName)
}

$green = [System.Drawing.Color]::FromArgb(65, 122, 75)
$greenDark = [System.Drawing.Color]::FromArgb(42, 85, 52)
$greenSoft = [System.Drawing.Color]::FromArgb(230, 242, 232)
$blue = [System.Drawing.Color]::FromArgb(55, 116, 151)
$blueSoft = [System.Drawing.Color]::FromArgb(230, 241, 248)
$ink = [System.Drawing.Color]::FromArgb(30, 42, 34)
$muted = [System.Drawing.Color]::FromArgb(88, 101, 93)
$border = [System.Drawing.Color]::FromArgb(205, 218, 208)
$background = [System.Drawing.Color]::FromArgb(245, 248, 246)
$surface = [System.Drawing.Color]::White
$orangeSoft = [System.Drawing.Color]::FromArgb(255, 244, 224)
$orange = [System.Drawing.Color]::FromArgb(178, 107, 28)

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 180, [int]$Height = 24, [switch]$Bold)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = [System.Drawing.Point]::new($X, $Y)
    $label.Size = [System.Drawing.Size]::new($Width, $Height)
    $label.ForeColor = $ink
    $label.AutoSize = $false
    $label.AutoEllipsis = $true
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 9, $style)
    return $label
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 120, [int]$Height = 32, [switch]$Primary)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = [System.Drawing.Point]::new($X, $Y)
    $button.Size = [System.Drawing.Size]::new($Width, $Height)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderColor = $border
    $button.BackColor = $surface
    $button.ForeColor = $ink
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    if ($Primary) {
        $button.BackColor = $green
        $button.ForeColor = $surface
        $button.FlatAppearance.BorderColor = $green
    }
    return $button
}

function New-TextBox {
    param([int]$X, [int]$Y, [int]$Width = 330, [string]$Text = '')
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = [System.Drawing.Point]::new($X, $Y)
    $box.Size = [System.Drawing.Size]::new($Width, 25)
    $box.Text = $Text
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    return $box
}

function Enable-NeutralComboBox {
    param([System.Windows.Forms.ComboBox]$Combo)
    if (-not $Combo) { return }
    if ($Combo.DrawMode -ne [System.Windows.Forms.DrawMode]::OwnerDrawFixed) {
        $Combo.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
        $Combo.ItemHeight = 22
        # Keep the normal Windows border/drop-arrow. Flat style made empty or
        # not-yet-populated selectors look like a detached white arrow box.
        $Combo.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
        $Combo.BackColor = $surface
        $Combo.ForeColor = $ink
        $Combo.Add_DrawItem({
            param($sender, $e)
            $isEdit = (($e.State -band [System.Windows.Forms.DrawItemState]::ComboBoxEdit) -ne 0)
            $selected = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0) -and (-not $isEdit)
            $back = if ($selected) { $greenSoft } else { $surface }
            $brush = New-Object System.Drawing.SolidBrush($back)
            try { $e.Graphics.FillRectangle($brush, $e.Bounds) } finally { $brush.Dispose() }
            $text = ''
            if ($e.Index -ge 0 -and $e.Index -lt $sender.Items.Count) {
                $text = [string]$sender.Items[$e.Index]
            }
            elseif ($sender.SelectedIndex -ge 0 -and $sender.SelectedIndex -lt $sender.Items.Count) {
                $text = [string]$sender.Items[$sender.SelectedIndex]
            }
            elseif ($sender.Text) {
                $text = [string]$sender.Text
            }
            $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $text, $sender.Font, $e.Bounds, $ink, $back, $flags)
        })
        if ($Combo.DropDownStyle -eq [System.Windows.Forms.ComboBoxStyle]::DropDown) {
            $Combo.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::None
            $Combo.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::None
            $clearComboSelection = {
                param($sender, $eventArgs)
                try {
                    $sender.SelectionStart = $sender.Text.Length
                    $sender.SelectionLength = 0
                } catch { }
            }
            $Combo.Add_Enter($clearComboSelection)
            $Combo.Add_GotFocus($clearComboSelection)
            $Combo.Add_DropDownClosed($clearComboSelection)
            $Combo.Add_SelectedIndexChanged($clearComboSelection)
        }
    }
}

function New-ComboBox {
    param([int]$X, [int]$Y, [int]$Width = 210, [string[]]$Items = @())
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Location = [System.Drawing.Point]::new($X, $Y)
    $combo.Size = [System.Drawing.Size]::new($Width, 25)
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $combo.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    Enable-NeutralComboBox $combo
    if ($Items.Count -gt 0) { [void]$combo.Items.AddRange($Items) }
    if ($combo.Items.Count -gt 0) { $combo.SelectedIndex = 0 }
    return $combo
}

function Enable-NeutralListBox {
    param([System.Windows.Forms.ListBox]$List)
    if (-not $List) { return }
    if ($List.DrawMode -ne [System.Windows.Forms.DrawMode]::OwnerDrawFixed) {
        $List.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
        $List.ItemHeight = 22
        $List.BackColor = $surface
        $List.ForeColor = $ink
        $List.Add_DrawItem({
            param($sender, $e)
            if ($e.Index -lt 0) { return }
            $selected = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
            $back = if ($selected) { $greenSoft } else { $surface }
            $brush = New-Object System.Drawing.SolidBrush($back)
            try { $e.Graphics.FillRectangle($brush, $e.Bounds) } finally { $brush.Dispose() }
            $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$sender.Items[$e.Index], $sender.Font, $e.Bounds, $ink, $back, $flags)
        })
    }
}

function Set-NeutralGridSelection {
    param([System.Windows.Forms.DataGridView]$Grid)
    if (-not $Grid) { return }
    foreach ($style in @($Grid.DefaultCellStyle, $Grid.RowsDefaultCellStyle, $Grid.AlternatingRowsDefaultCellStyle)) {
        $style.SelectionBackColor = $greenSoft
        $style.SelectionForeColor = $ink
    }
    $Grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $Grid.ColumnHeadersDefaultCellStyle.BackColor
    $Grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $Grid.ColumnHeadersDefaultCellStyle.ForeColor
    $Grid.RowHeadersDefaultCellStyle.SelectionBackColor = $greenSoft
    $Grid.RowHeadersDefaultCellStyle.SelectionForeColor = $ink
    $Grid.Add_EditingControlShowing({
        param($sender, $e)
        if ($e.Control -is [System.Windows.Forms.ComboBox]) { Enable-NeutralComboBox ([System.Windows.Forms.ComboBox]$e.Control) }
    })
}

function New-CheckBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 130, [bool]$Checked = $true)
    $check = New-Object System.Windows.Forms.CheckBox
    $check.Text = $Text
    $check.Location = [System.Drawing.Point]::new($X, $Y)
    $check.Size = [System.Drawing.Size]::new($Width, 25)
    $check.Checked = $Checked
    $check.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $check.ForeColor = $ink
    return $check
}

function New-Group {
    param([string]$Text, [int]$Y, [int]$Height)
    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = $Text
    $group.Location = [System.Drawing.Point]::new(0, $Y)
    $group.Size = [System.Drawing.Size]::new(600, $Height)
    $group.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $group.BackColor = $surface
    $group.ForeColor = $greenDark
    $group.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    if ($script:BuildingDownstreamUi) {
        $group.SuspendLayout()
        [void]$script:DeferredLayoutControls.Add($group)
    }
    return $group
}

function Select-InputFile([string]$Title, [string]$Filter) {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
    return ''
}

function Select-OutputFolder([string]$Description) {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
    return ''
}

function Open-ExampleWorkbook([string]$FileName) {
    $path = Join-Path $script:ExamplesDir $FileName
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Start-Process -FilePath $path
        return
    }
    Show-Error "The example workbook is missing: $FileName. Re-extract the complete application package."
}

function Invoke-ManualWorkbookInput {
    param([ValidateSet('de','combined','network')][string]$Profile)
    . (Join-Path $script:AppDir 'manual_input_editor.ps1')
    $helperPath = $script:ManualWorkbookScript
    $getDistro = ${function:Get-WslDistroLocal}
    $convertPath = ${function:Convert-ToWslPathLocal}
    $capture = ${function:Invoke-WslCaptureLocal}
    $runHelper = {
        param($action,$source,$destination)
        $distro = & $getDistro
        if (-not $distro) { throw 'Use Check environment or Install/update before using or exporting your data. The draft remains open.' }
        $helperWsl = & $convertPath $helperPath $distro
        $sourceWsl = & $convertPath $source $distro
        $destinationWsl = & $convertPath $destination $distro
        $python = '/root/.local/share/prok-rnaseq/miniforge3/envs/prok-rnaseq-downstream/bin/python'
        $result = & $capture -Arguments @('-d',$distro,'-u','root','--',$python,$helperWsl,$action,'--profile',$Profile,'--input',$sourceWsl,'--output',$destinationWsl) -TimeoutMilliseconds 120000
        if ($result.ExitCode -ne 0) { throw ((@($result.StandardOutput,$result.StandardError) | Where-Object { $_ }) -join "`r`n") }
    }.GetNewClosure()
    return Show-BraInputWorkbook -Profile $Profile -ResourceDir $script:ManualWorkbookExamplesDir -RunHelper $runHelper -Owner $form
}

function Get-ManualWorkbookFile($Result, [string]$FileName) {
    if ($null -eq $Result -or -not $Result.OutputDir) { return '' }
    $path = Join-Path ([string]$Result.OutputDir) $FileName
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return ''
}

function Show-Message([string]$Text, [string]$Title = $script:ModuleDisplayName) {
    [System.Windows.Forms.MessageBox]::Show($form, $Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Format-StructuredHelpText {
    param([System.Windows.Forms.RichTextBox]$Box, [string]$Title = '')
    if (-not $Box) { return }
    $regularFont = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    $boldFont = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $headingFont = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
    $Box.SelectAll()
    $Box.SelectionFont = $regularFont
    $Box.SelectionColor = $ink

    if ($Title) {
        $titleIndex = $Box.Text.IndexOf($Title, [System.StringComparison]::Ordinal)
        if ($titleIndex -ge 0) {
            $Box.Select($titleIndex, $Title.Length)
            $Box.SelectionFont = $headingFont
            $Box.SelectionColor = $greenDark
        }
    }

    # Bold parameter/category prefixes such as "Raw counts:", "Strengths:",
    # "Accepted range:", and "Recommended starting value:" everywhere.
    $prefixPattern = '(?m)^([A-Za-z][A-Za-z0-9 /+&().,_\-]{1,72}:)'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Box.Text, $prefixPattern)) {
        $Box.Select($match.Index, $match.Length)
        $Box.SelectionFont = $boldFont
        $Box.SelectionColor = $greenDark
    }

    # Package/method names are standalone paragraph headings immediately followed
    # by Strengths/Limitations. Make those headings visibly distinct as well.
    $sectionPattern = '(?m)^([^\r\n:]{2,90})(?=\r?\n(?:Strengths:|Accepted range:|Recommended starting value:|Trade-off:))'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Box.Text, $sectionPattern)) {
        $Box.Select($match.Index, $match.Length)
        $Box.SelectionFont = $headingFont
        $Box.SelectionColor = $greenDark
    }
    $Box.Select(0, 0)
}

function Show-StructuredGuideDialog {
    param([string]$Text, [string]$Title)
    $screenArea = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $dialogWidth = [Math]::Min(980, [Math]::Max(700, ($screenArea.Width - 80)))
    $dialogHeight = [Math]::Min(650, [Math]::Max(480, ($screenArea.Height - 100)))

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.ClientSize = [System.Drawing.Size]::new($dialogWidth, $dialogHeight)
    $dialog.MinimumSize = [System.Drawing.Size]::new(620, 460)
    $dialog.BackColor = $background
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dialog.ShowInTaskbar = $false

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = [System.Windows.Forms.DockStyle]::Fill
    $root.ColumnCount = 1
    $root.RowCount = 3
    $root.Margin = New-Object System.Windows.Forms.Padding(0)
    $root.Padding = New-Object System.Windows.Forms.Padding(0)
    [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 56)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 58)))
    $dialog.Controls.Add($root)

    $header = New-Object System.Windows.Forms.Label
    $header.Text = $Title
    $header.Dock = [System.Windows.Forms.DockStyle]::Fill
    $header.Padding = New-Object System.Windows.Forms.Padding(18, 8, 12, 4)
    $header.BackColor = $greenSoft
    $header.ForeColor = $greenDark
    $header.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $header.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $root.Controls.Add($header, 0, 0)

    $contentHost = New-Object System.Windows.Forms.Panel
    $contentHost.Dock = [System.Windows.Forms.DockStyle]::Fill
    $contentHost.Padding = New-Object System.Windows.Forms.Padding(18, 14, 18, 10)
    $contentHost.BackColor = $surface
    $root.Controls.Add($contentHost, 0, 1)

    $box = New-Object System.Windows.Forms.RichTextBox
    $box.Dock = [System.Windows.Forms.DockStyle]::Fill
    $box.ReadOnly = $true
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $box.BackColor = $surface
    $box.ForeColor = $ink
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $box.WordWrap = $true
    $box.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
    $box.Text = $Text.Trim()
    Format-StructuredHelpText -Box $box
    $contentHost.Controls.Add($box)

    $buttonPanel = New-Object System.Windows.Forms.Panel
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $buttonPanel.BackColor = $background
    $root.Controls.Add($buttonPanel, 0, 2)
    $ok = New-Button 'OK' 0 10 110 36 -Primary
    $ok.Anchor = [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Top
    $buttonPanel.Controls.Add($ok)
    $buttonPanel.Add_Resize({ $ok.Left = [Math]::Max(8, $buttonPanel.ClientSize.Width - $ok.Width - 18) })
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $dialog.AcceptButton = $ok
    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()
}

function Test-OnlineAnnotationDatabase {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $uri = 'https://rest.uniprot.org/uniprotkb/search?query=reviewed%3Atrue&format=tsv&fields=accession&size=1'
        $request = [System.Net.HttpWebRequest]::Create($uri)
        $request.Method = 'GET'
        $request.UserAgent = 'BacterialRNAAnalysis/1.9.3'
        $request.Timeout = 15000
        $request.ReadWriteTimeout = 15000
        $response = $request.GetResponse()
        try {
            $release = [string]$response.Headers['x-uniprot-release']
            if (-not $release) { $release = 'current' }
            Show-Message "UniProt is reachable. Database release: $release`r`n`r`nIdentifier annotation can run online. Protein/CDS sequence annotation additionally uses the DIAMOND tool and a cached reviewed Swiss-Prot sequence database, which is downloaded automatically on first use." 'Online annotation database'
        } finally { $response.Close() }
    } catch {
        Show-Error ("Could not connect to UniProt.`r`n`r`n" + $_.Exception.Message)
    }
}

function Test-KEGGDatabaseConnection {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $request = [System.Net.HttpWebRequest]::Create('https://rest.kegg.jp/info/kegg')
        $request.Method = 'GET'
        $request.UserAgent = 'BacterialRNAAnalysis/1.9.77'
        $request.Timeout = 15000
        $request.ReadWriteTimeout = 15000
        $response = $request.GetResponse()
        try {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
            try { $firstLine = [string]$reader.ReadLine() } finally { $reader.Dispose() }
            if ([string]::IsNullOrWhiteSpace($firstLine)) { throw 'KEGG returned an empty response.' }
            Show-Message "KEGG REST is reachable.`r`n`r`n$firstLine" 'KEGG database connection'
        } finally { $response.Close() }
    } catch {
        Show-Error ("Could not connect to KEGG REST.`r`n`r`n" + $_.Exception.Message)
    }
}

function Test-STRINGDatabaseConnection {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $uri = 'https://version-12-0.string-db.org/api/tsv/get_string_ids?identifiers=recA&species=511145&limit=1&echo_query=1'
        $request = [System.Net.HttpWebRequest]::Create($uri)
        $request.Method = 'GET'
        $request.UserAgent = 'BacterialRNAAnalysis/1.9.77'
        $request.Timeout = 15000
        $request.ReadWriteTimeout = 15000
        $response = $request.GetResponse()
        try {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
            try { $firstLine = [string]$reader.ReadLine() } finally { $reader.Dispose() }
            if ([string]::IsNullOrWhiteSpace($firstLine)) { throw 'STRING returned an empty response.' }
            Show-Message 'STRING v12 is reachable and its identifier-mapping API responded successfully.' 'STRING database connection'
        } finally { $response.Close() }
    } catch {
        Show-Error ("Could not connect to STRING v12.`r`n`r`n" + $_.Exception.Message)
    }
}

function Get-OnlineAnnotationModeKey([string]$Value) {
    if ($Value -like 'Protein FASTA*') { return 'protein_fasta' }
    if ($Value -like 'CDS nucleotide FASTA*') { return 'nucleotide_fasta' }
    return 'gene_ids'
}

function Get-OnlineAnnotationDatabaseKey([string]$Value) {
    if ($Value -like 'UniProtKB (reviewed + TrEMBL)*') { return 'uniprot_all' }
    return 'uniprot_reviewed'
}

$script:CommonBacterialOrganisms = @(
    'No organism / no taxonomy ID (unrestricted; lower confidence)',
    'Escherichia coli (E. coli) [taxid: 562]',
    'Bacillus subtilis [taxid: 1423]',
    'Pseudomonas aeruginosa [taxid: 287]',
    'Staphylococcus aureus [taxid: 1280]',
    'Streptomyces (genus) [taxid: 1883]',
    'Streptomyces coelicolor [taxid: 1902]',
    'Streptomyces avermitilis [taxid: 33903]',
    'Amycolatopsis (genus) [taxid: 1813]',
    'Amycolatopsis mediterranei [taxid: 33910]',
    'Amycolatopsis orientalis [taxid: 31958]',
    'Amycolatopsis sp. TNS106 (TNS.106) [taxid: 2861750]',
    'Mycobacterium tuberculosis [taxid: 1773]',
    'Salmonella enterica [taxid: 28901]',
    'Klebsiella pneumoniae [taxid: 573]',
    'Acinetobacter baumannii [taxid: 470]',
    'Vibrio cholerae [taxid: 666]',
    'Listeria monocytogenes [taxid: 1639]',
    'Clostridioides difficile [taxid: 1496]',
    'Corynebacterium glutamicum [taxid: 1718]',
    'Rhizobium leguminosarum [taxid: 384]',
    'Synechocystis sp. PCC 6803 [taxid: 1148]',
    'Lactiplantibacillus plantarum [taxid: 1590]'
)

function New-OrganismComboBox([int]$X, [int]$Y, [int]$Width = 260) {
    $combo = New-ComboBox $X $Y $Width $script:CommonBacterialOrganisms
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $combo.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::SuggestAppend
    $combo.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::ListItems
    $combo.DropDownWidth = 470
    $combo.MaxDropDownItems = 22
    $combo.IntegralHeight = $false
    $combo.DropDownHeight = 360
    $combo.SelectedIndex = 0
    return $combo
}

function Get-OrganismQueryText([System.Windows.Forms.Control]$Control) {
    $value = if ($Control) { [string]$Control.Text } else { '' }
    $value = $value.Trim()
    if (-not $value -or $value -like 'No organism / no taxonomy ID*' -or $value -like 'No organism / unknown*' -or $value -like 'Other / more organisms*') { return '' }
    if ($value -match '\[taxid:\s*(\d+)\]') { return [string]$Matches[1] }
    return ([regex]::Replace($value, '\s*\[taxid:\s*\d+\]\s*$', '')).Trim()
}

function Confirm-UnrestrictedOrganismSearch {
    $text = "No organism name or taxonomy ID was supplied.`r`n`r`nThe software will search the requested identifiers across organisms. Common bacterial gene names can match the wrong species, so results may be uncertain. Enter an organism name or taxonomy ID whenever possible for more accurate annotation.`r`n`r`nContinue with the unrestricted search?"
    $answer = [System.Windows.Forms.MessageBox]::Show($form, $text, 'Unrestricted organism search', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

function New-AdvancedPackageDefinition {
    param(
        [string]$Key,
        [string]$Function,
        [string]$Example,
        [string[]]$Protected = @()
    )
    [pscustomobject]@{ Key = $Key; Function = $Function; Example = $Example; Protected = @($Protected) }
}

function Get-AdvancedPackageDefinitions([string]$Mode) {
    if ($Mode -eq 'combined') {
        $combinedDefinitions = @(Get-AdvancedPackageDefinitions 'enrichment')
        $combinedDefinitions += @(Get-AdvancedPackageDefinitions 'network')
        # Keep the full integrated database controls available in the same
        # guided editor. These values override the compact main-page fields
        # only when their Use checkbox is selected.
        $combinedDefinitions += @(
            (New-AdvancedPackageDefinition 'integrated_kegg_pathway' 'Scientific Expansion::pathway (KEGG REST)' '{"organism":"amys"}' @('gene_list','gene_column','universe','universe_column','confirmed','kegg_confirmed','output_dir')),
            (New-AdvancedPackageDefinition 'integrated_string_network' 'Scientific Expansion::string_network (STRING REST)' '{"taxid":31958,"network_type":"physical","required_score":700,"add_nodes":0,"identifier_aliases":null}' @('gene_list','gene_column','expression_edges','output_dir'))
        )
        return @($combinedDefinitions)
    }
    if ($Mode -eq 'de') {
        $selected = [string]$deEngineCombo.SelectedItem
        if ($selected -like 'DESeq2*') {
            return @(
                (New-AdvancedPackageDefinition 'deseq2_deseq' 'DESeq2::DESeq' '{"fitType":"local","sfType":"poscounts","minReplicatesForReplace":7,"parallel":false}' @('object','full','reduced')),
                (New-AdvancedPackageDefinition 'deseq2_results' 'DESeq2::results' '{"independentFiltering":false,"pAdjustMethod":"BH","cooksCutoff":false,"lfcThreshold":0}' @('object','contrast','name','alpha','format','tidy'))
            )
        }
        if ($selected -like 'edgeR*') {
            return @(
                (New-AdvancedPackageDefinition 'edger_dge_list' 'edgeR::DGEList' '{"remove.zeros":false}' @('counts','group','lib.size','norm.factors','samples','genes')),
                (New-AdvancedPackageDefinition 'edger_filter_by_expr' 'edgeR::filterByExpr' '{"min.count":10,"min.total.count":15,"large.n":10,"min.prop":0.7}' @('y','design','group','lib.size')),
                (New-AdvancedPackageDefinition 'edger_calc_norm_factors' 'edgeR::calcNormFactors' '{"method":"TMMwsp","logratioTrim":0.3,"sumTrim":0.05,"doWeighting":true}' @('object')),
                (New-AdvancedPackageDefinition 'edger_estimate_disp' 'edgeR::estimateDisp' '{"trend.method":"locfit","robust":true,"winsor.tail.p":[0.05,0.1]}' @('y','design')),
                (New-AdvancedPackageDefinition 'edger_glm_ql_fit' 'edgeR::glmQLFit' '{"robust":true,"abundance.trend":true,"winsor.tail.p":[0.05,0.1]}' @('y','design')),
                (New-AdvancedPackageDefinition 'edger_glm_ql_test' 'edgeR::glmQLFTest' '{"poisson.bound":true}' @('glmfit','coef','contrast')),
                (New-AdvancedPackageDefinition 'edger_top_tags' 'edgeR::topTags' '{"adjust.method":"BH"}' @('object','n','sort.by')),
                (New-AdvancedPackageDefinition 'edger_cpm_normalized' 'edgeR::cpm (normalized export)' '{"normalized.lib.sizes":true}' @('y','log')),
                (New-AdvancedPackageDefinition 'edger_cpm_plot' 'edgeR::cpm (plot matrix)' '{"normalized.lib.sizes":true,"prior.count":2}' @('y','log'))
            )
        }
        return @(
            (New-AdvancedPackageDefinition 'limma_dge_list' 'edgeR::DGEList (limma-voom)' '{"remove.zeros":false}' @('counts','group','lib.size','norm.factors','samples','genes')),
            (New-AdvancedPackageDefinition 'limma_filter_by_expr' 'edgeR::filterByExpr (limma-voom)' '{"min.count":10,"min.total.count":15,"large.n":10,"min.prop":0.7}' @('y','design','group','lib.size')),
            (New-AdvancedPackageDefinition 'limma_calc_norm_factors' 'edgeR::calcNormFactors (limma-voom)' '{"method":"TMM"}' @('object')),
            (New-AdvancedPackageDefinition 'limma_voom' 'limma::voom' '{"normalize.method":"none","span":0.5,"save.plot":false}' @('counts','design','plot')),
            (New-AdvancedPackageDefinition 'limma_lm_fit' 'limma::lmFit' '{"method":"ls","ndups":1,"spacing":1}' @('object','design')),
            (New-AdvancedPackageDefinition 'limma_ebayes' 'limma::eBayes' '{"proportion":0.01,"trend":false,"robust":true,"winsor.tail.p":[0.05,0.1]}' @('fit')),
            (New-AdvancedPackageDefinition 'limma_top_table' 'limma::topTable' '{"adjust.method":"BH","p.value":1,"lfc":0,"confint":false}' @('fit','coef','number','sort.by')),
            (New-AdvancedPackageDefinition 'limma_cpm_normalized' 'edgeR::cpm (limma-voom export)' '{"normalized.lib.sizes":true}' @('y','log'))
        )
    }
    if ($Mode -eq 'enrichment') {
        $selected = [string]$enrichMethodCombo.SelectedItem
        if ($selected -like 'clusterProfiler*') {
            return @(
                (New-AdvancedPackageDefinition 'clusterprofiler_enricher' 'clusterProfiler::enricher' '{"pAdjustMethod":"BH","pvalueCutoff":1,"qvalueCutoff":1,"minGSSize":3,"maxGSSize":500}' @('gene','universe','TERM2GENE','TERM2NAME'))
            )
        }
        if ($selected -like 'fgsea*') {
            return @(
                (New-AdvancedPackageDefinition 'fgsea_multilevel' 'fgsea::fgseaMultilevel' '{"minSize":3,"maxSize":500,"eps":0,"scoreType":"std","nPermSimple":1000}' @('pathways','stats'))
            )
        }
        return @(
            (New-AdvancedPackageDefinition 'topgo_data' 'methods::new (topGOdata)' '{"ontology":"BP","nodeSize":3,"description":"Bacterial RNA-seq"}' @('Class','allGenes','geneSel','annot','gene2GO')),
            (New-AdvancedPackageDefinition 'topgo_classic_test' 'topGO::runTest (secondary)' '{"algorithm":"classic","statistic":"fisher"}' @('object')),
            (New-AdvancedPackageDefinition 'topgo_weight_test' 'topGO::runTest (primary)' '{"algorithm":"weight01","statistic":"fisher"}' @('object')),
            (New-AdvancedPackageDefinition 'topgo_gen_table' 'topGO::GenTable' '{"topNodes":100,"orderBy":"primaryResult","ranksOf":"primaryResult","numChar":80}' @('object','secondaryResult','primaryResult'))
        )
    }
    $selected = [string]$networkMethodCombo.SelectedItem
    if ($selected -like 'WGCNA*') {
        return @(
            (New-AdvancedPackageDefinition 'wgcna_good_samples_genes' 'WGCNA::goodSamplesGenes' '{"minFraction":0.5,"minNSamples":4,"minNGenes":4,"verbose":2}' @('datExpr')),
            (New-AdvancedPackageDefinition 'wgcna_pick_soft_threshold' 'WGCNA::pickSoftThreshold' '{"powerVector":[1,2,4,6,8,10,12,16,20],"RsquaredCut":0.85,"blockSize":1000,"verbose":2}' @('data')),
            (New-AdvancedPackageDefinition 'wgcna_blockwise_modules' 'WGCNA::blockwiseModules' '{"deepSplit":3,"detectCutHeight":0.995,"reassignThreshold":0,"pamStage":true,"saveTOMs":false}' @('datExpr')),
            (New-AdvancedPackageDefinition 'wgcna_module_eigengenes' 'WGCNA::moduleEigengenes' '{"impute":true,"nPC":1,"align":"along average"}' @('expr','colors'))
        )
    }
    if ($selected -like 'CEMiTool*') {
        return @(
            (New-AdvancedPackageDefinition 'cemitool_run' 'CEMiTool::cemitool' '{"filter":true,"filter_pval":0.1,"apply_vst":false,"cor_method":"pearson","network_type":"unsigned","min_ngen":30,"plot":false,"verbose":true}' @('expr')),
            (New-AdvancedPackageDefinition 'cemitool_module_genes' 'CEMiTool::module_genes' '{"module":null}' @('cem'))
        )
    }
    return @(
        (New-AdvancedPackageDefinition 'genie3_run' 'GENIE3::GENIE3' '{"nTrees":2000,"nCores":8,"treeMethod":"RF","K":"sqrt","verbose":true}' @('exprMatr','regulators')),
        (New-AdvancedPackageDefinition 'genie3_link_list' 'GENIE3::getLinkList' '{"reportMax":10000}' @('weightMatrix'))
    )
}

function Get-AdvancedPackageConfig([string]$Mode) {
    $result = [ordered]@{}
    foreach ($definition in @(Get-AdvancedPackageDefinitions $Mode)) {
        if ($script:AdvancedPackageOptions.ContainsKey($definition.Key)) {
            $result[$definition.Key] = [string]$script:AdvancedPackageOptions[$definition.Key]
        }
    }
    return ,$result
}

$script:PackageOptionDescriptions = @{
    'fitType' = 'Mean-dispersion trend fitting method used by DESeq2.'
    'sfType' = 'Size-factor estimator used for library normalization.'
    'minReplicatesForReplace' = 'Minimum replicate count required before Cook-outlier replacement is considered.'
    'parallel' = 'Allow package-level parallel execution where the installed package supports it.'
    'independentFiltering' = 'Filter low-information features before multiple-testing adjustment.'
    'pAdjustMethod' = 'Multiple-testing correction applied to raw p-values.'
    'cooksCutoff' = 'Enable, disable, or numerically set Cook-distance filtering.'
    'lfcThreshold' = 'Log2 fold-change threshold incorporated into the statistical test.'
    'remove.zeros' = 'Remove rows whose counts are zero in every sample.'
    'min.count' = 'Minimum count used by expression filtering.'
    'min.total.count' = 'Minimum total count across the retained sample group.'
    'large.n' = 'Sample-count threshold at which large-group filtering behavior begins.'
    'min.prop' = 'Minimum proportion of samples that must satisfy the count criterion.'
    'method' = 'Package-specific fitting or normalization method.'
    'logratioTrim' = 'Fraction trimmed from both ends of the log-ratio distribution.'
    'sumTrim' = 'Fraction trimmed from both ends of the absolute-expression distribution.'
    'doWeighting' = 'Use precision weighting during normalization.'
    'trend.method' = 'Method used to fit the dispersion trend.'
    'robust' = 'Use robust estimation to reduce sensitivity to outliers.'
    'winsor.tail.p' = 'Lower and upper tail proportions used for Winsorization.'
    'abundance.trend' = 'Model the abundance-dependent quasi-likelihood trend.'
    'poisson.bound' = 'Apply the Poisson-bound safeguard in quasi-likelihood testing.'
    'adjust.method' = 'Multiple-testing adjustment method used for ranked results.'
    'normalized.lib.sizes' = 'Use effective normalized library sizes for CPM calculation.'
    'prior.count' = 'Prior count added before log-CPM calculation.'
    'normalize.method' = 'Between-array normalization applied by limma or voom.'
    'span' = 'Smoothing span used to fit the voom mean-variance trend.'
    'save.plot' = 'Retain voom trend data for plotting.'
    'ndups' = 'Number of duplicate spots or measurements represented by each row.'
    'spacing' = 'Spacing between duplicate measurements.'
    'proportion' = 'Prior proportion of features expected to be differentially expressed.'
    'trend' = 'Allow empirical-Bayes variance moderation to depend on abundance.'
    'p.value' = 'Maximum p-value retained by the result table function.'
    'lfc' = 'Minimum absolute log2 fold change retained by the result table function.'
    'confint' = 'Request confidence intervals or set their confidence level.'
    'pvalueCutoff' = 'Raw p-value cutoff used inside enrichment testing.'
    'qvalueCutoff' = 'Adjusted q-value cutoff used inside enrichment testing.'
    'minGSSize' = 'Minimum gene-set size accepted by clusterProfiler.'
    'maxGSSize' = 'Maximum gene-set size accepted by clusterProfiler.'
    'minSize' = 'Minimum pathway size accepted by fgsea.'
    'maxSize' = 'Maximum pathway size accepted by fgsea.'
    'eps' = 'Lower bound on the estimated fgsea p-value; zero requests maximum precision.'
    'scoreType' = 'Whether enrichment scores may be two-sided, positive only, or negative only.'
    'nPermSimple' = 'Number of simple permutations used for the initial fgsea estimate.'
    'ontology' = 'Gene Ontology branch used by topGO.'
    'nodeSize' = 'Minimum annotated-gene count retained for a GO node.'
    'description' = 'Human-readable label stored in the topGO analysis object.'
    'algorithm' = 'Graph-aware topGO algorithm used for the enrichment test.'
    'statistic' = 'Statistical test paired with the selected topGO algorithm.'
    'topNodes' = 'Maximum number of GO terms returned by GenTable.'
    'orderBy' = 'Result object used to order the topGO table.'
    'ranksOf' = 'Result object used to report term ranks.'
    'numChar' = 'Maximum number of characters retained in GO term descriptions.'
    'minFraction' = 'Minimum fraction of nonmissing observations required for WGCNA quality filtering.'
    'minNSamples' = 'Minimum number of acceptable samples required by WGCNA.'
    'minNGenes' = 'Minimum number of acceptable genes required by WGCNA.'
    'verbose' = 'Amount of progress information printed by the package function.'
    'powerVector' = 'Candidate soft-threshold powers evaluated by WGCNA.'
    'RsquaredCut' = 'Target signed scale-free topology fit used for power selection.'
    'blockSize' = 'Number of genes processed together during connectivity calculations.'
    'deepSplit' = 'Dynamic tree-cut sensitivity; larger values split modules more aggressively.'
    'detectCutHeight' = 'Dendrogram cut height used for module detection.'
    'reassignThreshold' = 'P-value ratio threshold used when reassigning genes between modules.'
    'pamStage' = 'Run the PAM refinement stage after the initial tree cut.'
    'saveTOMs' = 'Save topological-overlap matrices for later reuse.'
    'impute' = 'Impute missing values before eigengene calculation.'
    'nPC' = 'Number of principal components considered for module eigengenes.'
    'align' = 'Rule used to orient eigengene signs consistently.'
    'filter' = 'Enable CEMiTool expression filtering.'
    'filter_pval' = 'CEMiTool filtering p-value threshold.'
    'apply_vst' = 'Apply variance-stabilizing transformation inside CEMiTool.'
    'cor_method' = 'Correlation coefficient used to build the co-expression network.'
    'network_type' = 'Signedness rule used when converting correlations into network similarity.'
    'min_ngen' = 'Minimum number of genes accepted in a CEMiTool module.'
    'plot' = 'Allow the package function to create its own plots in addition to suite figures.'
    'module' = 'Optional single CEMiTool module name; null returns every module.'
    'nTrees' = 'Number of regression trees trained by GENIE3.'
    'nCores' = 'CPU cores used by GENIE3.'
    'treeMethod' = 'Random-forest or extra-trees learner used by GENIE3.'
    'K' = 'Number of candidate regulators sampled at each tree split, or sqrt/all.'
    'reportMax' = 'Maximum regulator-target links returned by GENIE3.'
    'organism' = 'KEGG organism code or exact organism query used for online pathway retrieval.'
    'taxid' = 'NCBI taxonomy identifier sent to STRING.'
    'required_score' = 'Minimum STRING confidence score from 0 through 1000.'
    'add_nodes' = 'Number of additional STRING interaction partners to request beyond the submitted genes.'
    'identifier_aliases' = 'Optional verified gene-to-protein/UniProt alias table used before STRING mapping. Windows drive paths and WSL paths are accepted.'
}

function Get-FriendlyPackageOptionName([string]$Name) {
    $value = $Name -replace '[._]', ' '
    $value = [System.Text.RegularExpressions.Regex]::Replace($value, '([a-z])([A-Z])', '$1 $2')
    if (-not $value) { return $Name }
    return $value.Substring(0, 1).ToUpperInvariant() + $value.Substring(1)
}

function Get-PackageOptionChoices([string]$FunctionKey, [string]$Name) {
    if ($FunctionKey -eq 'integrated_string_network' -and $Name -eq 'network_type') { return @('physical','functional') }
    switch ($Name) {
        'fitType' { return @('parametric','local','mean','glmGamPoi') }
        'sfType' { return @('ratio','poscounts','iterate') }
        'pAdjustMethod' { return @('BH','fdr','BY','bonferroni','holm','hochberg','hommel','none') }
        'adjust.method' { return @('BH','fdr','BY','bonferroni','holm','hochberg','hommel','none') }
        'trend.method' { return @('locfit','none','movingave','loess','locfit.mixed') }
        'normalize.method' { return @('none','scale','quantile','Aquantile','Gquantile','Rquantile','Tquantile','cyclicloess','vsn') }
        'scoreType' { return @('std','pos','neg') }
        'ontology' { return @('BP','MF','CC') }
        'algorithm' { return @('classic','elim','weight','weight01','lea','parentchild') }
        'statistic' { return @('fisher','ks','ks.ties','globaltest','sum') }
        'align' { return @('along average','(leave orientation unchanged)') }
        'cor_method' { return @('pearson','spearman') }
        'network_type' { return @('unsigned','signed') }
        'treeMethod' { return @('RF','ET') }
        'orderBy' { return @('primaryResult','secondaryResult') }
        'ranksOf' { return @('primaryResult','secondaryResult') }
        'deepSplit' { return @('0','1','2','3','4') }
        'method' {
            if ($FunctionKey -match 'calc_norm_factors') { return @('TMM','TMMwsp','RLE','upperquartile','none') }
            if ($FunctionKey -eq 'limma_lm_fit') { return @('ls','robust') }
        }
    }
    return @()
}

function Get-PackageOptionMetadata([string]$FunctionKey, [string]$Name, [object]$ExampleValue) {
    $choices = @(Get-PackageOptionChoices $FunctionKey $Name)
    $valueType = 'text'
    if ($choices.Count) { $valueType = if ($Name -eq 'deepSplit') { 'integer_choice' } else { 'choice' } }
    elseif ($Name -in @('cooksCutoff','confint')) { $valueType = 'logical_or_number' }
    elseif ($Name -eq 'K') { $valueType = 'text_or_integer' }
    elseif ($null -eq $ExampleValue) { $valueType = 'nullable_text' }
    elseif ($ExampleValue -is [bool]) { $valueType = 'boolean' }
    elseif ($ExampleValue -is [System.Array]) {
        $first = if ($ExampleValue.Count) { $ExampleValue[0] } else { $null }
        $valueType = if ($first -is [byte] -or $first -is [int16] -or $first -is [int32] -or $first -is [int64]) { 'integer_list' } else { 'number_list' }
    }
    elseif ($ExampleValue -is [byte] -or $ExampleValue -is [int16] -or $ExampleValue -is [int32] -or $ExampleValue -is [int64]) { $valueType = 'integer' }
    elseif ($ExampleValue -is [single] -or $ExampleValue -is [double] -or $ExampleValue -is [decimal]) { $valueType = 'number' }
    $description = if ($script:PackageOptionDescriptions.ContainsKey($Name)) { [string]$script:PackageOptionDescriptions[$Name] } else { "Named value passed to the installed package function as '$Name'." }
    if ($FunctionKey -eq 'integrated_string_network' -and $Name -eq 'network_type') {
        $description = 'STRING evidence layer: physical interactions only, or the broader functional association network.'
    }
    return [pscustomobject]@{
        Name = $Name
        Label = Get-FriendlyPackageOptionName $Name
        ValueType = $valueType
        Choices = $choices
        ExampleValue = $ExampleValue
        Description = $description
    }
}

function ConvertTo-PackageOptionDisplayValue([object]$Value, [string]$ValueType) {
    if ($ValueType -eq 'boolean') { return [bool]$Value }
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [System.Array]) {
        return (@($Value | ForEach-Object {
            if ($_ -is [single] -or $_ -is [double]) { ([double]$_).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture) }
            elseif ($_ -is [decimal]) { ([decimal]$_).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
            else { [string]$_ }
        }) -join ', ')
    }
    if ($Value -is [single] -or $Value -is [double]) { return ([double]$Value).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [decimal]) { return ([decimal]$Value).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    return [string]$Value
}

function New-PackageFunctionEditorState([object]$Definition) {
    $example = [string]$Definition.Example | ConvertFrom-Json -ErrorAction Stop
    $savedText = if ($script:AdvancedPackageOptions.ContainsKey($Definition.Key)) { [string]$script:AdvancedPackageOptions[$Definition.Key] } else { '{}' }
    try { $saved = $savedText | ConvertFrom-Json -ErrorAction Stop }
    catch { $saved = '{}' | ConvertFrom-Json }
    $knownNames = @($example.PSObject.Properties.Name)
    $selected = @{}
    foreach ($property in @($saved.PSObject.Properties)) {
        if ($knownNames -contains $property.Name) {
            $exampleProperty = $example.PSObject.Properties[$property.Name]
            $metadata = Get-PackageOptionMetadata ([string]$Definition.Key) ([string]$property.Name) $exampleProperty.Value
            $displayValue = ConvertTo-PackageOptionDisplayValue $property.Value $metadata.ValueType
            if ([string]$property.Name -eq 'align' -and [string]::IsNullOrEmpty([string]$displayValue)) { $displayValue = '(leave orientation unchanged)' }
            $selected[[string]$property.Name] = $displayValue
        }
    }
    # Only documented, guided arguments are retained. Legacy unlisted JSON
    # escape-hatch values are deliberately ignored.
    return [pscustomobject]@{ Selected = $selected }
}

function ConvertFrom-PackageEditorValue([object]$Metadata, [object]$RawValue, [ref]$Message) {
    $type = [string]$Metadata.ValueType
    if ($type -eq 'boolean') { return [bool]$RawValue }
    $raw = ([string]$RawValue).Trim()
    if ([string]$Metadata.Name -eq 'align' -and $raw -eq '(leave orientation unchanged)') { return '' }
    if (-not $raw -and $type -ne 'nullable_text') {
        $Message.Value = "$($Metadata.Name): enter a value or clear the Use checkbox."
        return $null
    }
    if ($type -in @('choice','integer_choice') -and @($Metadata.Choices) -notcontains $raw) {
        $Message.Value = "$($Metadata.Name): choose one of the listed values."
        return $null
    }
    if ($type -in @('integer','integer_choice')) {
        $value = 0L
        if (-not [long]::TryParse($raw, [ref]$value)) { $Message.Value = "$($Metadata.Name): enter a whole number."; return $null }
        return $value
    }
    if ($type -eq 'number') {
        $value = 0.0
        if (-not [double]::TryParse($raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
            $Message.Value = "$($Metadata.Name): enter a number using a decimal point."
            return $null
        }
        return $value
    }
    if ($type -eq 'logical_or_number') {
        if ($raw -ieq 'true') { return $true }
        if ($raw -ieq 'false') { return $false }
        $value = 0.0
        if (-not [double]::TryParse($raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
            $Message.Value = "$($Metadata.Name): enter true, false, or a numeric threshold."
            return $null
        }
        return $value
    }
    if ($type -eq 'text_or_integer') {
        $integer = 0L
        if ([long]::TryParse($raw, [ref]$integer)) { return $integer }
        return $raw
    }
    if ($type -in @('integer_list','number_list')) {
        $parts = @($raw -split '[,;\s]+' | Where-Object { $_ })
        if (-not $parts.Count) { $Message.Value = "$($Metadata.Name): enter one or more comma-separated values."; return $null }
        $values = New-Object System.Collections.Generic.List[object]
        foreach ($part in $parts) {
            if ($type -eq 'integer_list') {
                $integer = 0L
                if (-not [long]::TryParse($part, [ref]$integer)) { $Message.Value = "$($Metadata.Name): '$part' is not a whole number."; return $null }
                [void]$values.Add($integer)
            }
            else {
                $number = 0.0
                if (-not [double]::TryParse($part, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { $Message.Value = "$($Metadata.Name): '$part' is not a number."; return $null }
                [void]$values.Add($number)
            }
        }
        return ,([object[]]$values.ToArray())
    }
    if ($type -eq 'nullable_text' -and ($raw -eq '' -or $raw -ieq 'null')) { return $null }
    return $raw
}

function Get-PackageFunctionManualPath([string]$FunctionName) {
    $fileName = ''
    if ($FunctionName -like 'Scientific Expansion::pathway*') {
        return Join-Path $script:ApplicationRoot 'Modules\GO Enrichment and Pathways\Documentation\Pathway Database Analysis Instructions.html'
    }
    if ($FunctionName -like 'Scientific Expansion::string_network*') {
        return Join-Path $script:ApplicationRoot 'Modules\Co-expression and Networks\Documentation\STRING Protein Associations Instructions.html'
    }
    if ($FunctionName -like 'DESeq2::*') { $fileName = 'DESeq2.html' }
    elseif ($FunctionName -like 'edgeR::*') { $fileName = 'edgeR.html' }
    elseif ($FunctionName -like 'limma::*') { $fileName = 'limma.html' }
    elseif ($FunctionName -like 'clusterProfiler::*') { $fileName = 'clusterProfiler.html' }
    elseif ($FunctionName -like 'fgsea::*') { $fileName = 'fgsea.html' }
    elseif ($FunctionName -like 'topGO::*' -or $FunctionName -like 'methods::new*') { $fileName = 'topGO.html' }
    elseif ($FunctionName -like 'WGCNA::*') { $fileName = 'WGCNA.html' }
    elseif ($FunctionName -like 'CEMiTool::*') { $fileName = 'CEMiTool.html' }
    elseif ($FunctionName -like 'GENIE3::*') { $fileName = 'GENIE3.html' }
    if (-not $fileName) { return '' }
    return Join-Path (Join-Path $script:ApplicationRoot 'Documentation\Offline manuals\Statistical packages') $fileName
}

function ConvertTo-RPreviewLiteral([object]$Value) {
    if ($null -eq $Value) { return 'NULL' }
    if ($Value -is [bool]) { if ([bool]$Value) { return 'TRUE' } else { return 'FALSE' } }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64]) { return [string]$Value }
    if ($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([double]$Value).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [System.Array]) {
        $parts = @($Value | ForEach-Object { ConvertTo-RPreviewLiteral $_ })
        return 'c(' + ($parts -join ', ') + ')'
    }
    $escaped = ([string]$Value).Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Get-PackagePreviewBaseArguments([string]$Key) {
    $args = [ordered]@{}
    switch ($Key) {
        'deseq2_deseq' {
            $args['object'] = '<DESeqDataSet>'
            $args['quiet'] = 'FALSE'
        }
        'deseq2_results' {
            $testLevel = if ($deTestCombo.SelectedItem) { [string]$deTestCombo.SelectedItem } else { '<test level>' }
            $referenceLevel = if ($deReferenceCombo.SelectedItem) { [string]$deReferenceCombo.SelectedItem } else { '<reference level>' }
            $alpha = if ($dePadj.Text.Trim()) { $dePadj.Text.Trim() } else { '0.05' }
            $args['object'] = '<DESeqDataSet>'
            $args['contrast'] = 'c(".condition", ' + (ConvertTo-RPreviewLiteral $testLevel) + ', ' + (ConvertTo-RPreviewLiteral $referenceLevel) + ')'
            $args['alpha'] = $alpha
        }
        'edger_dge_list' { $args['counts'] = '<filtered raw count matrix>' }
        'edger_filter_by_expr' { $args['y'] = '<DGEList>'; $args['design'] = '<design matrix>' }
        'edger_calc_norm_factors' { $args['object'] = '<DGEList>'; $args['method'] = '"TMM"' }
        'edger_estimate_disp' { $args['y'] = '<DGEList>'; $args['design'] = '<design matrix>'; $args['robust'] = 'TRUE' }
        'edger_glm_ql_fit' { $args['y'] = '<DGEList>'; $args['design'] = '<design matrix>'; $args['robust'] = 'TRUE' }
        'edger_glm_ql_test' { $args['glmfit'] = '<glmQLFit result>'; $args['coef'] = '<test coefficient>' }
        'edger_top_tags' { $args['object'] = '<glmQLFTest result>'; $args['n'] = 'Inf'; $args['sort.by'] = '"none"' }
        'edger_cpm_normalized' { $args['y'] = '<DGEList>'; $args['normalized.lib.sizes'] = 'TRUE'; $args['log'] = 'FALSE' }
        'edger_cpm_plot' { $args['y'] = '<DGEList>'; $args['normalized.lib.sizes'] = 'TRUE'; $args['log'] = 'TRUE'; $args['prior.count'] = '2' }
        'limma_dge_list' { $args['counts'] = '<filtered raw count matrix>' }
        'limma_filter_by_expr' { $args['y'] = '<DGEList>'; $args['design'] = '<design matrix>' }
        'limma_calc_norm_factors' { $args['object'] = '<DGEList>' }
        'limma_voom' { $args['counts'] = '<DGEList>'; $args['design'] = '<design matrix>'; $args['plot'] = 'FALSE' }
        'limma_lm_fit' { $args['object'] = '<voom result>'; $args['design'] = '<design matrix>' }
        'limma_ebayes' { $args['fit'] = '<lmFit result>'; $args['robust'] = 'TRUE' }
        'limma_top_table' { $args['fit'] = '<eBayes result>'; $args['coef'] = '<test coefficient>'; $args['number'] = 'Inf'; $args['sort.by'] = '"none"' }
        'limma_cpm_normalized' { $args['y'] = '<DGEList>'; $args['normalized.lib.sizes'] = 'TRUE'; $args['log'] = 'FALSE' }
        'clusterprofiler_enricher' {
            $minSize = if ($minSet.Text.Trim()) { $minSet.Text.Trim() } else { '3' }
            $maxSize = if ($maxSet.Text.Trim()) { $maxSet.Text.Trim() } else { '500' }
            $args['gene'] = '<selected genes>'
            $args['universe'] = '<background genes>'
            $args['TERM2GENE'] = '<term-to-gene table>'
            $args['TERM2NAME'] = '<term-to-name table>'
            $args['pAdjustMethod'] = '"BH"'
            $args['pvalueCutoff'] = '1'
            $args['qvalueCutoff'] = '1'
            $args['minGSSize'] = $minSize
            $args['maxGSSize'] = $maxSize
        }
        'fgsea_multilevel' {
            $minSize = if ($minSet.Text.Trim()) { $minSet.Text.Trim() } else { '3' }
            $maxSize = if ($maxSet.Text.Trim()) { $maxSet.Text.Trim() } else { '500' }
            $args['pathways'] = '<pathway gene sets>'
            $args['stats'] = '<named ranking vector>'
            $args['minSize'] = $minSize
            $args['maxSize'] = $maxSize
            $args['eps'] = '0'
            $args['scoreType'] = '"std"'
        }
        'topgo_data' {
            $ontology = if ($goOntologyCombo.SelectedItem) { [string]$goOntologyCombo.SelectedItem } else { 'All (BP + MF + CC)' }
            $minSize = if ($minSet.Text.Trim()) { $minSet.Text.Trim() } else { '3' }
            $args['Class'] = '"topGOdata"'
            $args['ontology'] = ConvertTo-RPreviewLiteral $ontology
            $args['allGenes'] = '<binary named gene vector>'
            $args['geneSel'] = 'function(x) x == 1L'
            $args['annot'] = 'topGO::annFUN.gene2GO'
            $args['gene2GO'] = '<gene-to-GO list>'
            $args['nodeSize'] = $minSize
        }
        'topgo_classic_test' { $args['object'] = '<topGOdata>'; $args['algorithm'] = '"classic"'; $args['statistic'] = '"fisher"' }
        'topgo_weight_test' { $args['object'] = '<topGOdata>'; $args['algorithm'] = '"weight01"'; $args['statistic'] = '"fisher"' }
        'topgo_gen_table' {
            $args['object'] = '<topGOdata>'
            $args['secondaryResult'] = '<classic test result>'
            $args['primaryResult'] = '<weight01 test result>'
            $args['topNodes'] = 'length(topGO::usedGO(go_data))'
        }
        'wgcna_good_samples_genes' { $args['datExpr'] = '<samples x genes expression matrix>'; $args['verbose'] = '1' }
        'wgcna_pick_soft_threshold' {
            $networkType = if ($networkTypeCombo.SelectedItem) { ([string]$networkTypeCombo.SelectedItem).ToLowerInvariant() } else { 'signed' }
            $args['data'] = '<samples x genes expression matrix>'
            $args['powerVector'] = 'c(1:10, seq(12, 20, 2))'
            $args['networkType'] = ConvertTo-RPreviewLiteral $networkType
            $args['verbose'] = '1'
        }
        'wgcna_blockwise_modules' {
            $networkType = if ($networkTypeCombo.SelectedItem) { ([string]$networkTypeCombo.SelectedItem).ToLowerInvariant() } else { 'signed' }
            $minModule = if ($minModuleText.Text.Trim()) { $minModuleText.Text.Trim() } else { '20' }
            $softPower = if ($softPowerText.Text.Trim() -and $softPowerText.Text.Trim().ToLowerInvariant() -ne 'auto') { $softPowerText.Text.Trim() } else { '<selected soft-threshold power>' }
            $args['datExpr'] = '<samples x genes expression matrix>'
            $args['power'] = $softPower
            $args['networkType'] = ConvertTo-RPreviewLiteral $networkType
            $args['TOMType'] = ConvertTo-RPreviewLiteral $networkType
            $args['minModuleSize'] = $minModule
            $args['mergeCutHeight'] = '0.25'
            $args['numericLabels'] = 'FALSE'
            $args['pamRespectsDendro'] = 'FALSE'
            $args['maxBlockSize'] = 'ncol(dat_expr)'
            $args['verbose'] = '2'
        }
        'wgcna_module_eigengenes' { $args['expr'] = '<samples x genes expression matrix>'; $args['colors'] = '<module colors>' }
        'cemitool_run' { $args['expr'] = '<genes x samples expression matrix>'; $args['filter'] = 'TRUE'; $args['plot'] = 'FALSE'; $args['verbose'] = 'TRUE' }
        'cemitool_module_genes' { $args['cem'] = '<CEMiTool result>' }
        'genie3_run' {
            $trees = if ($nTreesText.Text.Trim()) { $nTreesText.Text.Trim() } else { '1000' }
            $threads = if ($threadsText.Text.Trim()) { $threadsText.Text.Trim() } else { '4' }
            $args['exprMatr'] = '<genes x samples expression matrix>'
            $args['regulators'] = '<regulator gene vector>'
            $args['nTrees'] = $trees
            $args['nCores'] = $threads
            $args['verbose'] = 'TRUE'
        }
        'genie3_link_list' {
            $maxEdges = if ($maxEdgesText.Text.Trim()) { $maxEdgesText.Text.Trim() } else { '5000' }
            $args['weightMatrix'] = '<GENIE3 weight matrix>'
            $args['reportMax'] = $maxEdges
        }
        'integrated_kegg_pathway' {
            $organism = if ($integratedKeggOrganism.Text.Trim()) { $integratedKeggOrganism.Text.Trim() } else { '<KEGG organism code>' }
            if ($organism -match '^\s*([A-Za-z][A-Za-z0-9]{2,5})\s*[·|]') { $organism = [string]$Matches[1] }
            $args['gene_list'] = '<selected genes from functional enrichment>'
            $args['universe'] = '<tested-gene universe>'
            $args['organism'] = ConvertTo-RPreviewLiteral $organism
            $args['confirmed'] = 'TRUE'
            $args['output_dir'] = '<integrated pathway workspace>'
        }
        'integrated_string_network' {
            $taxid = if ($integratedStringOrganism.Text -match '(?i)taxid\s*:\s*(\d+)') { [string]$Matches[1] } elseif ($integratedStringOrganism.Text.Trim()) { $integratedStringOrganism.Text.Trim() } else { '<taxonomy ID>' }
            $args['gene_list'] = '<selected genes from functional enrichment>'
            $args['taxid'] = $taxid
            $args['network_type'] = ConvertTo-RPreviewLiteral (([string]$integratedStringType.SelectedItem).ToLowerInvariant())
            $args['required_score'] = if ($integratedStringScore.Text.Trim()) { $integratedStringScore.Text.Trim() } else { '700' }
            $args['add_nodes'] = '0'
            $args['identifier_aliases'] = 'NULL'
            $args['expression_edges'] = '<co-expression network edges when available>'
            $args['output_dir'] = '<integrated STRING workspace>'
        }
    }
    return ,$args
}

function Get-PackageEffectiveCallPreview([object]$Definition, [object]$State) {
    if ($null -eq $Definition) { return '' }
    $args = Get-PackagePreviewBaseArguments ([string]$Definition.Key)
    if ($null -eq $args) { $args = [ordered]@{} }
    $example = [string]$Definition.Example | ConvertFrom-Json -ErrorAction Stop
    $validationMessages = New-Object System.Collections.Generic.List[string]
    foreach ($property in @($example.PSObject.Properties)) {
        $name = [string]$property.Name
        if (-not $State.Selected.ContainsKey($name)) { continue }
        $metadata = Get-PackageOptionMetadata ([string]$Definition.Key) $name $property.Value
        $message = ''
        $converted = ConvertFrom-PackageEditorValue $metadata $State.Selected[$name] ([ref]$message)
        if ($message) {
            [void]$validationMessages.Add($message)
            continue
        }
        $args[$name] = ConvertTo-RPreviewLiteral $converted
    }
    $functionName = ([string]$Definition.Function -replace '\s+\(.*$', '')
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('# Effective package/API call preview')
    [void]$lines.Add('# Selected arguments are exact. Pipeline-created objects use <...> placeholders until the run starts.')
    [void]$lines.Add('# The fully resolved call is also written to the run log as THIRD-PARTY FUNCTION CALL.')
    [void]$lines.Add('')
    [void]$lines.Add($functionName + '(')
    $keys = @($args.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $name = [string]$keys[$i]
        $suffix = if ($i -lt ($keys.Count - 1)) { ',' } else { '' }
        [void]$lines.Add('    ' + $name + ' = ' + [string]$args[$name] + $suffix)
    }
    [void]$lines.Add(')')
    if ($validationMessages.Count) {
        [void]$lines.Add('')
        foreach ($message in $validationMessages) { [void]$lines.Add('# Not yet valid: ' + $message) }
    }
    return ($lines -join "`r`n")
}

function Show-AdvancedPackageOptions([string]$Mode) {
    $definitions = @(Get-AdvancedPackageDefinitions $Mode)
    if (-not $definitions.Count) { Show-Error 'No advanced package functions are available for the selected method.'; return }
    $states = @{}
    foreach ($definition in $definitions) { $states[[string]$definition.Key] = New-PackageFunctionEditorState $definition }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = if ($Mode -eq 'combined') { 'Combined guided package options' } else { 'Guided package options' }
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.ClientSize = [System.Drawing.Size]::new(1180, 730)
    $dialog.MinimumSize = [System.Drawing.Size]::new(980, 620)
    $dialog.BackColor = $background
    $dialog.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dialog.Tag = [pscustomobject]@{ Loading = $false }

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = if ($Mode -eq 'combined') {
        'This one dialog contains the selected enrichment and co-expression methods plus the integrated KEGG and STRING calls. Choose a function on the left, check Use to override a documented argument, then choose or enter its value. Every validated option is saved into the same coordinated run.'
    } else {
        'Choose a package function on the left. Check Use to override a documented argument, then choose or enter its value. Unchecked rows retain the workflow/package default. Only listed, validated arguments can be changed.'
    }
    $intro.SetBounds(16, 12, 1148, 46)
    $intro.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $intro.ForeColor = $ink

    $functionList = New-Object System.Windows.Forms.ListBox
    $functionList.SetBounds(16, 70, 272, 590)
    $functionList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $functionList.IntegralHeight = $false
    $functionList.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawVariable
    $functionList.Add_MeasureItem({param($sender,$e) if($e.Index -ge 0){$measure=[System.Windows.Forms.TextRenderer]::MeasureText([string]$sender.Items[$e.Index],$sender.Font,[System.Drawing.Size]::new($sender.ClientSize.Width-12,500),[System.Windows.Forms.TextFormatFlags]::WordBreak);$e.ItemHeight=[Math]::Max(30,$measure.Height+12)}})
    $functionList.Add_DrawItem({param($sender,$e) if($e.Index -lt 0){return};$e.DrawBackground();$rect=[System.Drawing.Rectangle]::new($e.Bounds.X+5,$e.Bounds.Y+5,$e.Bounds.Width-10,$e.Bounds.Height-10);[System.Windows.Forms.TextRenderer]::DrawText($e.Graphics,[string]$sender.Items[$e.Index],$sender.Font,$rect,$sender.ForeColor,[System.Windows.Forms.TextFormatFlags]::WordBreak)})
    foreach ($definition in $definitions) {
        $displayName = [string]$definition.Function
        if ($Mode -eq 'combined') {
            $category = if ([string]$definition.Key -eq 'integrated_kegg_pathway') { 'KEGG pathway' } elseif ([string]$definition.Key -eq 'integrated_string_network') { 'STRING PPI' } elseif ($displayName -match '^(clusterProfiler|fgsea|topGO|methods)::') { 'Enrichment' } else { 'Network' }
            $displayName = "$category | $displayName"
        }
        [void]$functionList.Items.Add($displayName)
    }

    $functionTitle = New-Label '' 306 70 650 29 -Bold
    $functionTitle.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $functionTitle.AutoEllipsis = $false
    $functionTitle.Height = 34
    $functionTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $functionTitle.ForeColor = $greenDark
    $functionTitle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $manualButton = New-Button 'Open offline manual' 984 68 180 32
    $manualButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $protectedLabel = New-Object System.Windows.Forms.Label
    $protectedLabel.SetBounds(306, 108, 858, 58)
    $protectedLabel.AutoEllipsis = $false
    $protectedLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $protectedLabel.BackColor = [System.Drawing.Color]::FromArgb(255, 247, 225)
    $protectedLabel.ForeColor = [System.Drawing.Color]::FromArgb(126, 70, 20)
    $protectedLabel.Padding = New-Object System.Windows.Forms.Padding(8, 5, 8, 5)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.SetBounds(306, 172, 858, 280)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $true
    $grid.RowHeadersVisible = $false
    $grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCells
    $grid.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
    $grid.ColumnHeadersDefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
    $grid.BackgroundColor = $surface
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::CellSelect
    $grid.EditMode = [System.Windows.Forms.DataGridViewEditMode]::EditOnEnter
    $grid.EnableHeadersVisualStyles = $false
    $grid.GridColor = [System.Drawing.Color]::Black
    $grid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::Single
    $grid.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::Single
    $grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9.25, [System.Drawing.FontStyle]::Bold)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $ink
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $surface
    $grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $ink
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $surface
    Set-NeutralGridSelection $grid

    $useColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $useColumn.Name = 'use'
    $useColumn.HeaderText = 'Use'
    $useColumn.Width = 46
    $argumentColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $argumentColumn.Name = 'argument'
    $argumentColumn.HeaderText = 'Package argument'
    $argumentColumn.ReadOnly = $true
    $argumentColumn.Width = 165
    $valueColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $valueColumn.Name = 'value'
    $valueColumn.HeaderText = 'Value'
    $valueColumn.Width = 155
    $typeColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $typeColumn.Name = 'type'
    $typeColumn.HeaderText = 'Expected type'
    $typeColumn.ReadOnly = $true
    $typeColumn.Width = 112
    $descriptionColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $descriptionColumn.Name = 'description'
    $descriptionColumn.HeaderText = 'What it changes'
    $descriptionColumn.ReadOnly = $true
    $descriptionColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $descriptionColumn.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
    [void]$grid.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($useColumn, $argumentColumn, $valueColumn, $typeColumn, $descriptionColumn))

    $callHeader = New-Label 'Effective package/API call' 306 462 220 24 -Bold
    $callHeader.ForeColor = $greenDark
    $callHeader.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

    $callHint = New-Label 'Selected arguments are exact; analysis-created objects use <...> placeholders until execution.' 480 463 592 22
    $callHint.AutoEllipsis = $false
    $callHint.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $callHint.ForeColor = $muted
    $callHint.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $copyCall = New-Button 'Copy' 1090 458 74 28
    $copyCall.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right

    $callPreview = New-Object System.Windows.Forms.RichTextBox
    $callPreview.SetBounds(306, 490, 858, 122)
    $callPreview.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $callPreview.ReadOnly = $true
    $callPreview.WordWrap = $false
    $callPreview.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
    $callPreview.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $callPreview.BackColor = [System.Drawing.Color]::FromArgb(20, 26, 34)
    $callPreview.ForeColor = [System.Drawing.Color]::FromArgb(238, 242, 247)
    $callPreview.Font = New-Object System.Drawing.Font('Consolas', 9.5, [System.Drawing.FontStyle]::Regular)
    $callPreview.DetectUrls = $false

    $selectionSummary = New-Object System.Windows.Forms.Label
    $selectionSummary.SetBounds(306, 620, 858, 40)
    $selectionSummary.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $selectionSummary.BackColor = $blueSoft
    $selectionSummary.Padding = New-Object System.Windows.Forms.Padding(8, 5, 8, 5)

    $resetSelected = New-Button 'Reset selected function' 16 678 170 36
    $resetSelected.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $resetAll = New-Button 'Reset all' 196 678 92 36
    $resetAll.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $cancel = New-Button 'Cancel' 948 678 100 36
    $cancel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $save = New-Button 'Apply options' 1058 678 106 36 -Primary
    $save.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right

    function Save-CurrentPackageEditorState {
        if ([bool]$dialog.Tag.Loading -or [string]::IsNullOrWhiteSpace([string]$grid.Tag)) { return }
        [void]$grid.EndEdit()
        $state = $states[[string]$grid.Tag]
        $selected = @{}
        foreach ($row in $grid.Rows) {
            if (-not [bool]$row.Cells['use'].Value) { continue }
            $metadata = $row.Tag
            $selected[[string]$metadata.Name] = if ([string]$metadata.ValueType -eq 'boolean') { [bool]$row.Cells['value'].Value } else { [string]$row.Cells['value'].Value }
        }
        $state.Selected = $selected
    }

    function Update-PackageSelectionSummary {
        if ([string]::IsNullOrWhiteSpace([string]$grid.Tag)) { $selectionSummary.Text = ''; return }
        Save-CurrentPackageEditorState
        $state = $states[[string]$grid.Tag]
        $selectionSummary.Text = "Selected documented overrides: $($state.Selected.Count). The effective call above updates immediately and the fully resolved call is retained in the run log."
    }

    function Update-PackageCallPreview {
        if ($functionList.SelectedIndex -lt 0 -or [string]::IsNullOrWhiteSpace([string]$grid.Tag)) { $callPreview.Text = ''; return }
        $definition = $definitions[$functionList.SelectedIndex]
        $state = $states[[string]$definition.Key]
        try { $callPreview.Text = Get-PackageEffectiveCallPreview $definition $state }
        catch { $callPreview.Text = "# Effective package/API call preview could not be rendered.`r`n# " + $_.Exception.Message }
        $callPreview.SelectionStart = 0
        $callPreview.SelectionLength = 0
        $callPreview.ScrollToCaret()
    }

    function Load-SelectedPackageFunction {
        if ($functionList.SelectedIndex -lt 0) { return }
        $dialog.Tag.Loading = $true
        try {
            $definition = $definitions[$functionList.SelectedIndex]
            $state = $states[[string]$definition.Key]
            $example = [string]$definition.Example | ConvertFrom-Json -ErrorAction Stop
            $grid.Tag = [string]$definition.Key
            $functionTitle.Text = [string]$definition.Function
            $protectedLabel.Text = 'Pipeline-managed and protected: ' + (@($definition.Protected) -join ', ')
            $grid.Rows.Clear()
            foreach ($property in @($example.PSObject.Properties)) {
                $metadata = Get-PackageOptionMetadata ([string]$definition.Key) ([string]$property.Name) $property.Value
                $rowIndex = $grid.Rows.Add()
                $row = $grid.Rows[$rowIndex]
                $row.Tag = $metadata
                $selected = $state.Selected.ContainsKey([string]$metadata.Name)
                $displayValue = if ($selected) { $state.Selected[[string]$metadata.Name] } else { ConvertTo-PackageOptionDisplayValue $property.Value $metadata.ValueType }
                if ($selected -and @($metadata.Choices).Count -and @($metadata.Choices) -notcontains [string]$displayValue) {
                    $metadata.Choices = @($metadata.Choices) + @([string]$displayValue)
                    $metadata.Description = [string]$metadata.Description + ' The current project value is retained as an additional choice for backward compatibility.'
                }
                $row.Cells['use'].Value = $selected
                $row.Cells['argument'].Value = [string]$metadata.Name
                if ([string]$metadata.ValueType -eq 'boolean') {
                    $booleanCell = New-Object System.Windows.Forms.DataGridViewCheckBoxCell
                    $row.Cells[$valueColumn.Index] = $booleanCell
                    $row.Cells['value'].Value = [bool]$displayValue
                }
                elseif (@($metadata.Choices).Count) {
                    $choiceCell = New-Object System.Windows.Forms.DataGridViewComboBoxCell
                    $choiceCell.DropDownWidth = 500
                    $choiceCell.DisplayStyle = [System.Windows.Forms.DataGridViewComboBoxDisplayStyle]::DropDownButton
                    [void]$choiceCell.Items.AddRange([object[]]@($metadata.Choices))
                    $row.Cells[$valueColumn.Index] = $choiceCell
                    $row.Cells['value'].Value = [string]$displayValue
                }
                else { $row.Cells['value'].Value = [string]$displayValue }
                $row.Cells['type'].Value = ([string]$metadata.ValueType -replace '_', ' ')
                $row.Cells['description'].Value = [string]$metadata.Description
                $row.MinimumHeight = 42
            }
        }
        finally { $dialog.Tag.Loading = $false }
        Update-PackageSelectionSummary
        Update-PackageCallPreview
    }

    $functionList.Add_SelectedIndexChanged({
        if (-not [bool]$dialog.Tag.Loading) { Save-CurrentPackageEditorState }
        Load-SelectedPackageFunction
    })
    $grid.Add_CurrentCellDirtyStateChanged({ if ($grid.IsCurrentCellDirty) { $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null } })
    $grid.Add_CellValueChanged({ if (-not [bool]$dialog.Tag.Loading) { Update-PackageSelectionSummary; Update-PackageCallPreview } })
    $copyCall.Add_Click({
        if (-not [string]::IsNullOrWhiteSpace($callPreview.Text)) {
            try { [System.Windows.Forms.Clipboard]::SetText($callPreview.Text) } catch { Show-Error 'The package/API call preview could not be copied to the clipboard.' }
        }
    })
    $manualButton.Add_Click({
        if ($functionList.SelectedIndex -ge 0) {
            $manualPath = Get-PackageFunctionManualPath ([string]$definitions[$functionList.SelectedIndex].Function)
            if ($manualPath -and (Test-Path -LiteralPath $manualPath -PathType Leaf)) { Start-Process $manualPath; return }
            Show-Error 'The bundled offline package manual is missing. Re-extract the complete application package.'
        }
    })
    $resetSelected.Add_Click({
        if ($functionList.SelectedIndex -lt 0) { return }
        $definition = $definitions[$functionList.SelectedIndex]
        $states[[string]$definition.Key] = [pscustomobject]@{ Selected = @{} }
        Load-SelectedPackageFunction
    })
    $resetAll.Add_Click({
        foreach ($definition in $definitions) { $states[[string]$definition.Key] = [pscustomobject]@{ Selected = @{} } }
        Load-SelectedPackageFunction
    })
    $save.Add_Click({
        Save-CurrentPackageEditorState
        $normalizedByKey = @{}
        for ($index = 0; $index -lt $definitions.Count; $index++) {
            $definition = $definitions[$index]
            $state = $states[[string]$definition.Key]
            $example = [string]$definition.Example | ConvertFrom-Json -ErrorAction Stop
            $combined = [ordered]@{}
            foreach ($property in @($example.PSObject.Properties)) {
                $name = [string]$property.Name
                if (-not $state.Selected.ContainsKey($name)) { continue }
                $metadata = Get-PackageOptionMetadata ([string]$definition.Key) $name $property.Value
                $message = ''
                $converted = ConvertFrom-PackageEditorValue $metadata $state.Selected[$name] ([ref]$message)
                if ($message) { $functionList.SelectedIndex = $index; Show-Error "$($definition.Function): $message"; return }
                $combined[$name] = $converted
            }
            $normalizedByKey[[string]$definition.Key] = if ($combined.Count) { $combined | ConvertTo-Json -Compress -Depth 12 } else { '{}' }
        }
        foreach ($definition in $definitions) {
            $key = [string]$definition.Key
            $normalized = [string]$normalizedByKey[$key]
            if ($normalized -eq '{}') { [void]$script:AdvancedPackageOptions.Remove($key) }
            else { $script:AdvancedPackageOptions[$key] = $normalized }
        }
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $dialog.AcceptButton = $save
    $dialog.CancelButton = $cancel
    $dialog.Controls.AddRange(@(
        $intro, $functionList, $functionTitle, $manualButton, $protectedLabel, $grid,
        $callHeader, $callHint, $copyCall, $callPreview, $selectionSummary,
        $resetSelected, $resetAll, $cancel, $save
    ))
    $functionList.SelectedIndex = 0
    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()
}

function Show-Error([string]$Text) {
    [System.Windows.Forms.MessageBox]::Show($form, $Text, 'Cannot continue', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

function Normalize-NativeOutputTextLocal([string]$Text) {
    if ($null -eq $Text) { return '' }
    $clean = [string]$Text
    $clean = $clean.Replace(([string][char]0), [string]::Empty)
    $clean = [System.Text.RegularExpressions.Regex]::Replace(
        $clean,
        '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]',
        ''
    )
    $clean = $clean -replace "(?<!`r)`n", "`r`n"
    return $clean.TrimEnd()
}

function Invoke-WslCaptureLocal([string[]]$Arguments, [int]$TimeoutMilliseconds = 60000) {
    # Use the same native invocation strategy as RNA Processing.  In particular,
    # test/run WSL as Linux root because the managed environments are installed
    # below /root/.local/share/prok-rnaseq.  A distro whose default user is
    # broken or unconfigured can still be perfectly valid for this application.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $records = @(& wsl.exe @Arguments 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
        $stdoutLines = New-Object System.Collections.Generic.List[string]
        $stderrLines = New-Object System.Collections.Generic.List[string]
        foreach ($record in $records) {
            if ($null -eq $record) { continue }
            $isStandardError = $record -is [System.Management.Automation.ErrorRecord]
            if ($isStandardError) {
                $line = [string]$record.Exception.Message
                if (-not $line) { $line = [string]$record }
            } else { $line = [string]$record }
            $line = Normalize-NativeOutputTextLocal $line
            if (-not $line) { continue }
            if ($isStandardError) { [void]$stderrLines.Add($line) }
            else { [void]$stdoutLines.Add($line) }
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            StandardOutput = Normalize-NativeOutputTextLocal ($stdoutLines -join "`r`n")
            StandardError = Normalize-NativeOutputTextLocal ($stderrLines -join "`r`n")
        }
    }
    catch {
        return [pscustomobject]@{ ExitCode = -1; StandardOutput = ''; StandardError = $_.Exception.Message }
    }
    finally { $ErrorActionPreference = $previousPreference }
}

function Normalize-WslNameLocal([string]$Value) {
    if ($null -eq $Value) { return '' }
    $clean = [string]$Value
    $clean = [System.Text.RegularExpressions.Regex]::Replace($clean, '[\p{Cc}\p{Cf}]', '')
    try { $clean = $clean.Normalize([System.Text.NormalizationForm]::FormKC) } catch { }
    $clean = $clean.Trim()
    if ($clean.StartsWith('*')) { $clean = $clean.Substring(1).Trim() }
    return $clean
}

function Get-WslNameFromProbeOutputLocal([string]$Text) {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in ((Normalize-NativeOutputTextLocal $Text) -split '[\r\n]+')) {
        $name = Normalize-WslNameLocal $line
        if (-not $name) { continue }
        if ($name -match '(?i)^wsl(?:\.exe)?\s*:') { continue }
        if ($name -match '(?i)localhost prox|not mirrored into WSL|does not support localhost proxies|there is no distribution|error code|windows subsystem') { continue }
        [void]$names.Add($name)
    }
    if ($names.Count -eq 0) { return '' }
    return [string]$names[$names.Count - 1]
}

function Test-WslDistroRunnableLocal([string]$Distro) {
    $name = Normalize-WslNameLocal $Distro
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    $probe = Invoke-WslCaptureLocal @('-d', $name, '-u', 'root', '--', '/bin/echo', 'BACTERIAL_RNA_WSL_READY') 60000
    return ($probe.ExitCode -eq 0 -and $probe.StandardOutput -match 'BACTERIAL_RNA_WSL_READY')
}

function Test-WslDistroCompatibleLocal([string]$Distro) {
    if (-not (Test-WslDistroRunnableLocal $Distro)) { return $false }
    $probe = Invoke-WslCaptureLocal @('-d', $Distro, '-u', 'root', '--', '/bin/cat', '/etc/os-release') 60000
    if ($probe.ExitCode -ne 0) { return $false }
    return ([string]$probe.StandardOutput) -match '(?im)^ID=(ubuntu|debian)$|^ID="?(ubuntu|debian)"?$'
}

function Test-WslDistroHasDownstreamEnvironmentLocal([string]$Distro) {
    $name = Normalize-WslNameLocal $Distro
    if (-not $name -or -not (Test-WslDistroRunnableLocal $name)) { return $false }
    $command = 'if [ -x /root/.local/share/prok-rnaseq/miniforge3/envs/prok-rnaseq-downstream/bin/Rscript ] && [ -x /root/.local/share/prok-rnaseq/miniforge3/envs/prok-rnaseq-downstream/bin/python ]; then printf BACTERIAL_RNA_DOWNSTREAM_READY; fi'
    $probe = Invoke-WslCaptureLocal @('-d', $name, '-u', 'root', '--', 'bash', '-lc', $command) 60000
    return ($probe.ExitCode -eq 0 -and $probe.StandardOutput -match 'BACTERIAL_RNA_DOWNSTREAM_READY')
}

function Test-WslDistroHasCoreRnaEnvironmentLocal([string]$Distro) {
    $name = Normalize-WslNameLocal $Distro
    if (-not $name -or -not (Test-WslDistroRunnableLocal $name)) { return $false }
    $command = 'if [ -x /root/.local/share/prok-rnaseq/miniforge3/envs/prok-rnaseq/bin/python ]; then printf BACTERIAL_RNA_CORE_READY; fi'
    $probe = Invoke-WslCaptureLocal @('-d', $name, '-u', 'root', '--', 'bash', '-lc', $command) 60000
    return ($probe.ExitCode -eq 0 -and $probe.StandardOutput -match 'BACTERIAL_RNA_CORE_READY')
}

function Get-WslRegistryDistroNamesLocal {
    $names = New-Object System.Collections.Generic.List[string]
    try {
        $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        if (-not (Test-Path -LiteralPath $root)) { return @() }
        $rootProperties = Get-ItemProperty -LiteralPath $root -ErrorAction SilentlyContinue
        $defaultId = [string]$rootProperties.DefaultDistribution
        if ($defaultId) {
            $defaultPath = Join-Path $root $defaultId
            if (Test-Path -LiteralPath $defaultPath) {
                $defaultName = Normalize-WslNameLocal ([string](Get-ItemProperty -LiteralPath $defaultPath -ErrorAction SilentlyContinue).DistributionName)
                if ($defaultName) { [void]$names.Add($defaultName) }
            }
        }
        foreach ($item in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $name = Normalize-WslNameLocal ([string](Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue).DistributionName)
            if ($name) { [void]$names.Add($name) }
        }
    } catch { }
    return @($names)
}

function Get-WslListedDistroNamesLocal {
    # Preserve the byte-level UTF-16 handling from RNA Processing. wsl.exe
    # commonly writes --list --quiet as UTF-16LE when redirected.
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process -FilePath 'wsl.exe' -ArgumentList @('--list', '--quiet') -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if ($process.ExitCode -ne 0) { return @() }
        $bytes = [System.IO.File]::ReadAllBytes($stdoutPath)
        if ($bytes.Length -eq 0) { return @() }
        $isUnicode = $false
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $isUnicode = $true }
        elseif ($bytes.Length -ge 4 -and ($bytes[1] -eq 0 -or $bytes[3] -eq 0)) { $isUnicode = $true }
        if ($isUnicode) {
            if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $output = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
            else { $output = [System.Text.Encoding]::Unicode.GetString($bytes) }
        } else {
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $output = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) }
            else { $output = [System.Text.Encoding]::UTF8.GetString($bytes) }
        }
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($line in ([string]$output -split '[\r\n]+')) {
            $name = Normalize-WslNameLocal $line
            if (-not $name) { continue }
            if ($name -match '(?i)there is no distribution|error code|windows subsystem') { continue }
            [void]$names.Add($name)
        }
        return @($names)
    } catch { return @() }
    finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-WslDistroLocal {
    $suiteRoot = Split-Path -Parent (Split-Path -Parent $script:ModuleRoot)
    $marker = Join-Path $suiteRoot 'App\environment\.wsl_distro'
    $candidates = New-Object System.Collections.Generic.List[string]

    # The RNA Processing marker is the first hint, but never blindly trusted.
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        try {
            $saved = Normalize-WslNameLocal (Get-Content -LiteralPath $marker -Raw -ErrorAction Stop)
            if ($saved) { [void]$candidates.Add($saved) }
        } catch { }
    }

    # Ask the same default-root probe used by RNA Processing.  This is robust to
    # a distro whose default non-root account is unavailable.
    $defaultProbe = Invoke-WslCaptureLocal @('-u', 'root', '--', '/usr/bin/printenv', 'WSL_DISTRO_NAME') 60000
    if ($defaultProbe.ExitCode -eq 0) {
        $defaultName = Get-WslNameFromProbeOutputLocal $defaultProbe.StandardOutput
        if ($defaultName) { [void]$candidates.Add($defaultName) }
    }

    foreach ($value in @(Get-WslRegistryDistroNamesLocal)) { [void]$candidates.Add([string]$value) }
    foreach ($value in @(Get-WslListedDistroNamesLocal)) { [void]$candidates.Add([string]$value) }
    foreach ($known in @('Ubuntu-24.04','Ubuntu','Ubuntu-22.04','Debian','OpDetect-Ubuntu')) { [void]$candidates.Add($known) }

    $seen = @{}
    $normalized = New-Object System.Collections.Generic.List[string]
    foreach ($candidateValue in $candidates) {
        $candidate = Normalize-WslNameLocal ([string]$candidateValue)
        if (-not $candidate) { continue }
        if ($candidate -match '(?i)^docker-desktop(?:-data)?$|^rancher-desktop$|^podman-machine') { continue }
        $key = $candidate.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$normalized.Add($candidate)
    }

    # For DE/GO/Network, the best distro is the one where their environment is
    # already installed.  This also accepts a historically named OpDetect-Ubuntu
    # if that is where the working shared downstream environment actually lives.
    foreach ($candidate in $normalized) {
        if (Test-WslDistroHasDownstreamEnvironmentLocal $candidate) { return [string]$candidate }
    }

    # Otherwise stay with RNA Processing's managed environment when possible.
    foreach ($candidate in $normalized) {
        if (Test-WslDistroHasCoreRnaEnvironmentLocal $candidate) { return [string]$candidate }
    }

    # Installation/repair fallback: any truly runnable Ubuntu/Debian distro.
    foreach ($candidate in $normalized) {
        if (Test-WslDistroCompatibleLocal $candidate) { return [string]$candidate }
    }
    return ''
}

function Convert-ToWslPathLocal([string]$WindowsPath, [string]$Distro) {
    if ([string]::IsNullOrWhiteSpace($WindowsPath)) { throw 'A Windows path was not provided.' }

    # Convert ordinary Windows drive paths directly. This avoids differences in
    # wslpath availability and command-line parsing across WSL distributions.
    $expanded = [Environment]::ExpandEnvironmentVariables($WindowsPath.Trim())
    try { $fullPath = [System.IO.Path]::GetFullPath($expanded) }
    catch { $fullPath = $expanded }

    if ($fullPath -match '^(?<drive>[A-Za-z]):[\\/](?<tail>.*)$') {
        $drive = $Matches.drive.ToLowerInvariant()
        $tail = $Matches.tail -replace '\\', '/'
        if ([string]::IsNullOrEmpty($tail)) { return "/mnt/$drive" }
        return "/mnt/$drive/$tail"
    }

    # Also accept paths copied from \\wsl$ or \\wsl.localhost Explorer shares.
    if ($fullPath -match '^\\\\(?:wsl\$|wsl\.localhost)\\(?<share>[^\\]+)\\(?<tail>.*)$') {
        $share = $Matches.share
        if ($Distro -and $share -and ($share -ine $Distro)) {
            throw "This WSL path belongs to '$share', but the selected distribution is '$Distro'."
        }
        $tail = $Matches.tail -replace '\\', '/'
        return "/$tail"
    }

    if ($fullPath.StartsWith('/')) { return $fullPath }
    throw "Could not translate this Windows path for WSL:`r`n$WindowsPath"
}


function Convert-ToPowerShellLiteral([string]$Value) {
    if ($null -eq $Value) { return "''" }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function New-DownstreamLogPath([string]$Purpose) {
    if ([string]::IsNullOrWhiteSpace($Purpose)) { $Purpose = 'job' }
    $safePurpose = ($Purpose -replace '[^A-Za-z0-9.-]+', ' ').Trim()
    if (-not $safePurpose) { $safePurpose = 'job' }
    $stamp = [DateTime]::Now.ToString('yyyyMMdd_HHmmss')

    $fallbackRoot = if ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'Bacterial RNA Analysis\Logs'
    } else {
        Join-Path ([System.IO.Path]::GetTempPath()) 'Bacterial RNA Analysis Logs'
    }
    foreach ($candidate in @($script:PersistentLogDir, $fallbackRoot)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            [void][System.IO.Directory]::CreateDirectory($candidate)
            if (Test-Path -LiteralPath $candidate -PathType Container) {
                return Join-Path $candidate ("Downstream {0} {1}.log" -f $safePurpose, $stamp)
            }
        } catch { }
    }
    throw 'No writable folder was available for the downstream run log.'
}

function Remove-JobWrapper {
    if ($script:JobWrapperPath -and (Test-Path -LiteralPath $script:JobWrapperPath -PathType Leaf)) {
        try { Remove-Item -LiteralPath $script:JobWrapperPath -Force -ErrorAction Stop } catch { }
    }
    $script:JobWrapperPath = ''
}

function Quote-Bash([string]$Value) {
    if ($Value.Contains("'")) { throw "Paths containing an apostrophe are not supported by this WSL launcher: $Value" }
    return "'$Value'"
}

function Quote-BashSafe([string]$Value) {
    if ($null -eq $Value) { return "''" }
    $sq = [string][char]39
    $dq = [string][char]34
    $replacement = $sq + $dq + $sq + $dq + $sq
    return $sq + ([string]$Value).Replace($sq, $replacement) + $sq
}

function Write-JsonConfig([hashtable]$Config, [string]$Path) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, ($Config | ConvertTo-Json -Depth 8), $encoding)
}

function Test-RequiredPath([System.Windows.Forms.TextBox]$Box, [string]$Label, [switch]$Folder) {
    $value = $Box.Text.Trim()
    if (-not $value) { Show-Error "$Label is required."; return $false }
    if ($Folder) {
        try { [void][System.IO.Directory]::CreateDirectory($value) } catch { Show-Error "$Label could not be created or opened.`r`n`r`n$($_.Exception.Message)"; return $false }
        return $true
    }
    if (-not (Test-Path -LiteralPath $value -PathType Leaf)) { Show-Error "$Label was not found:`r`n$value"; return $false }
    return $true
}

function Get-TableHeaders([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $line = Get-Content -LiteralPath $Path -TotalCount 1
    if ($null -eq $line) { return @() }
    $delimiter = if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -eq '.csv') { ',' } else { "`t" }
    return @(([string]$line).Split([string[]]@($delimiter), [System.StringSplitOptions]::None) | ForEach-Object { $_.Trim('"') })
}

function Read-MetadataRows([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -eq '.csv') { return @(Import-Csv -LiteralPath $Path) }
        return @(Import-Csv -LiteralPath $Path -Delimiter "`t")
    } catch { return @() }
}

function Fill-Combo([System.Windows.Forms.ComboBox]$Combo, [object[]]$Items, [string]$Preferred = '') {
    # Normalize all inputs to a real array. This matters because PowerShell unwraps
    # a one-item pipeline result into a scalar object, while scan-populated ComboBox
    # handlers expect collection semantics.
    $safeItems = @($Items | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    $Combo.BeginUpdate()
    try {
        $Combo.Items.Clear()
        if ($safeItems.Count -gt 0) { [void]$Combo.Items.AddRange([object[]]$safeItems) }
        if ($Preferred -and $Combo.Items.Contains([string]$Preferred)) { $Combo.SelectedItem = [string]$Preferred }
        elseif ($Combo.Items.Count -gt 0) { $Combo.SelectedIndex = 0 }
    } finally {
        $Combo.EndUpdate()
    }
}

function Remove-TerminalControlSequences([string]$Text) {
    if ($null -eq $Text) { return '' }
    # Strip ANSI colour/cursor sequences, backspaces and other terminal-only
    # control characters before displaying or reporting Conda/WSL output.
    $ansiPattern = ([regex]::Escape([string][char]27)) + '\[[0-?]*[ -/]*[@-~]'
    $clean = [regex]::Replace([string]$Text, $ansiPattern, '')
    $clean = $clean.Replace("`b", '')
    $clean = [regex]::Replace($clean, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    return $clean
}

function Read-SharedLogTailText([string]$Path, [int64]$MaximumBytes = 524288) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = $null
    $reader = $null
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        $start = [Math]::Max([int64]0, ($stream.Length - $MaximumBytes))
        [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        $text = $reader.ReadToEnd()
        if ($start -gt 0) {
            $firstNewline = $text.IndexOf("`n")
            if ($firstNewline -ge 0 -and $firstNewline + 1 -lt $text.Length) {
                $text = $text.Substring($firstNewline + 1)
            }
            return "[Live console is limited to the most recent 512 KiB. Open the run log for the complete audit trail.]`r`n" + $text
        }
        return $text
    }
    catch { return '' }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}

function Get-SharedLogTail([string]$Path, [int]$Count = 35) {
    $text = Remove-TerminalControlSequences (Read-SharedLogTailText $Path)
    if (-not $text) { return @() }
    $lines = @($text -split "`r?`n")
    if ($lines.Count -le $Count) { return $lines }
    return @($lines[($lines.Count - $Count)..($lines.Count - 1)])
}

function Append-Log([string]$Text) {
    if (-not $Text) { return }
    $Text = Remove-TerminalControlSequences $Text
    if (-not $Text) { return }
    $logBox.AppendText($Text)
    if (-not $Text.EndsWith("`r`n")) { $logBox.AppendText("`r`n") }
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Refresh-Log {
    if (-not $script:JobLogPath -or -not (Test-Path -LiteralPath $script:JobLogPath -PathType Leaf)) { return }
    try {
        $info = Get-Item -LiteralPath $script:JobLogPath
        if ($info.Length -ne $script:JobLogLength) {
            $text = Remove-TerminalControlSequences (Read-SharedLogTailText $script:JobLogPath)
            $logBox.Text = ($text -replace "(?<!`r)`n", "`r`n")
            $logBox.SelectionStart = $logBox.TextLength
            $logBox.ScrollToCaret()
            $script:JobLogLength = $info.Length
        }
    } catch { }
}

function Reset-ProgressDisplay {
    if ($progressBar) {
        $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
        $progressBar.Value = 0
    }
    if ($detailProgressBar) {
        $detailProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
        $detailProgressBar.Value = 0
    }
    if ($detailProgressLabel) { $detailProgressLabel.Text = ''; $detailProgressLabel.Tag = '' }
    $script:JobProgressStamp = [DateTime]::MinValue
    $script:LastProgressState = $null
    $script:LastProgressWriteUtc = [DateTime]::MinValue
}

function Refresh-ProgressDisplay {
    if (-not $script:JobProgressPath -or -not (Test-Path -LiteralPath $script:JobProgressPath -PathType Leaf)) { return }
    try {
        $info = Get-Item -LiteralPath $script:JobProgressPath -ErrorAction Stop
        if ($info.LastWriteTimeUtc -ne $script:JobProgressStamp -or $null -eq $script:LastProgressState) {
            $script:LastProgressState = Get-Content -LiteralPath $script:JobProgressPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:JobProgressStamp = $info.LastWriteTimeUtc
            $script:LastProgressWriteUtc = $info.LastWriteTimeUtc
        }
        $state = $script:LastProgressState
        if ($null -eq $state) { return }

        $overall = 0
        if ($null -ne $state.overall_percent) { $overall = [Math]::Max(0, [Math]::Min(100, [int][Math]::Round([double]$state.overall_percent))) }
        $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
        $progressBar.Value = $overall
        $phase = [string]$state.phase
        if (-not $phase) { $phase = "Running $($script:JobMode)" }
        # Use ASCII separators so Windows PowerShell 5.1 never displays UTF-8
        # punctuation as mojibake (for example, 'Â·').
        $statusLabel.Text = "$phase | $overall% overall"
        if ($script:ParameterToolTip) { $script:ParameterToolTip.SetToolTip($statusLabel, $statusLabel.Text) }

        if ($detailProgressBar -and $detailProgressBar.Visible) {
            $current = 0L; $total = 0L
            if ($null -ne $state.current) { $current = [int64]$state.current }
            if ($null -ne $state.total) { $total = [int64]$state.total }
            $phasePercent = 0
            if ($null -ne $state.phase_percent) { $phasePercent = [Math]::Max(0, [Math]::Min(100, [int][Math]::Round([double]$state.phase_percent))) }
            if ($total -gt 0) {
                $detailProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
                $detailProgressBar.Value = $phasePercent
            } elseif ($script:JobProcess -and -not $script:JobProcess.HasExited -and $overall -lt 100) {
                $detailProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
                $detailProgressBar.MarqueeAnimationSpeed = 30
            } else {
                $detailProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
                $detailProgressBar.Value = $phasePercent
            }

            $detail = [string]$state.detail
            if (-not $detail) {
                $unit = [string]$state.unit
                if ($total -gt 0) { $detail = ('{0:N0}/{1:N0} {2}' -f $current, $total, $unit) }
                elseif ($current -gt 0) { $detail = ('{0:N0} {1}' -f $current, $unit) }
                else { $detail = $phase }
            }

            # If the scientific process is still alive but the progress state has
            # not changed, show the waiting time in the same label instead of
            # leaving a frozen-looking number. The downloader now retries after a
            # short socket inactivity timeout, so this should normally remain brief.
            if ($script:JobProcess -and -not $script:JobProcess.HasExited -and $script:LastProgressWriteUtc -gt [DateTime]::MinValue) {
                $idleSeconds = [int][Math]::Floor(([DateTime]::UtcNow - $script:LastProgressWriteUtc).TotalSeconds)
                if ($idleSeconds -ge 5) {
                    if ($idleSeconds -ge 45) {
                        $detail = "$detail | network idle ${idleSeconds}s; automatic reconnect active"
                    } else {
                        $detail = "$detail | waiting ${idleSeconds}s for next data"
                    }
                }
            }
            $detailProgressLabel.Text = $detail
            $detailProgressLabel.Tag = $detail
            if ($script:ParameterToolTip) { $script:ParameterToolTip.SetToolTip($detailProgressLabel, $detail) }
        }
    } catch { }
}

function Set-JobUi([bool]$Running, [string]$Status) {
    $statusLabel.Text = $Status
    if ($script:ParameterToolTip) { $script:ParameterToolTip.SetToolTip($statusLabel, $Status) }
    if ($Running -and $script:JobMode -in @('enrichment', 'network', 'combined')) {
        $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
        if ($progressBar.Value -lt 1) { $progressBar.Value = 1 }
    } else {
        $progressBar.Style = if ($Running) { [System.Windows.Forms.ProgressBarStyle]::Marquee } else { [System.Windows.Forms.ProgressBarStyle]::Blocks }
        $progressBar.MarqueeAnimationSpeed = if ($Running) { 35 } else { 0 }
    }
    $stopButton.Enabled = $Running
    # Functional controls are not constructed on the DE page. Even putting an
    # unset variable into an array raises an error under the suite's StrictMode.
    $buttons = @($runDEButton, $deAdvancedPackageButton, $installEnvironmentButton, $checkEnvironmentButton, $openDEStudioButton)
    if ($script:InitialTab -ne 'de') {
        $buttons += @($runEnrichmentButton, $runNetworkButton, $runKeggMapButton, $enrichAdvancedPackageButton, $networkAdvancedPackageButton, $openEnrichmentStudioButton, $openNetworkStudioButton)
    }
    foreach ($button in $buttons) {
        if ($button) { $button.Enabled = -not $Running }
    }
}

function Refresh-DEPlots { }
function Refresh-EnrichmentPlots { }
function Refresh-NetworkPlots { }

function Complete-Job {
    Refresh-Log
    Refresh-ProgressDisplay
    $exitCode = 1
    if ($script:JobProcess) {
        try {
            $script:JobProcess.WaitForExit()
            $exitCode = [int]$script:JobProcess.ExitCode
        } catch {
            $exitCode = 1
            if ($script:JobLogPath) {
                try {
                    Add-Content -LiteralPath $script:JobLogPath -Value ("Windows launcher error while reading the process exit code: " + $_.Exception.Message) -Encoding UTF8
                } catch { }
            }
        }
    }
    if ($script:JobTimer) { $script:JobTimer.Stop() }
    Refresh-Log

    # A check exit code of 2 means the Linux distribution started correctly
    # but a required environment component is not installed. Report this as a
    # setup status, not as a failed analysis job.
    if ($script:JobMode -eq 'check' -and $exitCode -eq 2) {
        Set-JobUi $false 'Installation required'
        $details = ''
        if ($script:JobLogPath -and (Test-Path -LiteralPath $script:JobLogPath -PathType Leaf)) {
            try {
                $tail = @(Get-SharedLogTail $script:JobLogPath 35)
                if ($tail.Count -gt 0) { $details = ($tail -join "`r`n") }
            } catch { }
        }
        if ($details -match 'MISSING: downstream conda environment') {
            $statusMessage = 'WSL and Miniforge were detected, but the shared downstream analysis environment is not installed yet. Click Install or update to create it. The same environment supports Differential Expression and the complete combined functional-analysis workflow.'
        }
        elseif ($details -match 'MISSING: Miniforge') {
            $statusMessage = 'WSL was detected, but Miniforge was not found in either supported location. Use Install or update to prepare the shared downstream analysis environment.'
        }
        else {
            $statusMessage = 'The downstream environment check completed and found missing setup components. Click Install or update, then run Check environment again.'
        }
        Append-Log $statusMessage
        Show-Message $statusMessage 'Downstream environment setup required'
        Remove-JobWrapper
        $script:JobProcess = $null
        return
    }

    if ($exitCode -eq 0) {
        if ($script:JobMode -in @('enrichment','network','combined')) { $progressBar.Value = 100; $detailProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks; $detailProgressBar.Value = 100 }
        Set-JobUi $false 'Completed successfully'
        Append-Log "Completed: $($script:JobMode)"
        switch ($script:JobMode) {
            'de' { $script:LastDEOutput = $script:JobOutput; Save-SharedAnalysisOutput 'de' $script:JobOutput; Refresh-DEPlots }
            'enrichment' { $script:LastEnrichmentOutput = $script:JobOutput; Save-SharedAnalysisOutput 'enrichment' $script:JobOutput; Refresh-EnrichmentPlots }
            'network' { $script:LastNetworkOutput = $script:JobOutput; Save-SharedAnalysisOutput 'network' $script:JobOutput; Refresh-NetworkPlots }
            'combined' {
                $script:LastFunctionalOutput = $script:JobOutput
                $script:LastEnrichmentOutput = $script:JobOutput
                $script:LastNetworkOutput = $script:JobOutput
                Save-SharedAnalysisOutput 'combined' $script:JobOutput
                Save-SharedAnalysisOutput 'enrichment' $script:JobOutput
                Save-SharedAnalysisOutput 'network' $script:JobOutput
                Refresh-EnrichmentPlots
                Refresh-NetworkPlots
            }
            'pathway_map' {
                $script:LastFunctionalOutput = $script:JobOutput
                $script:LastEnrichmentOutput = $script:JobOutput
                Save-SharedAnalysisOutput 'combined' $script:JobOutput
                Save-SharedAnalysisOutput 'enrichment' $script:JobOutput
            }
            'gene-range' {
                $latest = Get-ChildItem -LiteralPath $script:JobOutput -Filter 'gene_range_*.html' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($latest) { Start-Process -FilePath $latest.FullName | Out-Null }
            }
            'circular' {
                Refresh-DEPlots
                $plotPath = Join-Path $script:JobOutput 'Circular genome interactive.html'
                if (Test-Path -LiteralPath $plotPath -PathType Leaf) { Start-Process -FilePath $plotPath | Out-Null }
            }
            'install' { }
            'check' { }
        }
        if ($script:JobMode -in @('de','enrichment','network','combined','pathway_map')) {
            Show-AnalysisSuccessDialog $script:JobMode $script:JobOutput
        }
    } else {
        Set-JobUi $false "Failed with exit code $exitCode"
        $logExists = $script:JobLogPath -and (Test-Path -LiteralPath $script:JobLogPath -PathType Leaf)
        if (-not $logExists -and $script:JobLogPath) {
            try {
                $parent = Split-Path -Parent $script:JobLogPath
                if ($parent) { [void][System.IO.Directory]::CreateDirectory($parent) }
                [System.IO.File]::WriteAllText(
                    $script:JobLogPath,
                    ("[{0}] The Windows launcher ended before a WSL log was created.`r`nExit code: {1}`r`n" -f [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'), $exitCode),
                    (New-Object System.Text.UTF8Encoding($false))
                )
                $logExists = $true
            } catch { }
        }

        $details = ''
        if ($logExists) {
            try {
                $tail = @(Get-SharedLogTail $script:JobLogPath 35)
                if ($tail.Count -gt 0) { $details = ($tail -join "`r`n") }
            } catch { }
            Append-Log "The job failed. Run log: $($script:JobLogPath)"
        } else {
            Append-Log 'The job failed before a run log could be created.'
        }

        $message = "The $($script:JobMode) job failed with exit code $exitCode."
        if ($script:JobMode -eq 'install') {
            $message += "`r`nThe installer is resumable. Click Install or update again after correcting the reported problem; already downloaded Conda packages will be reused."
        }
        if ($logExists) { $message += "`r`n`r`nRun log:`r`n$($script:JobLogPath)" }
        else { $message += "`r`n`r`nNo log file was created. The failure occurred in the Windows launcher before WSL produced output." }
        if ($details) { $message += "`r`n`r`nLast messages:`r`n$details" }
        Show-Error $message
    }

    Remove-JobWrapper
    $script:JobProcess = $null
}

function Stop-DownstreamJob([string]$Reason = 'Stop requested by user') {
    if (-not $script:JobProcess -or $script:JobProcess.HasExited) {
        Remove-JobWrapper
        $script:JobProcess = $null
        return $true
    }

    $script:JobStopRequested = $true
    try { Set-JobUi $true 'Stopping safely...' } catch { }
    try { $stopButton.Enabled = $false } catch { }
    Append-Log "$Reason. Stopping the complete Linux analysis process tree and preserving completed outputs..."

    # First terminate the Linux process group created by run_supervised_job.sh.
    # Killing only the Windows PowerShell/wsl.exe wrapper leaves conda/R/Python
    # alive inside WSL, which can keep result folders locked after the GUI closes.
    if ($script:JobDistro -and $script:JobToken) {
        try {
            $stopScriptWsl = Convert-ToWslPathLocal $script:StopSupervisorScript $script:JobDistro
            $savedPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { & wsl.exe -d $script:JobDistro -u root -- /bin/bash $stopScriptWsl $script:JobToken 2>&1 | Out-Null } finally { $ErrorActionPreference = $savedPreference }
        } catch {
            Append-Log ("Linux stop warning: " + $_.Exception.Message)
        }
    }

    # Give the managed Windows wrapper time to observe the Linux exit. If it is
    # still alive, terminate the whole Windows wrapper tree as a final cleanup.
    try {
        for ($i = 0; $i -lt 40 -and $script:JobProcess -and -not $script:JobProcess.HasExited; $i++) {
            Start-Sleep -Milliseconds 100
            [System.Windows.Forms.Application]::DoEvents()
        }
    } catch { }
    if ($script:JobProcess -and -not $script:JobProcess.HasExited) {
        try { & taskkill.exe /PID $script:JobProcess.Id /T /F 2>$null | Out-Null } catch { }
        try { $script:JobProcess.WaitForExit(3000) | Out-Null } catch { }
    }

    if ($script:JobTimer) { try { $script:JobTimer.Stop() } catch { } }
    Refresh-Log
    Remove-JobWrapper
    $script:JobProcess = $null
    $script:JobToken = ''
    $script:JobDistro = ''
    $script:JobLinuxPidFile = ''
    try { Set-JobUi $false 'Stopped safely' } catch { }
    Append-Log 'Stopped safely. No managed analysis process is left running in WSL; the result folder can now be moved or deleted.'
    return $true
}

function Start-BashJob([string]$Mode, [string]$BashCommand, [string]$LogPath, [string]$OutputDirectory = '') {
    if ($script:JobProcess -and -not $script:JobProcess.HasExited) { Show-Error 'Another analysis job is already running.'; return }
    $distro = Get-WslDistroLocal
    if (-not $distro) { Show-Error 'No runnable WSL2 Linux distribution was found. Open Environment > Install or update, or verify that an installed Ubuntu WSL2 distribution can start.'; return }

    if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = New-DownstreamLogPath $Mode }
    $script:JobToken = [Guid]::NewGuid().ToString('N')
    $script:JobDistro = $distro
    $script:JobLinuxPidFile = "/tmp/bra_job_$($script:JobToken).pid"
    $script:JobStopRequested = $false
    try {
        $logParent = Split-Path -Parent $LogPath
        if ($logParent) { [void][System.IO.Directory]::CreateDirectory($logParent) }
        $header = @(
            "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] Starting downstream job"
            "Mode: $Mode"
            "WSL distribution (technical identifier): $distro"
            "Linux account: root (shared with RNA Processing)"
            "Bash command: $BashCommand"
            "Managed job token: $($script:JobToken)"
            ''
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($LogPath, $header, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Show-Error ("The run log could not be created.`r`n`r`nRequested path:`r`n$LogPath`r`n`r`n" + $_.Exception.Message)
        return
    }

    $script:JobLogPath = $LogPath
    $script:JobLogLength = 0
    $script:JobMode = $Mode
    $script:JobOutput = $OutputDirectory
    $script:JobProgressPath = ''
    if ($OutputDirectory -and $Mode -in @('enrichment', 'network', 'combined')) {
        $script:JobProgressPath = Join-Path (Join-Path $OutputDirectory 'Intermediate files') ("{0} progress.json" -f $Mode)
        try { Remove-Item -LiteralPath $script:JobProgressPath -Force -ErrorAction SilentlyContinue } catch { }
        Reset-ProgressDisplay
    }
    Remove-JobWrapper

    # Launch WSL through a small Windows PowerShell wrapper and stream stdout and
    # stderr into a real Windows file. The displayed log path therefore exists
    # before WSL starts and remains useful even when WSL itself cannot launch.
    $wrapperPath = Join-Path ([System.IO.Path]::GetTempPath()) ("bra_downstream_{0}.ps1" -f ([Guid]::NewGuid().ToString('N')))
    $distroLiteral = Convert-ToPowerShellLiteral $distro
    try {
        $supervisorWsl = Convert-ToWslPathLocal $script:SupervisorScript $distro
        # Do not feed a shell-quoted command through another `bash -lc`. That
        # double interpretation caused the install command to break on suite
        # paths containing spaces ("unexpected EOF while looking for matching
        # quote"). Transport the exact UTF-8 command as base64 instead.
        $commandBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$BashCommand)
        $commandPayload = [Convert]::ToBase64String($commandBytes)
    } catch {
        try { Add-Content -LiteralPath $LogPath -Value ("Could not prepare managed Linux process supervision: " + $_.Exception.Message) -Encoding UTF8 } catch { }
        Show-Error ("The managed WSL launcher could not be prepared.`r`n`r`n" + $_.Exception.Message)
        return
    }
    $supervisorLiteral = Convert-ToPowerShellLiteral $supervisorWsl
    $tokenLiteral = Convert-ToPowerShellLiteral $script:JobToken
    $payloadLiteral = Convert-ToPowerShellLiteral $commandPayload
    $logLiteral = Convert-ToPowerShellLiteral $LogPath
    $wrapperText = @"
# Native applications such as conda, R and Python legitimately write progress,
# warnings and package messages to stderr. With ErrorActionPreference=Stop,
# Windows PowerShell 5.1 can convert one of those redirected stderr records
# into a terminating System.Management.Automation.RemoteException even when
# the Linux command is healthy. Preserve every line in the log and use the
# real WSL exit code as the sole success/failure signal.
`$ErrorActionPreference = 'Stop'
`$distro = $distroLiteral
`$supervisor = $supervisorLiteral
`$jobToken = $tokenLiteral
`$commandPayload = $payloadLiteral
`$logPath = $logLiteral
`$stream = `$null
`$writer = `$null
function Clean-TerminalLine([string]`$value) {
    if (`$null -eq `$value) { return '' }
    `$ansiPattern = ([regex]::Escape([string][char]27)) + '\[[0-?]*[ -/]*[@-~]'
    `$clean = [regex]::Replace([string]`$value, `$ansiPattern, '')
    `$clean = `$clean.Replace("``b", '')
    `$clean = [regex]::Replace(`$clean, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    `$clean = `$clean.TrimEnd("``r")
    # Windows PowerShell 5.1 can stringify a harmless native stderr record as
    # this type name even when WSL later exits successfully. It contains no
    # diagnostic information, so omit it while preserving the real messages.
    if (`$clean -eq 'System.Management.Automation.RemoteException') { return '' }
    return `$clean
}
try {
    # Keep one append stream open and explicitly allow the GUI to read it.
    # This removes the Add-Content/Get-Content race that previously aborted a
    # healthy Conda download with "file is being used by another process".
    `$share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    `$stream = New-Object System.IO.FileStream(`$logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, `$share)
    `$encoding = New-Object System.Text.UTF8Encoding(`$false)
    `$writer = New-Object System.IO.StreamWriter(`$stream, `$encoding)
    `$writer.AutoFlush = `$true
    # Temporarily allow native stderr records through the pipeline. In Windows
    # PowerShell 5.1, ErrorActionPreference=Stop can promote a harmless stderr
    # warning into a terminating RemoteException before LASTEXITCODE is read.
    `$savedPreference = `$ErrorActionPreference
    `$ErrorActionPreference = 'Continue'
    try {
        # Pass each argument directly to wsl.exe. The supervisor decodes the
        # payload and invokes exactly one bash -lc, so no layer has to parse a
        # command that already contains shell quotes.
        & wsl.exe -d `$distro -u root -- bash `$supervisor `$jobToken --bash64 `$commandPayload 2>&1 |
            ForEach-Object {
                `$line = Clean-TerminalLine ([string]`$_)
                if (-not [string]::IsNullOrWhiteSpace(`$line)) { `$writer.WriteLine(`$line) }
            }
        `$code = `$LASTEXITCODE
    } finally {
        `$ErrorActionPreference = `$savedPreference
    }
    if (`$null -eq `$code) { `$code = 1 }
    `$writer.WriteLine("WSL exit code: " + `$code)
    exit [int]`$code
} catch {
    try {
        if (`$writer) { `$writer.WriteLine("Windows launcher exception: " + `$_.Exception.ToString()) }
    } catch { }
    exit 1
} finally {
    if (`$writer) { `$writer.Dispose() }
    elseif (`$stream) { `$stream.Dispose() }
}
"@
    try {
        [System.IO.File]::WriteAllText($wrapperPath, $wrapperText, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        try { Add-Content -LiteralPath $LogPath -Value ("Could not create the Windows WSL wrapper: " + $_.Exception.Message) -Encoding UTF8 } catch { }
        Show-Error ("The WSL launcher could not be prepared.`r`n`r`nRun log:`r`n$LogPath`r`n`r`n" + $_.Exception.Message)
        return
    }
    $script:JobWrapperPath = $wrapperPath

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $PSHOME 'powershell.exe')
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$wrapperPath`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
    } catch {
        try { Add-Content -LiteralPath $LogPath -Value ("The Windows wrapper process could not start: " + $_.Exception.ToString()) -Encoding UTF8 } catch { }
        Remove-JobWrapper
        Show-Error ("The WSL job could not start.`r`n`r`nRun log:`r`n$LogPath`r`n`r`n" + $_.Exception.Message)
        return
    }

    $script:JobProcess = $process
    Set-JobUi $true "Running $Mode"
    Append-Log "Started $Mode at $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))"
    Append-Log "Shared Linux environment: connected"
    Append-Log "Run log: $LogPath"
    if (-not $script:JobTimer) {
        $script:JobTimer = New-Object System.Windows.Forms.Timer
        $script:JobTimer.Interval = 400
        $script:JobTimer.Add_Tick({
            Refresh-Log
            Refresh-ProgressDisplay
            if ($script:JobProcess -and $script:JobProcess.HasExited) { Complete-Job }
        })
    }
    $script:JobTimer.Start()
}

function Start-AnalysisJob([string]$Mode, [hashtable]$Config, [string]$OutputDirectory) {
    $distro = Get-WslDistroLocal
    if (-not $distro) { Show-Error 'No runnable WSL2 Linux distribution was found. Verify that the shared Ubuntu WSL2 environment can start, then use Install or update if the downstream analysis environment is not installed.'; return }
    [void][System.IO.Directory]::CreateDirectory($OutputDirectory)
    $technicalDirectory = Join-Path $OutputDirectory 'Intermediate files'
    [void][System.IO.Directory]::CreateDirectory($technicalDirectory)
    $configWindows = Join-Path $technicalDirectory ("{0} configuration.json" -f $Mode)
    Write-JsonConfig $Config $configWindows
    $runnerWsl = Convert-ToWslPathLocal $script:Runner $distro
    $configWsl = Convert-ToWslPathLocal $configWindows $distro
    $bashCommand = "bash $(Quote-Bash $runnerWsl) $(Quote-Bash $Mode) $(Quote-Bash $configWsl)"
    Start-BashJob $Mode $bashCommand (Join-Path $technicalDirectory ("{0} run.log" -f $Mode)) $OutputDirectory
}

function Open-VisualizationStudio([string]$Mode, [string]$OutputDirectory) {
    $OutputDirectory = [string]$OutputDirectory
    if (-not $OutputDirectory -or -not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        Show-Error 'Select or create a result folder first. Run the analysis to generate the interactive HTML report.'
        return
    }
    $reportName = switch ($Mode) {
        'de' { 'Differential expression interactive.html' }
        'enrichment' { 'GO enrichment interactive.html' }
        'network' { 'Network analysis interactive.html' }
        'combined' { 'Functional enrichment and co-expression interactive.html' }
        'pathway_map' { 'Functional enrichment and co-expression interactive.html' }
        default { '' }
    }
    if (-not $reportName) { Show-Error "Unknown interactive report type: $Mode"; return }
    $reportPath = Join-Path $OutputDirectory $reportName
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        Show-Error "The interactive HTML report was not found:`r`n$reportPath`r`n`r`nRun the analysis again with this version to generate it automatically."
        return
    }
    try {
        # Refresh saved plot behavior only when opening a report. This uses the
        # current renderer without invoking WSL, loading counts, or running DE.
        . (Join-Path $script:AppDir 'refresh_plot_reports.ps1')
        $refreshed = Update-BraPlotReports -ResultDirectory $OutputDirectory -RuntimeSource (Join-Path $script:ModuleRoot 'Python\interactive_plots.py')
        if ($refreshed -gt 0) { Append-Log "Updated $refreshed saved interactive plots to v28. Statistical results are unchanged." }
        Start-Process -FilePath $reportPath | Out-Null
        Append-Log "Opened offline interactive HTML report: $reportPath"
    } catch {
        Show-Error ("The interactive HTML report could not be opened.`r`n`r`n" + $_.Exception.Message)
    }
}

function Show-AnalysisSuccessDialog([string]$Mode, [string]$OutputDirectory) {
    $modeTitle = switch ($Mode) {
        'de' { 'Differential-expression analysis completed' }
        'enrichment' { 'GO / enrichment analysis completed' }
        'network' { 'Network analysis completed' }
        'combined' { 'Functional enrichment and co-expression analysis completed' }
        'pathway_map' { 'KEGG pathway expression mapping completed' }
        default { 'Analysis completed' }
    }
    $reportName = switch ($Mode) {
        'de' { 'Differential expression interactive.html' }
        'enrichment' { 'GO enrichment interactive.html' }
        'network' { 'Network analysis interactive.html' }
        'combined' { 'Functional enrichment and co-expression interactive.html' }
        'pathway_map' { 'Functional enrichment and co-expression interactive.html' }
        default { '' }
    }
    $reportPath = if ($reportName) { Join-Path $OutputDirectory $reportName } else { '' }
    $reportReady = [bool]($reportPath -and (Test-Path -LiteralPath $reportPath -PathType Leaf))

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Analysis completed successfully'
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(600, 188)
    $dialog.BackColor = $surface

    $title = New-Object System.Windows.Forms.Label
    $title.Text = $modeTitle
    $title.SetBounds(22, 18, 552, 28)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', [single]13, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $greenDark

    $body = New-Object System.Windows.Forms.Label
    $body.Text = if ($reportReady) {
        "The analysis finished successfully. The Excel results and interactive HTML report are ready."
    } else {
        "The analysis finished successfully. The Excel results were written, but the interactive HTML report was not found."
    }
    $body.SetBounds(22, 56, 552, 42)
    $body.Font = New-Object System.Drawing.Font('Segoe UI', [single]9.5)
    $body.ForeColor = $ink

    $pathLabel = New-Object System.Windows.Forms.Label
    $pathLabel.Text = if ($reportPath) { $reportPath } else { $OutputDirectory }
    $pathLabel.SetBounds(22, 101, 552, 25)
    $pathLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]8.3)
    $pathLabel.ForeColor = $muted
    $pathLabel.AutoEllipsis = $true

    $open = New-Button 'Open interactive report' 292 139 180 34 -Primary
    $open.Enabled = $reportReady
    $open.Tag = [pscustomobject]@{ Mode=$Mode; Output=$OutputDirectory; Dialog=$dialog }
    $open.Add_Click({
        param($sender,$eventArgs)
        Open-VisualizationStudio ([string]$sender.Tag.Mode) ([string]$sender.Tag.Output)
        $sender.Tag.Dialog.Close()
    })

    $close = New-Button 'Close' 482 139 95 34
    $close.Tag = $dialog
    $close.Add_Click({ param($sender,$eventArgs) $sender.Tag.Close() })

    $dialog.Controls.AddRange(@($title,$body,$pathLabel,$open,$close))
    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()
}

$script:ActiveParameterHelpPopup = $null
function Hide-ParameterHelpPopup {
    if ($script:ActiveParameterHelpPopup) {
        try { $script:ActiveParameterHelpPopup.Close() } catch { }
        try { $script:ActiveParameterHelpPopup.Dispose() } catch { }
        $script:ActiveParameterHelpPopup = $null
    }
}

function Show-ParameterHelpPopup {
    param([System.Windows.Forms.Control]$Anchor, [string]$Title, [string]$HelpText)
    Hide-ParameterHelpPopup
    $screen = [System.Windows.Forms.Screen]::FromControl($Anchor)
    $area = $screen.WorkingArea
    $popupWidth = [Math]::Min(470, [Math]::Max(330, ($area.Width - 30)))
    $fullText = "$Title`r`n`r`n$HelpText"
    $measure = [System.Windows.Forms.TextRenderer]::MeasureText(
        $fullText,
        (New-Object System.Drawing.Font('Segoe UI', 9.5)),
        ([System.Drawing.Size]::new(($popupWidth - 30), 2200)),
        ([System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix)
    )
    $popupHeight = [Math]::Min(520, [Math]::Max(150, ($measure.Height + 28)))
    $box = New-Object System.Windows.Forms.RichTextBox
    $box.Size = [System.Drawing.Size]::new(($popupWidth - 4), ($popupHeight - 4))
    $box.ReadOnly = $true
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $box.BackColor = $surface
    $box.ForeColor = $ink
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $box.WordWrap = $true
    $box.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
    $box.Text = $fullText
    Format-StructuredHelpText -Box $box -Title $Title
    $hostControl = New-Object System.Windows.Forms.ToolStripControlHost -ArgumentList $box
    $hostControl.AutoSize = $false
    $hostControl.Size = $box.Size
    $hostControl.Margin = New-Object System.Windows.Forms.Padding(0)
    $popup = New-Object System.Windows.Forms.ToolStripDropDown
    $popup.AutoSize = $false
    $popup.Padding = New-Object System.Windows.Forms.Padding(1)
    $popup.Size = [System.Drawing.Size]::new($popupWidth, $popupHeight)
    $popup.BackColor = $border
    $popup.DropShadowEnabled = $true
    [void]$popup.Items.Add($hostControl)
    $anchorPoint = $Anchor.PointToScreen([System.Drawing.Point]::new(($Anchor.Width + 6), 0))
    $x = $anchorPoint.X
    if (($x + $popupWidth) -gt $area.Right) {
        $x = $Anchor.PointToScreen([System.Drawing.Point]::new((-1 * ($popupWidth + 6)), 0)).X
    }
    $x = [Math]::Max(($area.Left + 4), [Math]::Min($x, ($area.Right - $popupWidth - 4)))
    $y = [Math]::Max(($area.Top + 4), [Math]::Min($anchorPoint.Y, ($area.Bottom - $popupHeight - 4)))
    $script:ActiveParameterHelpPopup = $popup
    $popup.Show((New-Object System.Drawing.Point($x, $y)))
}

function New-HelpButton {
    param([int]$X, [int]$Y, [string]$Title, [string]$HelpText, [int]$Size = 25)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = '?'
    $button.Location = [System.Drawing.Point]::new($X, $Y)
    $button.Size = [System.Drawing.Size]::new($Size, $Size)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderColor = $blue
    $button.FlatAppearance.BorderSize = 1
    $button.BackColor = $blueSoft
    $button.ForeColor = $blue
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $button.Cursor = [System.Windows.Forms.Cursors]::Help
    $button.TabStop = $false
    $button.Tag = [pscustomobject]@{ Title = $Title; HelpText = $HelpText }
    try {
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddEllipse(0, 0, ($Size - 1), ($Size - 1))
        $button.Region = New-Object System.Drawing.Region($path)
        $path.Dispose()
    } catch { }
    $button.Add_MouseEnter({
        param($sender, $eventArgs)
        Show-ParameterHelpPopup -Anchor $sender -Title ([string]$sender.Tag.Title) -HelpText ([string]$sender.Tag.HelpText)
    })
    $button.Add_MouseLeave({ Hide-ParameterHelpPopup })
    return $button
}

$script:ParameterToolTip = New-Object System.Windows.Forms.ToolTip
$script:ParameterToolTip.AutoPopDelay = 16000
$script:ParameterToolTip.InitialDelay = 450
$script:ParameterToolTip.ReshowDelay = 150
$script:ParameterToolTip.ShowAlways = $true
function Set-ParameterTip([System.Windows.Forms.Control]$Control, [string]$Text) {
    if ($Control -and $Text) { $script:ParameterToolTip.SetToolTip($Control, $Text) }
}

function Set-InputPathTip {
    param([System.Windows.Forms.Control[]]$Controls, [string]$Text)
    if (-not $Text) { return }

    $title = 'Accepted input'
    if ($Text -match '(?im)^\s*OUTPUT LOCATION') { $title = 'Output folder guidance' }
    elseif ($Text -match '(?im)^\s*OPTIONAL INPUT') { $title = 'Optional input guidance' }
    elseif ($Text -match '(?im)^\s*ONLINE ANNOTATION INPUT') { $title = 'Online annotation input' }

    # The popup already has its own title bar. Strip the repeated all-caps
    # heading from the body so users see "Accepted input" only once.
    $body = [regex]::Replace(
        [string]$Text,
        '(?is)^\s*(ACCEPTED INPUT|OPTIONAL INPUT|OUTPUT LOCATION|ONLINE ANNOTATION INPUT)\s*',
        ''
    ).Trim()

    foreach ($control in @($Controls)) {
        if (-not $control) { continue }
        $script:ParameterToolTip.SetToolTip($control, $body)
        # Use accessibility properties for event-local storage so existing Tag
        # values used elsewhere in the GUI are never overwritten.
        $control.AccessibleName = $title
        $control.AccessibleDescription = $body
        # MouseEnter is more reliable than MouseHover on editable text boxes.
        $control.Add_MouseEnter({
            param($sender, $eventArgs)
            if ($sender.AccessibleDescription) {
                Show-ParameterHelpPopup -Anchor $sender -Title ([string]$sender.AccessibleName) -HelpText ([string]$sender.AccessibleDescription)
            }
        })
        $control.Add_MouseHover({
            param($sender, $eventArgs)
            if ($sender.AccessibleDescription) {
                Show-ParameterHelpPopup -Anchor $sender -Title ([string]$sender.AccessibleName) -HelpText ([string]$sender.AccessibleDescription)
            }
        })
        $control.Add_MouseLeave({ Hide-ParameterHelpPopup })
        $control.Add_Leave({ Hide-ParameterHelpPopup })
    }
}

function New-FlowPanel {
    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    if ($script:BuildingDownstreamUi) {
        $panel.SuspendLayout()
        [void]$script:DeferredLayoutControls.Add($panel)
    }
    $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $panel.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $panel.WrapContents = $false
    # Allow the configuration cards to scroll instead of being hidden behind the
    # shared live-console/status footer on smaller windows or high-DPI displays.
    $panel.AutoScroll = $true
    $panel.BackColor = $background
    $panel.Padding = New-Object System.Windows.Forms.Padding(4)
    return $panel
}

function New-GuidanceGroup {
    param([string]$Title, [string]$Body, [int]$Height = 155)
    $group = New-Group $Title 0 $Height
    $box = New-Object System.Windows.Forms.RichTextBox
    $box.Location = [System.Drawing.Point]::new(12, 24)
    $box.Size = [System.Drawing.Size]::new(560, ($Height - 34))
    $box.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $box.ReadOnly = $true
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $box.BackColor = $blueSoft
    $box.ForeColor = $ink
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $box.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::None
    $box.Text = $Body
    $group.Controls.Add($box)
    $group.Tag = $box
    return $group
}

function Test-IntegerRange([System.Windows.Forms.TextBox]$Box, [string]$Label, [int]$Minimum, [int]$Maximum, [ref]$Value) {
    $parsed = 0
    if (-not [int]::TryParse($Box.Text.Trim(), [ref]$parsed)) {
        Show-Error "$Label must be a whole number from $Minimum to $Maximum."
        $Box.Focus()
        return $false
    }
    if ($parsed -lt $Minimum -or $parsed -gt $Maximum) {
        Show-Error "$Label must be from $Minimum to $Maximum."
        $Box.Focus()
        return $false
    }
    $Value.Value = $parsed
    return $true
}

function Test-DoubleRange([System.Windows.Forms.TextBox]$Box, [string]$Label, [double]$Minimum, [double]$Maximum, [bool]$MinimumInclusive, [ref]$Value) {
    $parsed = 0.0
    if (-not [double]::TryParse($Box.Text.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        Show-Error "$Label must be a numeric value. Use a period as the decimal separator."
        $Box.Focus()
        return $false
    }
    $below = if ($MinimumInclusive) { $parsed -lt $Minimum } else { $parsed -le $Minimum }
    if ($below -or $parsed -gt $Maximum) {
        $lowerText = if ($MinimumInclusive) { "at least $Minimum" } else { "greater than $Minimum" }
        Show-Error "$Label must be $lowerText and no greater than $Maximum."
        $Box.Focus()
        return $false
    }
    $Value.Value = $parsed
    return $true
}

function Set-ResponsiveSplitter([System.Windows.Forms.SplitContainer]$Split, [double]$LeftFraction = 0.58) {
    if (-not $Split -or $Split.ClientSize.Width -le 0 -or $Split.Panel2Collapsed) { return }
    $available = [int]($Split.ClientSize.Width - $Split.SplitterWidth)

    # A SplitContainer is initially created at a very small default width. Setting
    # Panel1MinSize or Panel2MinSize before the parent form has completed layout can
    # make WinForms reject the current SplitterDistance. Wait for a usable width,
    # temporarily relax both minimums, set a valid distance, and only then restore
    # practical minimum panel widths.
    if ($available -lt 700) { return }

    $preferredLeftMin = 620
    $preferredRightMin = 350
    if ($available -le ($preferredLeftMin + $preferredRightMin)) {
        $target = [Math]::Max(300, $available - $preferredRightMin)
    } else {
        $target = [int]($available * $LeftFraction)
        $target = [Math]::Max($preferredLeftMin, [Math]::Min($target, ($available - $preferredRightMin)))
    }

    try {
        $Split.Panel1MinSize = 25
        $Split.Panel2MinSize = 25
        $maximumDistance = [Math]::Max(25, $available - 25)
        $target = [Math]::Max(25, [Math]::Min([int]$target, $maximumDistance))
        $Split.SplitterDistance = [int]$target

        $leftPanelMinimum = [Math]::Min(300, [Math]::Max(25, [int]$target))
        $rightPanelMinimum = [Math]::Min(300, [Math]::Max(25, [int]($available - $target)))
        $Split.Panel1MinSize = [int]$leftPanelMinimum
        $Split.Panel2MinSize = [int]$rightPanelMinimum
    } catch {
        # Keep startup resilient on unusual DPI/layout combinations. The resize and
        # Shown handlers will call this function again after WinForms finishes layout.
    }
}

$script:UiStartupWatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:BuildingDownstreamUi = $true
$script:DeferredLayoutControls = New-Object 'System.Collections.Generic.List[System.Windows.Forms.Control]'
$form = New-Object System.Windows.Forms.Form
$form.SuspendLayout()
$form.Text = "$($script:ModuleDisplayName) | Bacterial RNA Analysis"
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.ClientSize = [System.Drawing.Size]::new([int]1500, [int]900)
$form.MinimumSize = [System.Drawing.Size]::new([int]1400, [int]820)
$form.BackColor = $background
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.ShowInTaskbar = -not $script:EmbeddedMode

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.SuspendLayout()
$root.Dock = [System.Windows.Forms.DockStyle]::Fill
$root.ColumnCount = 1
$root.RowCount = 3
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 78)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
# Keep the shared console visible without stealing enough vertical space to clip
# the last settings card. The input panes remain scrollable as a DPI-safe fallback.
$sharedStatusHeight = if ($script:InitialTab -in @('enrichment', 'network')) { 168 } else { 160 }
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $sharedStatusHeight)))
$form.Controls.Add($root)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = [System.Windows.Forms.DockStyle]::Fill
$header.BackColor = $surface
$root.Controls.Add($header, 0, 0)
$title = New-Label $script:ModuleDisplayName 20 5 620 34 -Bold
$title.Font = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = $greenDark
$subtitle = New-Label $script:ModuleSubtitle 22 43 800 27
$subtitle.ForeColor = $muted
$instructionsButton = New-Button 'Instructions' 0 14 140 36
$instructionsButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$backButton = New-Button '< Back to analysis modules' 0 14 188 36
$backButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$header.Controls.AddRange(@($title, $subtitle, $instructionsButton, $backButton))
$layoutHeaderButtons = {
    $backButton.Left = [Math]::Max(1040, $header.ClientSize.Width - $backButton.Width - 18)
    $instructionsButton.Left = [Math]::Max(690, $backButton.Left - $instructionsButton.Width - 8)
    $subtitle.Width = [Math]::Max(430, $instructionsButton.Left - 40)
}.GetNewClosure()
$header.Add_Resize($layoutHeaderButtons)
& $layoutHeaderButtons

$tabs = New-Object System.Windows.Forms.Panel
$tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
$tabs.Margin = New-Object System.Windows.Forms.Padding(0)
$tabs.Padding = New-Object System.Windows.Forms.Padding(0)
$tabs.BackColor = $background
$root.Controls.Add($tabs, 0, 1)
$pageDE = New-Object System.Windows.Forms.Panel
$pageDE.Dock = [System.Windows.Forms.DockStyle]::Fill
$pageDE.BackColor = $background
$pageEnrichment = New-Object System.Windows.Forms.Panel
$pageEnrichment.Dock = [System.Windows.Forms.DockStyle]::Fill
$pageEnrichment.BackColor = $background
$pageNetwork = New-Object System.Windows.Forms.Panel
$pageNetwork.Dock = [System.Windows.Forms.DockStyle]::Fill
$pageNetwork.BackColor = $background
switch ($script:InitialTab) {
    'enrichment' { [void]$tabs.Controls.Add($pageEnrichment) }
    'network' { [void]$tabs.Controls.Add($pageNetwork) }
    default { [void]$tabs.Controls.Add($pageDE) }
}

# Shared status and environment controls
$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$statusPanel.BackColor = $surface
$root.Controls.Add($statusPanel, 0, 2)
$statusLeft = New-Object System.Windows.Forms.Panel
$statusLeft.Location = [System.Drawing.Point]::new(8, 6)
$statusLeft.Size = [System.Drawing.Size]::new(355, ($sharedStatusHeight - 14))
$statusLabel = New-Label 'Ready' 4 0 303 20 -Bold
$statusLabel.ForeColor = $greenDark
$statusLabel.AutoEllipsis = $true
$statusLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]9.25, [System.Drawing.FontStyle]::Bold)
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = [System.Drawing.Point]::new(4, 22)
$progressBar.Size = [System.Drawing.Size]::new(303, 14)
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$detailProgressLabel = New-Label '' 4 40 303 20
$detailProgressLabel.ForeColor = $muted
$detailProgressLabel.AutoEllipsis = $true
$detailProgressLabel.Tag = ''
$detailProgressLabel.Add_MouseHover({
    $fullText = [string]$detailProgressLabel.Tag
    if ($fullText -and $script:ParameterToolTip) {
        $script:ParameterToolTip.Show($fullText, $detailProgressLabel, 0, $detailProgressLabel.Height + 2, 16000)
    }
})
$detailProgressBar = New-Object System.Windows.Forms.ProgressBar
$detailProgressBar.Location = [System.Drawing.Point]::new(4, 61)
$detailProgressBar.Size = [System.Drawing.Size]::new(303, 11)
$detailProgressBar.Minimum = 0
$detailProgressBar.Maximum = 100
if ($script:InitialTab -in @('enrichment', 'network')) {
    $statusLabel.SetBounds(4,0,343,18)
    $progressBar.SetBounds(4,19,343,12)
    $detailProgressLabel.SetBounds(4,33,343,17)
    $detailProgressBar.SetBounds(4,51,343,9)
}
$showDetailedProgress = ($script:InitialTab -in @('enrichment', 'network'))
$detailProgressLabel.Visible = $showDetailedProgress
$detailProgressBar.Visible = $showDetailedProgress
$openDatabaseLibraryButton = $null
if ($showDetailedProgress) {
    # Compact footer so the live console never clips the final analysis-action row.
    $checkEnvironmentButton = New-Button 'Check environment' 4 65 165 25
    $installEnvironmentButton = New-Button 'Install or update' 178 65 169 25
    $stopButton = New-Button 'Stop current job' 4 95 343 26
    $openDatabaseLibraryButton = New-Button 'Database library' 4 126 104 25
    $openJobLogButton = New-Button 'Open log file' 114 126 104 25
    $openJobResultFolderButton = New-Button 'Open result folder' 224 126 123 25
} else {
    $checkEnvironmentButton = New-Button 'Check environment' 4 46 145 27
    $installEnvironmentButton = New-Button 'Install or update' 162 46 145 27
    $stopButton = New-Button 'Stop current job' 4 79 303 28
    $openJobLogButton = New-Button 'Open log file' 4 113 145 27
    $openJobResultFolderButton = New-Button 'Open result folder' 162 113 145 27
}
$stopButton.Enabled = $false
if ($showDetailedProgress) {
    Set-ParameterTip $checkEnvironmentButton 'Checks one environment containing all annotation, enrichment, automatic-module, co-expression, regulatory-network, plotting, Excel, and interactive-report dependencies.'
    Set-ParameterTip $installEnvironmentButton 'Creates or updates the same combined environment used by the complete run. No separate GO or network installation is required.'
}
if ($showDetailedProgress) {
    $statusLeft.Controls.AddRange(@($statusLabel, $progressBar, $detailProgressLabel, $detailProgressBar, $checkEnvironmentButton, $installEnvironmentButton, $stopButton, $openDatabaseLibraryButton, $openJobLogButton, $openJobResultFolderButton))
    Set-ParameterTip $openDatabaseLibraryButton 'Open the persistent shared Database Library at /root/.local/share/prok-rnaseq/Database Library. Downloaded UniProt/Swiss-Prot/TrEMBL resources are kept here and reused across GO and Network projects.'
} else {
    $statusLeft.Controls.AddRange(@($statusLabel, $progressBar, $detailProgressLabel, $detailProgressBar, $checkEnvironmentButton, $installEnvironmentButton, $stopButton, $openJobLogButton, $openJobResultFolderButton))
}

function Open-CurrentDownstreamLog {
    if ($script:JobLogPath -and (Test-Path -LiteralPath $script:JobLogPath -PathType Leaf)) {
        Start-Process -FilePath $script:JobLogPath
        return
    }
    Show-Message 'No current run log exists yet. Start an environment check, installation, or analysis first.'
}
function Open-CurrentDownstreamResultFolder {
    $folder = ''
    if ($script:JobOutput -and (Test-Path -LiteralPath $script:JobOutput -PathType Container)) { $folder = [string]$script:JobOutput }
    elseif ($script:InitialTab -eq 'de' -and $deOutputText -and $deOutputText.Text.Trim()) { $folder = $deOutputText.Text.Trim() }
    elseif ($script:InitialTab -eq 'enrichment' -and $enrichOutputText -and $enrichOutputText.Text.Trim()) { $folder = $enrichOutputText.Text.Trim() }
    elseif ($script:InitialTab -eq 'network' -and $networkOutputText -and $networkOutputText.Text.Trim()) { $folder = $networkOutputText.Text.Trim() }
    if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) { Start-Process explorer.exe $folder; return }
    Show-Message 'The current result folder is not available yet. Choose a results folder or run the analysis first.'
}
function Open-SharedDatabaseLibrary {
    $distro = Get-WslDistroLocal
    if (-not $distro) { Show-Error 'No runnable WSL2 Linux distribution was found, so the shared Database Library cannot be opened yet.'; return }
    $linuxPath = '/root/.local/share/prok-rnaseq/Database Library'
    try {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & wsl.exe -d $distro -u root -- /bin/mkdir -p $linuxPath 2>&1 | Out-Null
            $mkdirExit = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        if ($mkdirExit -ne 0) { throw "WSL could not create or access the library folder (exit $mkdirExit)." }

        $uncPrimary = "\\wsl.localhost\$distro\root\.local\share\prok-rnaseq\Database Library"
        $uncFallback = "\\wsl$\$distro\root\.local\share\prok-rnaseq\Database Library"
        $opened = $false
        foreach ($candidate in @($uncPrimary, $uncFallback)) {
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = 'explorer.exe'
                $psi.Arguments = '"' + $candidate + '"'
                $psi.UseShellExecute = $true
                [void][System.Diagnostics.Process]::Start($psi)
                $opened = $true
                break
            } catch { }
        }
        if (-not $opened) { throw 'Windows Explorer could not open the WSL library path.' }
    } catch {
        Show-Error ("Could not open the shared Database Library.`r`nLinux path: {0}`r`nWSL distribution: {1}`r`n`r`n{2}" -f $linuxPath, $distro, $_.Exception.Message)
    }
}
if ($showDetailedProgress -and $openDatabaseLibraryButton) { $openDatabaseLibraryButton.Add_Click({ Open-SharedDatabaseLibrary }) }
$openJobLogButton.Add_Click({ Open-CurrentDownstreamLog })
$openJobResultFolderButton.Add_Click({ Open-CurrentDownstreamResultFolder })

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = [System.Drawing.Point]::new(365, 6)
$logBox.Size = [System.Drawing.Size]::new(1115, 146)
$logBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$logBox.ReadOnly = $true
$logBox.WordWrap = $false
$logBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
$logBox.BackColor = [System.Drawing.Color]::FromArgb(250, 252, 250)
$logBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$statusPanel.Controls.AddRange(@($statusLeft, $logBox))
$statusPanel.Add_Resize({
    $usableHeight = [Math]::Max(136, $statusPanel.ClientSize.Height - 12)
    $statusLeft.Height = $usableHeight
    $logBox.SetBounds(365, 6, [Math]::Max(420, ($statusPanel.ClientSize.Width - 373)), $usableHeight)
})

# Differential expression page
$deSplit = New-Object System.Windows.Forms.SplitContainer
$deSplit.Dock = [System.Windows.Forms.DockStyle]::Fill
$deSplit.Panel2Collapsed = $true
$deSplit.BackColor = $background
$pageDE.Controls.Add($deSplit)
$deLeftHost = New-Object System.Windows.Forms.Panel
$deLeftHost.Dock = [System.Windows.Forms.DockStyle]::Fill
$deLeftHost.BackColor = $background
$deSplit.Panel1.Controls.Add($deLeftHost)
$deInputPanel = New-FlowPanel
$deInputPanel.Padding = New-Object System.Windows.Forms.Padding(4)
$deLeftHost.Controls.Add($deInputPanel)
$deRight = New-FlowPanel
$deRight.BackColor = $surface
$deSplit.Panel2.Controls.Add($deRight)

$deInputGroup = New-Group '1. Raw counts, metadata, and optional genome coordinates' 0 216
$deCountLabel = New-Label 'Raw integer count matrix' 16 28 205 24
$deCountText = New-TextBox 230 27 290
$deCountBrowse = New-Button 'Browse' 530 25 72 29
$useLatestRnaSeqButton = New-Button 'Use latest RNA-seq result' 612 25 170 29
$deMetadataLabel = New-Label 'Sample metadata' 16 65 205 24
$deMetadataText = New-TextBox 230 64 290
$deMetadataBrowse = New-Button 'Browse' 530 62 68 29
$deAnnotationLabel = New-Label 'Gene coordinates for IGV (optional)' 16 102 205 24
$deAnnotationText = New-TextBox 230 101 290
$deAnnotationBrowse = New-Button 'Browse' 530 99 68 29
$deOutputLabel = New-Label 'Results folder' 16 139 205 24
$deOutputText = New-TextBox 230 138 290
$deOutputBrowse = New-Button 'Browse' 530 136 68 29
$deExampleButton = New-Button 'Example workbook' 230 174 120 29
$deExampleButton.Visible = $false
$deManualExcelButton = New-Button 'Manual Excel input' 358 174 150 29
$deScanFolderButton = New-Button 'Scan RNA Processing folder' 516 174 220 29
$deInputGroup.Controls.AddRange(@($deCountLabel, $deCountText, $deCountBrowse, $useLatestRnaSeqButton, $deMetadataLabel, $deMetadataText, $deMetadataBrowse, $deAnnotationLabel, $deAnnotationText, $deAnnotationBrowse, $deOutputLabel, $deOutputText, $deOutputBrowse, $deExampleButton, $deManualExcelButton, $deScanFolderButton))
$deInputPanel.Controls.Add($deInputGroup)
$deInputGroup.Add_Resize({
    $w = $deInputGroup.ClientSize.Width
    $browseLeft = [Math]::Max(470,$w-86)
    foreach($box in @($deCountText,$deMetadataText,$deAnnotationText,$deOutputText)){ $box.Left=230;$box.Width=[Math]::Max(170,$browseLeft-240) }
    foreach($button in @($deCountBrowse,$deMetadataBrowse,$deAnnotationBrowse,$deOutputBrowse)){ $button.Left=$browseLeft }
    $useLatestRnaSeqButton.SetBounds(16,174,224,29)
    $deManualExcelButton.SetBounds(248,174,170,29)
    $deScanFolderButton.SetBounds(426,174,240,29)
})

$deEngineHelpText = @'
edgeR quasi-likelihood  -  recommended default
Strengths: strong type-I error control, fast execution, flexible generalized linear models, and good performance for typical replicated bacterial experiments.
Limitations: may be conservative with very small sample sizes; interpretation still depends on a correct design and dispersion estimates.

DESeq2
Strengths: highly established workflow, robust size-factor and dispersion estimation, and useful fold-change shrinkage for ranking and plotting.
Limitations: can be slower on large designs; many contrasts or unusual designs may require more manual specification; biological replication is still essential.

limma-voom
Strengths: excellent for multifactor studies, time courses, batch terms, interactions, and many contrasts; computationally efficient.
Limitations: relies on a well-estimated mean-variance trend and adequate library sizes; very sparse low-count data require careful filtering.
'@
$deDesignGroup = New-Group '2. Statistical design and contrast' 0 228
$deEngineLabel = New-Label 'Engine' 16 29 110 24
$deEngineCombo = New-ComboBox 135 27 360 @('edgeR quasi-likelihood (recommended)', 'DESeq2', 'limma-voom')
$deEngineHelp = New-HelpButton 505 27 'Differential-expression engines' $deEngineHelpText
$deSampleColumnLabel = New-Label 'Sample ID column' 16 70 115 24
$deSampleColumnCombo = New-ComboBox 135 68 150 @()
$deConditionLabel = New-Label 'Condition column' 310 70 115 24
$deConditionCombo = New-ComboBox 430 68 150 @()
$deBatchLabel = New-Label 'Batch column' 16 109 115 24
$deBatchCombo = New-ComboBox 135 107 150 @('None')
$deReferenceLabel = New-Label 'Reference level' 310 109 115 24
$deReferenceCombo = New-ComboBox 430 107 150 @()
$deTestLabel = New-Label 'Test level' 16 148 115 24
$deTestCombo = New-ComboBox 135 146 150 @()
$deMultiContrast = New-Object System.Windows.Forms.CheckBox
$deMultiContrast.Text = 'Multiple treatments vs one control'
$deMultiContrast.Location = [System.Drawing.Point]::new(310, 146)
$deMultiContrast.Size = [System.Drawing.Size]::new(255, 25)
$deMultiContrast.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$deMultiSelectButton = New-Button 'Choose treatment groups...' 16 181 180 32
$deMultiSelectButton.Visible = $false
$deMultiSummary = New-Label '' 206 178 560 40
$deMultiSummary.ForeColor = $muted
$deMultiSummary.Visible = $false
$deDesignNote = New-Label 'Fold change is test versus reference. Add batch only when it is not confounded with condition.' 310 178 420 38
$deDesignNote.ForeColor = $muted
$deDesignGroup.Controls.AddRange(@($deEngineLabel, $deEngineCombo, $deEngineHelp, $deSampleColumnLabel, $deSampleColumnCombo, $deConditionLabel, $deConditionCombo, $deBatchLabel, $deBatchCombo, $deReferenceLabel, $deReferenceCombo, $deTestLabel, $deTestCombo, $deMultiContrast, $deMultiSelectButton, $deMultiSummary, $deDesignNote))
$deInputPanel.Controls.Add($deDesignGroup)
$deDesignGroup.Add_Resize({
    $w = $deDesignGroup.ClientSize.Width
    $deEngineHelp.Left = [Math]::Max(505, $w - 43)
    $deEngineCombo.Width = [Math]::Max(250, $deEngineHelp.Left - $deEngineCombo.Left - 10)
    $half = [int](($w - 42) / 2)
    $rightX = 22 + $half
    foreach ($label in @($deConditionLabel, $deReferenceLabel)) { $label.Left = $rightX }
    foreach ($combo in @($deConditionCombo, $deReferenceCombo)) { $combo.Left = $rightX + 120; $combo.Width = [Math]::Max(125, $w - $combo.Left - 18) }
    foreach ($combo in @($deSampleColumnCombo, $deBatchCombo, $deTestCombo)) { $combo.Width = [Math]::Max(125, $half - 135) }
    $deMultiContrast.Left = $rightX
    $deMultiContrast.Width = [Math]::Max(240, $w - $rightX - 18)
    $deMultiSummary.Left = 206
    $deMultiSummary.Width = [Math]::Max(300, $w - $deMultiSummary.Left - 18)
    $deDesignNote.Left = $rightX
    $deDesignNote.Width = [Math]::Max(220, $w - $rightX - 18)
})

$deSettingsGroup = New-Group '3. Filtering and significance' 0 112
$deMinCountHelpText = @'
Accepted range: 0 to 10,000,000 raw reads per gene.

Recommended starting value: 10.

Trade-off: lower values retain weakly expressed genes but increase noise and the multiple-testing burden. Higher values improve stability but can remove genuine low-expression genes. Combine this setting with Minimum samples rather than filtering on total count alone.
'@
$deMinSamplesHelpText = @'
Accepted range: 3 to 10,000 samples.

Recommended starting value: 3, or the size of the smallest biological group for stricter filtering.

Trade-off: a smaller value keeps condition-specific genes; a larger value requires broader expression and gives more stable dispersion estimates, but can discard genes expressed only in one condition.
'@
$dePadjHelpText = @'
Accepted range: greater than 0 through 1.

Recommended starting value: 0.05. Use 0.10 only for clearly labelled exploratory screening.

Trade-off: smaller values reduce false discoveries but lower sensitivity. Larger values identify more candidates but increase the expected proportion of false positives among reported genes.
'@
$deLfcHelpText = @'
Accepted range: 0 to 50.

Recommended starting value: 1.0, corresponding to a twofold change. A value of 0.585 is approximately 1.5-fold.

Trade-off: lower thresholds retain subtle but statistically supported changes. Higher thresholds focus on stronger biological effects but may exclude coordinated modest responses.
'@
$deMinCountLabel = New-Label 'Minimum count' 16 31 92 24
$deMinCount = New-TextBox 110 29 62 '10'
$deMinCountHelp = New-HelpButton 177 30 'Minimum count' $deMinCountHelpText 22
$deMinSamplesLabel = New-Label 'Minimum samples' 218 31 105 24
$deMinSamples = New-TextBox 326 29 62 '3'
$deMinSamplesHelp = New-HelpButton 393 30 'Minimum samples' $deMinSamplesHelpText 22
$dePadjLabel = New-Label 'Adjusted p-value' 434 31 105 24
$dePadj = New-TextBox 542 29 62 '0.05'
$dePadjHelp = New-HelpButton 609 30 'Adjusted p-value' $dePadjHelpText 22
$deLfcLabel = New-Label 'Absolute log2 FC' 650 31 112 24
$deLfc = New-TextBox 765 29 62 '1.0'
$deLfcHelp = New-HelpButton 832 30 'Absolute log2 fold change' $deLfcHelpText 22
$deParameterHelp = New-Button 'Parameter guide' 16 70 125 32
$deAdvancedPackageButton = New-Button 'Guided package options' 149 70 200 32
$deAdvancedPackageButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$runDEButton = New-Button 'Run differential-expression analysis' 327 69 235 34 -Primary
$runDEButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$openDEStudioButton = New-Button 'Open interactive report' 570 69 160 34
$openDEStudioButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
Set-ParameterTip $openDEStudioButton 'Generated automatically after a successful differential-expression run.'

$deRecommendation = New-Group 'Recommended study design and interpretation' 10 108
$deRecommendation.Size = New-Object System.Drawing.Size(700, 82)
$deRecommendation.BackColor = $orangeSoft
$deRecommendationTitle = New-Label 'RECOMMENDED: 3 OR MORE BIOLOGICAL REPLICATES PER GROUP' 12 22 650 20 -Bold
$deRecommendationTitle.ForeColor = $orange
$deRecommendationBody = New-Label 'At least three biological replicates are required in every compared group. Use raw integer counts, inspect PCA for outliers and group separation, use batch only when estimable, and interpret DE as association rather than direct regulation.' 12 42 650 34
$deRecommendationBody.Font = New-Object System.Drawing.Font('Segoe UI', [single]8.5)
$deRecommendationBody.AutoEllipsis = $false
Set-ParameterTip $deRecommendationBody $deRecommendationBody.Text
$deRecommendation.Controls.AddRange(@($deRecommendationTitle, $deRecommendationBody))
$deRecommendation.Add_Resize({
    $inside = [Math]::Max(320, $deRecommendation.ClientSize.Width - 24)
    $deRecommendationTitle.Width = $inside
    $deRecommendationBody.Width = $inside
})

$deSettingsGroup.Controls.AddRange(@($deMinCountLabel, $deMinCount, $deMinCountHelp, $deMinSamplesLabel, $deMinSamples, $deMinSamplesHelp, $dePadjLabel, $dePadj, $dePadjHelp, $deLfcLabel, $deLfc, $deLfcHelp, $deParameterHelp, $deAdvancedPackageButton, $runDEButton, $openDEStudioButton))
$deInputPanel.Controls.Add($deSettingsGroup)
$deRecommendation.Margin = New-Object System.Windows.Forms.Padding(0,0,0,4)
$deInputPanel.Controls.Add($deRecommendation)
$deInputPanel.Controls.SetChildIndex($deRecommendation,0)
$deSettingsGroup.Add_Resize({
    # Keep the action row left aligned. Only widths change; no self-resizing height loop.
    $w = [Math]::Max(920, $deSettingsGroup.ClientSize.Width)
    $deParameterHelp.SetBounds(16,70,125,32)
    $deAdvancedPackageButton.SetBounds(149,70,170,32)
    $runDEButton.SetBounds(327,69,235,34)
    $openDEStudioButton.SetBounds(570,69,160,34)
})

$deGuidanceText = @'
Raw counts: integer gene counts only; do not use TPM, FPKM, percentages, or already normalized values.
Sample ID: must exactly match count-matrix column names.
Condition: categorical biological group used for the comparison.
Batch: optional categorical factor; use None when absent and never include a batch perfectly confounded with condition.
Reference level: baseline condition used as the denominator for fold change.
Test level: condition compared with the reference; reported log2 fold change is test/reference. For several treatments versus one control, enable Multiple treatments vs one control and choose two or more treatment levels. The recommended input remains one raw-count matrix plus one metadata table containing all groups so every contrast uses one consistent fitted model.

Minimum count: 0-10,000,000; 10 is a practical default.
Minimum samples: 3-10,000; use 3 as the default or the size of the smallest biological group for stricter filtering.
Adjusted p-value: >0-1; 0.05 recommended and 0.10 exploratory.
Absolute log2 FC: 0-50; 1.0 means a twofold change and 0.585 means about 1.5-fold.

Automatic exploratory analyses: every successful run adds normalized sample distributions, correlation/clustering, 3D PCA, source-of-variation, raw-p-value, gene-rank, top-variable-gene, and single-gene views. Two or more contrasts add UpSet, a Venn view for two or three contrasts, and fold-change comparison. Three or more condition levels add fuzzy expression-pattern clusters. These outputs use the same selected thresholds and are written to the Excel workbook and interactive report.
'@
$deParameterHelp.Add_Click({ Show-StructuredGuideDialog $deGuidanceText 'Differential-expression parameter guide' })
$deAdvancedPackageButton.Add_Click({ Show-AdvancedPackageOptions 'de' })

Set-ParameterTip $deEngineCombo 'Choose edgeR QL for the default production workflow, DESeq2 for a familiar shrinkage-based workflow, or limma-voom for complex designs and many contrasts.'
Set-ParameterTip $deAnnotationText 'Optional gene-coordinate table with gene_id, seqid, start, and end. Coordinates are 1-based inclusive and enable automatic IGV bedGraph export of signed log2 fold change.'
Set-ParameterTip $deSampleColumnCombo 'Metadata column containing unique sample IDs that exactly match count-matrix sample columns.'
Set-ParameterTip $deConditionCombo 'Metadata column defining the biological comparison. It must contain at least two levels.'
Set-ParameterTip $deBatchCombo 'Optional nuisance factor. Do not select a batch that is perfectly confounded with condition.'
Set-ParameterTip $deReferenceCombo 'Baseline condition. Fold changes are calculated relative to this level.'
Set-ParameterTip $deTestCombo 'Condition compared against the reference level.'
Set-ParameterTip $deMultiContrast 'Enable this when two or more treatment levels should each be compared with one shared control. Recommended input is one raw-count matrix containing all samples plus one metadata table containing Control, Treatment 1, Treatment 2, Treatment 3, and so on. The statistical model is fitted once and each treatment-versus-control contrast is extracted from that same model.'
Set-ParameterTip $deMultiSelectButton 'Choose two or more metadata condition levels to compare against the selected reference/control. Separate experiments should not be blindly merged unless they use the same reference/feature definition and batch is represented in metadata.'
Set-ParameterTip $deMinCount 'Accepted range 0-10,000,000. Recommended starting value 10.'
Set-ParameterTip $deMinSamples 'Accepted range 3-10,000. Recommended 3 or the size of the smallest biological group.'
Set-ParameterTip $dePadj 'Accepted range greater than 0 through 1. Recommended 0.05.'
Set-ParameterTip $deLfc 'Accepted range 0-50. Recommended 1.0 for a twofold-change threshold.'
Set-ParameterTip $deAdvancedPackageButton 'Configure named, typed arguments for the selected DESeq2, edgeR, or limma-voom package functions. Exact options and effective calls are retained in the run log.'
Set-ParameterTip $deExampleButton 'Open a bundled example workbook showing the required differential-expression input structure.'
Set-ParameterTip $deManualExcelButton 'Open the in-application input grid. Pale examples appear in empty cells immediately; use the current data directly or optionally import/export an Excel workbook.'
Set-ParameterTip $deScanFolderButton 'Select a completed RNA Processing Results folder. The software searches only that folder tree for raw integer counts, sample metadata, and optional gene coordinates.'

$deCountFileTip = @'
ACCEPTED INPUT
Files: .tsv, .txt, or .csv.
Structure: first column = unique gene IDs; remaining columns = raw non-negative integer counts, one column per sample.
Sample column names must match the sample IDs in the metadata table.
Do not use TPM, FPKM, CPM, percentages, or already normalized expression values.
'@
Set-InputPathTip @($deCountText, $deCountBrowse, $deCountLabel) $deCountFileTip

$deMetadataFileTip = @'
ACCEPTED INPUT
Files: .tsv, .txt, or .csv with a header row.
Required: one column of unique sample IDs matching the count-matrix column names and one categorical condition column.
Optional: batch and other metadata columns. At least three biological samples are required in each compared group.
'@
Set-InputPathTip @($deMetadataText, $deMetadataBrowse, $deMetadataLabel) $deMetadataFileTip

$deCoordinateFileTip = @'
OPTIONAL INPUT
Files: .tsv, .txt, or .csv.
Required columns: gene_id, seqid, start, end. Coordinates are 1-based inclusive.
Sequence names should match the reference used in IGV. A strand column may be included but is not required for the DE bedGraph export.
'@
Set-InputPathTip @($deAnnotationText, $deAnnotationBrowse, $deAnnotationLabel) $deCoordinateFileTip

$deOutputFolderTip = @'
OUTPUT LOCATION
Select a writable folder, not a file. The software creates a named Differential Expression analysis subfolder inside it.
Existing folders are accepted; analysis-owned output files are organized inside the generated subfolder.
'@
Set-InputPathTip @($deOutputText, $deOutputBrowse, $deOutputLabel) $deOutputFolderTip

# Build functional controls only for the functional module. Merely opening DE
# must not construct, reparent, lay out, or bind the hidden GO/KEGG/STRING pages.
if ($script:InitialTab -ne 'de') {
# Enrichment page
$enrichSplit = New-Object System.Windows.Forms.SplitContainer
$enrichSplit.Dock = [System.Windows.Forms.DockStyle]::Fill
$enrichSplit.Panel2Collapsed = $true
$pageEnrichment.Controls.Add($enrichSplit)
$enrichLeftHost = New-Object System.Windows.Forms.Panel
$enrichLeftHost.Dock = [System.Windows.Forms.DockStyle]::Fill
$enrichLeftHost.BackColor = $background
$enrichSplit.Panel1.Controls.Add($enrichLeftHost)
$enrichInputPanel = New-FlowPanel
$enrichInputPanel.Padding = New-Object System.Windows.Forms.Padding(4)
$enrichInputPanel.AutoScroll = $true
$enrichLeftHost.Controls.Add($enrichInputPanel)
$enrichRight = New-FlowPanel
$enrichRight.BackColor = $surface
$enrichSplit.Panel2.Controls.Add($enrichRight)

$enrichInputGroup = New-Group '1. Enrichment and co-expression inputs' 0 226
$enrichResultLabel = New-Label 'Differential-expression result' 16 29 180 24
$enrichResultText = New-TextBox 205 27 210
$enrichResultBrowse = New-Button 'Browse' 425 25 68 29
$useLastDEButton = New-Button 'Use latest DE analysis results' 452 144 190 29
# Mapping and scan controls follow the three co-expression inputs added below.
$enrichOfflineMapping = New-CheckBox 'Gene-to-term mapping (offline)' 16 146 210 $false
$enrichOnlineAnnotation = New-CheckBox 'Gene-to-term mapping (online)' 234 146 210 $true
$enrichUniverseLabel = New-Label 'Custom universe (optional)' 16 107 180 24
$enrichUniverseText = New-TextBox 205 105 210
$enrichUniverseBrowse = New-Button 'Browse' 425 103 68 29
$enrichOutputLabel = New-Label 'Combined results folder' 620 68 180 24
$enrichOutputText = New-TextBox 805 66 210
$enrichOutputBrowse = New-Button 'Browse' 1025 64 68 29
$enrichExampleButton = New-Button 'Open combined example' 605 144 165 29
$enrichExampleButton.Visible = $false
$enrichManualExcelButton = New-Button 'Manual Excel input' 605 180 175 29
$enrichScanFolderButton = New-Button 'Scan DE / functional folder' 788 180 250 29
$enrichInputGroup.Controls.AddRange(@($enrichResultLabel, $enrichResultText, $enrichResultBrowse, $useLastDEButton, $enrichExampleButton, $enrichManualExcelButton, $enrichScanFolderButton, $enrichOfflineMapping, $enrichOnlineAnnotation, $enrichUniverseLabel, $enrichUniverseText, $enrichUniverseBrowse, $enrichOutputLabel, $enrichOutputText, $enrichOutputBrowse))
$enrichInputPanel.Controls.Add($enrichInputGroup)

$enrichAnnotationGroup = New-Group '2. Gene-to-term mapping details' 0 68
$enrichMappingLabel = New-Label 'Mapping file' 16 29 180 24
$enrichMappingText = New-TextBox 205 27 370
$enrichMappingBrowse = New-Button 'Browse' 585 25 68 29
$enrichAnnotationModeLabel = New-Label 'Identify genes by' 16 29 105 24
$enrichAnnotationModeCombo = New-ComboBox 125 27 190 @('Gene/locus-tag IDs', 'Protein FASTA', 'CDS nucleotide FASTA')
$enrichAnnotationDatabaseLabel = New-Label 'Database' 330 29 70 24
$enrichAnnotationDatabaseCombo = New-ComboBox 405 27 250 @('UniProtKB/Swiss-Prot (reviewed)', 'UniProtKB (reviewed + TrEMBL)')
$enrichAnnotationOrganismLabel = New-Label 'Organism name or taxonomy ID' 16 68 180 24
$enrichAnnotationOrganismText = New-OrganismComboBox 205 66 250
$enrichFindOrganism = New-Button 'Find organism' 463 64 122 29
$enrichAnnotationRefresh = New-CheckBox 'Update UniProt library if changed' 343 66 230 $false
Set-ParameterTip $enrichAnnotationRefresh 'Checks the current UniProt release first. If the shared local copy is already current, it is kept and no protein database is downloaded. If UniProt has a newer release, only the affected shared library is refreshed and its DIAMOND index is rebuilt. If the update check cannot connect, the valid local copy is preserved.'
$enrichAnnotationTestButton = New-Button 'Test database connection' 581 64 165 29
$enrichAnnotationSequenceLabel = New-Label 'Sequence FASTA' 16 107 180 24
$enrichAnnotationSequenceText = New-TextBox 205 105 370
$enrichAnnotationSequenceBrowse = New-Button 'Browse' 585 103 68 29
$enrichOrganismWarning = New-Label 'No organism / no taxonomy ID is allowed, but unrestricted matching is less certain. Choose an organism whenever possible for more accurate annotation.' 16 138 760 34 -Bold
$enrichOrganismWarning.ForeColor = $orange
$enrichOrganismWarning.AutoEllipsis = $false
$enrichAnnotationGroup.Controls.AddRange(@($enrichMappingLabel,$enrichMappingText,$enrichMappingBrowse,$enrichAnnotationModeLabel,$enrichAnnotationModeCombo,$enrichAnnotationDatabaseLabel,$enrichAnnotationDatabaseCombo,$enrichAnnotationOrganismLabel,$enrichAnnotationOrganismText,$enrichFindOrganism,$enrichAnnotationSequenceLabel,$enrichAnnotationSequenceText,$enrichAnnotationSequenceBrowse,$enrichAnnotationRefresh,$enrichAnnotationTestButton,$enrichOrganismWarning))
foreach($control in @($enrichAnnotationGroup.Controls)){ $control.Top += 32 }
$enrichAnnotationGroup.Controls.AddRange(@($enrichOfflineMapping,$enrichOnlineAnnotation))
$enrichOnlineAnnotation.SetBounds(16,25,265,25)
$enrichOfflineMapping.SetBounds(295,25,265,25)

$enrichInputPanel.Controls.Add($enrichAnnotationGroup)
$enrichAnnotationGroup.Add_Resize({
    $w = $enrichAnnotationGroup.ClientSize.Width
    $browseLeft = [Math]::Max(470, $w - 82)
    $enrichMappingText.Width = [Math]::Max(170, $browseLeft - $enrichMappingText.Left - 10)
    $enrichMappingBrowse.Left = $browseLeft
    $enrichAnnotationSequenceText.Width = [Math]::Max(170, $browseLeft - $enrichAnnotationSequenceText.Left - 10)
    $enrichAnnotationSequenceBrowse.Left = $browseLeft
    $enrichOrganismWarning.Width = [Math]::Max(320, $w - 32)

    # Organism row, left to right: searchable organism, official taxonomy site,
    # update shared UniProt library, and connection test.
    $rowGap = 8
    $rightPad = 14
    $enrichAnnotationTestButton.Left = [Math]::Max(565, $w - $enrichAnnotationTestButton.Width - $rightPad)
    $enrichAnnotationRefresh.Left = $enrichAnnotationTestButton.Left - $enrichAnnotationRefresh.Width - $rowGap
    $enrichFindOrganism.Left = $enrichAnnotationRefresh.Left - $enrichFindOrganism.Width - $rowGap
    $enrichAnnotationOrganismText.Width = [Math]::Max(105, $enrichFindOrganism.Left - $enrichAnnotationOrganismText.Left - $rowGap)
    $enrichAnnotationDatabaseCombo.Width = [Math]::Max(150, $w - $enrichAnnotationDatabaseCombo.Left - 18)
})

$enrichMethodHelpText = @'
clusterProfiler ORA
Strengths: flexible custom TERM2GENE input for bacterial GO, KEGG, COG, eggNOG, BioCyc, regulons, and laboratory-defined sets; clear tables and plots.
Limitations: requires a thresholded gene list and a correct tested-gene universe; results can change with the DEG cutoff.

fgsea ranked enrichment
Strengths: uses the complete ranked gene list, avoids a hard DEG cutoff, and can detect coordinated modest changes.
Limitations: depends strongly on the ranking statistic, gene-set quality, and duplicated or missing identifiers.

topGO topology-aware analysis
Strengths: accounts for parent-child relationships in the GO graph and can reduce broad redundant GO findings.
Limitations: requires genuine GO identifiers and gene-to-GO mappings; it is not suitable for arbitrary KEGG, COG, BioCyc, or custom sets. Ontology can be BP, MF, CC, or All (BP + MF + CC).
'@
$enrichMethodGroup = New-Group '3. Functional enrichment method and annotation columns' 0 220
$enrichMethodLabel = New-Label 'Method' 16 29 100 24
$enrichMethodCombo = New-ComboBox 125 27 360 @('clusterProfiler ORA', 'fgsea ranked enrichment', 'topGO topology-aware')
$enrichMethodHelp = New-HelpButton 495 27 'Enrichment methods' $enrichMethodHelpText
$enrichSourceLabel = New-Label 'Annotation source' 16 70 120 24
$enrichSourceCombo = New-ComboBox 145 68 160 @('Custom', 'GO', 'KEGG', 'COG', 'eggNOG', 'BioCyc', 'Regulon')
$goOntologyLabel = New-Label 'topGO ontology' 325 70 115 24
$goOntologyCombo = New-ComboBox 445 68 190 @('BP', 'MF', 'CC', 'All (BP + MF + CC)')
$goOntologyCombo.SelectedIndex = 3
$mapGeneLabel = New-Label 'Gene column' 16 109 110 24
$mapGeneText = New-TextBox 130 107 150 'gene_id'
$mapTermLabel = New-Label 'Term column' 310 109 110 24
$mapTermText = New-TextBox 425 107 150 'term_id'
$mapNameLabel = New-Label 'Name column' 16 148 110 24
$mapNameText = New-TextBox 130 146 150 'term_name'
$mapSourceLabel = New-Label 'Source column' 310 148 110 24
$mapSourceText = New-TextBox 425 146 150 'source'
$rankColumnLabel = New-Label 'fgsea rank column' 16 187 120 24
$rankColumnText = New-TextBox 145 185 150 'stat'
$enrichMethodGroup.Controls.AddRange(@($enrichMethodLabel, $enrichMethodCombo, $enrichMethodHelp, $enrichSourceLabel, $enrichSourceCombo, $goOntologyLabel, $goOntologyCombo, $mapGeneLabel, $mapGeneText, $mapTermLabel, $mapTermText, $mapNameLabel, $mapNameText, $mapSourceLabel, $mapSourceText, $rankColumnLabel, $rankColumnText))
$enrichInputPanel.Controls.Add($enrichMethodGroup)
$enrichMethodGroup.Add_Resize({
    $w = $enrichMethodGroup.ClientSize.Width
    $enrichMethodHelp.Left = [Math]::Max(495, $w - 43)
    $enrichMethodCombo.Width = [Math]::Max(250, $enrichMethodHelp.Left - $enrichMethodCombo.Left - 10)
    $half = [int](($w - 42) / 2)
    $rightX = 22 + $half
    foreach ($label in @($goOntologyLabel, $mapTermLabel, $mapSourceLabel)) { $label.Left = $rightX }
    $goOntologyCombo.Left = $rightX + 120
    $mapTermText.Left = $rightX + 115
    $mapSourceText.Left = $rightX + 115
    foreach ($control in @($goOntologyCombo, $mapTermText, $mapSourceText)) { $control.Width = [Math]::Max(100, $w - $control.Left - 18) }
    foreach ($control in @($enrichSourceCombo, $mapGeneText, $mapNameText, $rankColumnText)) { $control.Width = [Math]::Max(120, $half - $control.Left + 12) }
})

$enrichDirectionHelpText = @'
Accepted choices: All, Up, or Down for ORA and topGO. fgsea always uses the complete signed ranking.

Recommended starting choice: All when performing a two-sided functional overview. Use Up or Down only when the biological question explicitly separates activated and repressed programs.

Trade-off: separating directions improves interpretability but reduces the number of genes in each tested list and can reduce power.
'@
$enrichPadjHelpText = @'
Accepted range: greater than 0 through 1.

Recommended starting value: 0.05. Use 0.10 only for clearly labelled exploratory screening.

Trade-off: smaller values provide stronger false-discovery control but return fewer genes and terms. Larger values improve sensitivity while increasing the expected false-positive proportion.
'@
$enrichLfcHelpText = @'
Accepted range: 0 through 50.

Recommended starting value: 1.0 for thresholded ORA, representing a twofold expression change. Use 0 for fgsea because ranking uses all genes.

Trade-off: a larger cutoff emphasizes strong effects but may miss coordinated modest pathway responses.
'@
$minSetHelpText = @'
Accepted range: 1 through 100,000 genes.

Recommended starting value: 3 to 10 for compact bacterial annotations; 3 is the permissive default.

Trade-off: very small sets are unstable and sensitive to one gene. Larger minimums remove sparse terms but can exclude specific regulons or small operons.
'@
$maxSetHelpText = @'
Accepted range: the selected minimum set size through 1,000,000 genes.

Recommended starting value: 500. For a small bacterial genome, values near the number of tested genes are acceptable.

Trade-off: very large sets are broad and less informative. A lower maximum focuses interpretation but can remove genuinely global processes.
'@
# Spacious one-line GO filtering controls. Positions are recalculated from the available width;
# only X coordinates change during resize, avoiding the self-resizing layout loops from older builds.
$enrichSettingsGroup = New-Group '5. Enrichment, module, edge, regulatory, and run settings' 0 232
$enrichSettingsGroup.MinimumSize = [System.Drawing.Size]::new(760, 228)
$enrichDirectionLabel = New-Label 'Direction' 16 31 70 24
$enrichDirectionCombo = New-ComboBox 90 29 98 @('All', 'Up', 'Down')
$enrichDirectionHelp = New-HelpButton 194 30 'Gene-list direction' $enrichDirectionHelpText 22
$enrichPadjLabel = New-Label 'Gene adjusted p' 245 31 110 24
$enrichPadj = New-TextBox 360 29 68 '0.05'
$enrichPadjHelp = New-HelpButton 434 30 'Gene adjusted p-value' $enrichPadjHelpText 22
$enrichLfcLabel = New-Label 'Absolute log2 FC' 495 31 112 24
$enrichLfc = New-TextBox 612 29 68 '1.0'
$enrichLfcHelp = New-HelpButton 686 30 'Absolute log2 fold change' $enrichLfcHelpText 22
$minSetLabel = New-Label 'Minimum set size' 748 31 112 24
$minSet = New-TextBox 865 29 68 '3'
$minSetHelp = New-HelpButton 939 30 'Minimum gene-set size' $minSetHelpText 22
$maxSetLabel = New-Label 'Maximum set size' 1000 31 116 24
$maxSet = New-TextBox 1121 29 68 '500'
$maxSetHelp = New-HelpButton 1195 30 'Maximum gene-set size' $maxSetHelpText 22
$enrichParameterHelp = New-Button 'Parameter guide' 16 72 150 30
$enrichAdvancedPackageButton = New-Button 'Guided package options' 194 72 210 30
$runEnrichmentButton = New-Button 'Run combined analysis' 412 71 190 32 -Primary
foreach ($actionButton in @($enrichParameterHelp, $enrichAdvancedPackageButton, $runEnrichmentButton)) {
    $actionButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $actionButton.AutoEllipsis = $false
    $actionButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
}
$enrichSettingsGroup.Controls.AddRange(@($enrichDirectionLabel, $enrichDirectionCombo, $enrichDirectionHelp, $enrichPadjLabel, $enrichPadj, $enrichPadjHelp, $enrichLfcLabel, $enrichLfc, $enrichLfcHelp, $minSetLabel, $minSet, $minSetHelp, $maxSetLabel, $maxSet, $maxSetHelp, $enrichParameterHelp, $enrichAdvancedPackageButton, $runEnrichmentButton))
$enrichInputPanel.Controls.Add($enrichSettingsGroup)
$layoutEnrichmentGeneSet = {
    $w = [Math]::Max(800, $enrichSettingsGroup.ClientSize.Width)
    $left = 16
    $right = [Math]::Max($left + 760, $w - 18)
    $slot = [Math]::Max(202, [int](($right - $left) / 5))
    $groups = @(
        @($enrichDirectionLabel,$enrichDirectionCombo,$enrichDirectionHelp,70,98),
        @($enrichPadjLabel,$enrichPadj,$enrichPadjHelp,110,68),
        @($enrichLfcLabel,$enrichLfc,$enrichLfcHelp,112,68),
        @($minSetLabel,$minSet,$minSetHelp,112,68),
        @($maxSetLabel,$maxSet,$maxSetHelp,116,68)
    )
    for($i=0;$i -lt $groups.Count;$i++) {
        $g=$groups[$i]; $x=$left + ($i*$slot)
        $g[0].Left=$x; $g[0].Width=[int]$g[3]
        $g[1].Left=$x+[int]$g[3]+8; $g[1].Width=[int]$g[4]
        $g[2].Left=$g[1].Right+6
    }
}.GetNewClosure()
$enrichSettingsGroup.Add_SizeChanged($layoutEnrichmentGeneSet)
& $layoutEnrichmentGeneSet
$enrichGuidanceText = @'
ONE COMPLETE WORKFLOW
Use Scan DE / functional folder, Use latest DE analysis results, or Manual Excel input to populate the differential-expression result, normalized expression matrix, sample metadata, optional regulator list, mapping, and universe. The software prepares annotation once, then reuses it for both enrichment and module/network interpretation.

FUNCTIONAL ENRICHMENT
Method: ORA uses thresholded genes; fgsea uses every ranked gene; topGO is only for genuine GO mappings.
Ranking statistic: for fgsea use a signed numeric statistic such as a Wald or likelihood-ratio statistic; do not use absolute values.
Direction: All, Up, or Down for ORA/topGO; fgsea uses the full signed ranking.
Gene adjusted p: >0-1; 0.05 recommended. Absolute log2 FC: 0-50; 1.0 recommended for thresholded ORA.
Gene-set size: 3-10 minimum is practical for bacteria; 500 is a useful maximum default.
Background universe: use all tested and mappable genes unless a justified custom universe is supplied.

CO-EXPRESSION AND NETWORKS
The normalized expression matrix and sample metadata are required because correlations must be calculated across samples; they cannot be reconstructed from a differential-expression table alone.
Section 4 lets you choose CEMiTool automatic modules, WGCNA advanced modules, or GENIE3 regulatory inference. Method-specific controls are enabled automatically, and the selected method is passed unchanged to the combined analysis.
Keep log2(x + 1) selected for non-negative normalized counts or CPM; clear it for VST, rlog, voom, z-scores, or negative values.
At least 20 independent samples are recommended. Below 15 samples, exploratory mode is selected automatically and the result must be treated as hypothesis-generating.

OUTPUT
Run all analyses executes annotation, GO/gene-set enrichment, the selected co-expression/network method, online KEGG pathway enrichment, and STRING PPI from the same selected genes. All completed tables and plots are combined into one Excel workbook and one interactive HTML report. If one online database is unavailable, that status is recorded while the completed core analyses are preserved.
'@
$enrichParameterHelp.Add_Click({ Show-StructuredGuideDialog $enrichGuidanceText 'Parameter guide' })
$enrichAdvancedPackageButton.Add_Click({ Show-AdvancedPackageOptions 'combined' })
Set-ParameterTip $enrichMethodCombo 'ORA for a thresholded list, fgsea for a complete signed ranking, or topGO for GO topology-aware analysis. fgsea also exports running-ES profiles, multi-term ES overlays, global ES distribution, and NES-versus-significance diagnostics for GO, KEGG, or other mapped gene sets.'
Set-ParameterTip $enrichSourceCombo 'Records or filters the annotation source. Custom accepts any mapped gene set.'
Set-ParameterTip $enrichOfflineMapping 'Use a local gene-to-term mapping table or GMT file. Selecting this option reveals only the mapping-file row, keeping the page compact.'
Set-ParameterTip $enrichOnlineAnnotation 'Build gene-to-term mapping online instead of supplying a local mapping file. The software first reuses RNA-processing annotation aliases, then organism-specific UniProtKB, and automatically falls back to retained reference sequences with DIAMOND when needed.'
Set-ParameterTip $enrichAnnotationOrganismText 'Type an organism or choose a common bacterium. No organism / no taxonomy ID allows unrestricted matching, but cross-species results are less certain; an organism or taxonomy ID is strongly recommended.'
Set-ParameterTip $enrichFindOrganism 'Open NCBI Taxonomy to find the exact organism name or taxonomy ID, then paste it into the organism box.'
Set-ParameterTip $enrichAnnotationSequenceText 'Protein FASTA uses DIAMOND blastp and CDS nucleotide FASTA uses DIAMOND blastx. FASTA identifiers are reconciled to DE gene_id values through retained RNA-processing aliases when available.'
Set-ParameterTip $mapGeneText 'Exact mapping-file column containing gene identifiers.'
Set-ParameterTip $mapTermText 'Exact mapping-file column containing GO terms, pathway IDs, COGs, regulons, or custom set IDs.'
Set-ParameterTip $mapNameText 'Optional readable term-name column.'
Set-ParameterTip $mapSourceText 'Optional source column used to distinguish GO, KEGG, COG, eggNOG, BioCyc, regulons, and custom sets.'
Set-ParameterTip $goOntologyCombo 'BP, MF, CC, or All (BP + MF + CC). All runs the three topGO ontology graphs and combines the results with one BH adjustment across the combined table.'
Set-ParameterTip $rankColumnText 'Signed numeric ranking statistic for fgsea. The default DE output provides stat.'
Set-ParameterTip $enrichDirectionCombo 'All, Up, or Down for thresholded ORA/topGO. fgsea uses the full signed ranking.'
Set-ParameterTip $enrichPadj 'Accepted range greater than 0 through 1. Recommended 0.05.'
Set-ParameterTip $enrichAdvancedPackageButton 'Configure the documented functions for both the selected enrichment method and selected network method in one dialog. Both sets of exact overrides are retained in the combined run log.'
Set-ParameterTip $runEnrichmentButton 'One click runs shared annotation, enrichment, co-expression/network inference, online KEGG pathway enrichment, and STRING PPI, then combines all completed results in one workbook and one interactive report.'
Set-ParameterTip $enrichExampleButton 'Open one workbook containing the DE result, normalized expression, sample metadata, optional regulators, gene-to-term mapping, and optional universe required by the combined workflow.'
Set-ParameterTip $enrichManualExcelButton 'Open the in-application input grid for DE, expression, metadata, mapping, universe, and regulator tables. Pale examples appear immediately and Excel import/export is optional.'
Set-ParameterTip $enrichScanFolderButton 'Select a Differential Expression or Functional Enrichment results folder. Only that folder tree is scanned for DE, normalized expression, metadata, mapping, universe, and regulator files.'
Set-ParameterTip $useLastDEButton 'Load the latest differential-expression result together with its normalized expression matrix and sample metadata. Optional mapping, universe, and regulator files are also loaded when available.'
Set-ParameterTip $enrichLfc 'Accepted range 0-50. Recommended 1.0 for thresholded enrichment.'
Set-ParameterTip $minSet 'Accepted range 1-100,000. Recommended 3-10 for compact bacterial gene sets.'
Set-ParameterTip $maxSet 'Accepted range from the minimum set size through 1,000,000. Recommended 500.'

$enrichResultFileTip = @'
ACCEPTED INPUT
Files: .tsv, .txt, or .csv differential-expression result tables.
Recommended columns: gene_id, padj, log2FoldChange, and stat. Common adjusted-p and fold-change alternatives are also detected.
For fgsea, provide a signed numeric ranking statistic; the software uses stat by default.
'@
Set-InputPathTip @($enrichResultText, $enrichResultBrowse, $enrichResultLabel) $enrichResultFileTip

$enrichMappingFileTip = @'
ACCEPTED INPUT
Files: .tsv, .txt, .csv, or .gmt.
Delimited tables need at least gene and term columns; defaults are gene_id and term_id. term_name and source are optional.
GMT format: term ID, term name/description, then one or more gene IDs on the same tab-delimited line.
Not required when Gene-to-term mapping (online) is enabled.
'@
Set-InputPathTip @($enrichMappingText, $enrichMappingBrowse, $enrichMappingLabel) $enrichMappingFileTip

$enrichUniverseFileTip = @'
OPTIONAL INPUT
Files: .tsv, .txt, or .csv.
The first column must contain gene IDs for the tested background universe. Additional columns are ignored.
Use all tested and mappable genes unless there is a justified reason to supply a custom universe.
'@
Set-InputPathTip @($enrichUniverseText, $enrichUniverseBrowse, $enrichUniverseLabel) $enrichUniverseFileTip

$enrichSequenceFileTip = @'
ONLINE ANNOTATION INPUT
Files: .fa, .fasta, .faa, .fna, .fa.gz, or .fasta.gz.
Protein FASTA is searched with DIAMOND blastp; CDS nucleotide FASTA is searched with DIAMOND blastx.
FASTA record identifiers are reconciled to differential-expression gene_id values through retained RNA-processing aliases when available.
'@
Set-InputPathTip @($enrichAnnotationSequenceText, $enrichAnnotationSequenceBrowse, $enrichAnnotationSequenceLabel) $enrichSequenceFileTip

$enrichOutputFolderTip = @'
OUTPUT LOCATION
Select one writable folder, not a file. The software creates one Functional enrichment and co-expression analysis subfolder inside it.
Enrichment, co-expression, pathway, and STRING results are organized together in one verified Excel workbook and one combined interactive HTML report inside that subfolder.
'@
Set-InputPathTip @($enrichOutputText, $enrichOutputBrowse, $enrichOutputLabel) $enrichOutputFolderTip

$openEnrichmentStudioButton = New-Button 'Open interactive results' 0 0 202 32
$openEnrichmentStudioButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
Set-ParameterTip $openEnrichmentStudioButton 'Opens the one self-contained report containing both functional enrichment and co-expression/network results.'
$enrichSettingsGroup.Controls.Add($openEnrichmentStudioButton)

# Network page
$networkSplit = New-Object System.Windows.Forms.SplitContainer
$networkSplit.Dock = [System.Windows.Forms.DockStyle]::Fill
$networkSplit.Panel2Collapsed = $true
$pageNetwork.Controls.Add($networkSplit)
$networkLeftHost = New-Object System.Windows.Forms.Panel
$networkLeftHost.Dock = [System.Windows.Forms.DockStyle]::Fill
$networkLeftHost.BackColor = $background
$networkSplit.Panel1.Controls.Add($networkLeftHost)
$networkInputPanel = New-FlowPanel
$networkInputPanel.Padding = New-Object System.Windows.Forms.Padding(4)
$networkLeftHost.Controls.Add($networkInputPanel)
$networkRight = New-FlowPanel
$networkRight.BackColor = $surface
$networkSplit.Panel2.Controls.Add($networkRight)

$networkInputGroup = New-Group '1. Expression matrix, metadata, and optional regulators' 0 222
$networkExprLabel = New-Label 'Normalized expression matrix' 16 29 190 24
$networkExprText = New-TextBox 215 27 205
$networkExprBrowse = New-Button 'Browse' 430 25 68 29
$useLastNormalizedButton = New-Button 'Use latest normalized counts' 508 25 185 29
$networkMetadataLabel = New-Label 'Sample metadata' 16 68 190 24
$networkMetadataText = New-TextBox 215 66 390
$networkMetadataBrowse = New-Button 'Browse' 615 64 68 29
$networkRegulatorLabel = New-Label 'Regulator list (GENIE3 optional)' 16 107 190 24
$networkRegulatorText = New-TextBox 215 105 390
$networkRegulatorBrowse = New-Button 'Browse' 615 103 68 29
$networkOutputLabel = New-Label 'Results folder' 16 146 190 24
$networkOutputText = New-TextBox 215 144 390
$networkOutputBrowse = New-Button 'Browse' 615 142 68 29
$networkExampleButton = New-Button 'Open example workbook' 215 180 165 29
$networkScanFolderButton = New-Button 'Scan DE / functional folder' 390 180 220 29
$networkInputGroup.Controls.AddRange(@($networkExprLabel, $networkExprText, $networkExprBrowse, $useLastNormalizedButton, $networkMetadataLabel, $networkMetadataText, $networkMetadataBrowse, $networkRegulatorLabel, $networkRegulatorText, $networkRegulatorBrowse, $networkOutputLabel, $networkOutputText, $networkOutputBrowse, $networkExampleButton, $networkScanFolderButton))
$networkInputPanel.Controls.Add($networkInputGroup)
$networkInputGroup.Add_Resize({
    $w = $networkInputGroup.ClientSize.Width
    $latestLeft = [Math]::Max(360, $w - $useLastNormalizedButton.Width - 14)
    $browseLeft = $latestLeft - $networkExprBrowse.Width - 10
    $networkExprText.Width = [Math]::Max(120, $browseLeft - $networkExprText.Left - 10)
    $networkExprBrowse.Left = $browseLeft
    $useLastNormalizedButton.Left = $latestLeft
    $otherBrowseLeft = [Math]::Max(470, $w - 82)
    foreach ($box in @($networkMetadataText, $networkRegulatorText, $networkOutputText)) { $box.Width = [Math]::Max(170, $otherBrowseLeft - $box.Left - 10) }
    foreach ($button in @($networkMetadataBrowse, $networkRegulatorBrowse, $networkOutputBrowse)) { $button.Left = $otherBrowseLeft }
    $networkExampleButton.Left = 215
    $networkScanFolderButton.Left = $networkExampleButton.Right + 10
})

$networkAnnotationGroup = New-Group '2. Functional annotation (optional)' 0 52
$networkOnlineAnnotation = New-CheckBox 'Annotate network genes from online databases' 16 26 320 $false
$networkAnnotationModeLabel = New-Label 'Identify genes by' 16 66 105 24
$networkAnnotationModeCombo = New-ComboBox 125 64 190 @('Gene/locus-tag IDs', 'Protein FASTA', 'CDS nucleotide FASTA')
$networkAnnotationDatabaseLabel = New-Label 'Database' 330 66 70 24
$networkAnnotationDatabaseCombo = New-ComboBox 405 64 250 @('UniProtKB/Swiss-Prot (reviewed)', 'UniProtKB (reviewed + TrEMBL)')
$networkAnnotationOrganismLabel = New-Label 'Organism name or taxonomy ID' 16 105 180 24
$networkAnnotationOrganismText = New-OrganismComboBox 205 103 250
$networkAnnotationSequenceLabel = New-Label 'Sequence FASTA' 16 144 180 24
$networkAnnotationSequenceText = New-TextBox 205 142 370
$networkAnnotationSequenceBrowse = New-Button 'Browse' 585 140 68 29
$networkAnnotationRefresh = New-CheckBox 'Update shared UniProt library if changed' 16 178 330 $false
Set-ParameterTip $networkAnnotationRefresh 'Checks the current UniProt release first. If the shared local copy is already current, it is kept and no protein database is downloaded. If UniProt has a newer release, only the affected shared library is refreshed and its DIAMOND index is rebuilt. If the update check cannot connect, the valid local copy is preserved.'
$networkAnnotationTestButton = New-Button 'Test database connection' 400 174 190 31
$networkAnnotationGroup.Controls.AddRange(@($networkOnlineAnnotation,$networkAnnotationModeLabel,$networkAnnotationModeCombo,$networkAnnotationDatabaseLabel,$networkAnnotationDatabaseCombo,$networkAnnotationOrganismLabel,$networkAnnotationOrganismText,$networkAnnotationSequenceLabel,$networkAnnotationSequenceText,$networkAnnotationSequenceBrowse,$networkAnnotationRefresh,$networkAnnotationTestButton))
$networkInputPanel.Controls.Add($networkAnnotationGroup)
$networkAnnotationGroup.Add_Resize({
    $w = $networkAnnotationGroup.ClientSize.Width
    $browseLeft = [Math]::Max(470, $w - 82)
    $networkAnnotationSequenceText.Width = [Math]::Max(170, $browseLeft - $networkAnnotationSequenceText.Left - 10)
    $networkAnnotationSequenceBrowse.Left = $browseLeft
    $networkAnnotationTestButton.Left = [Math]::Max(350, $w - $networkAnnotationTestButton.Width - 14)
    $networkAnnotationDatabaseCombo.Width = [Math]::Max(150, $w - $networkAnnotationDatabaseCombo.Left - 18)
})

$networkMethodHelpText = @'
CEMiTool automatic modules  -  recommended guided mode
Strengths: automates filtering, module detection, activity summaries, and reporting; easiest starting point for users who want reproducible modules with fewer technical choices.
Limitations: offers less control than WGCNA and still requires enough independent samples; modules are co-expression, not confirmed regulation.

WGCNA advanced modules
Strengths: transparent control of soft threshold, signed/unsigned networks, module size, and module-trait analysis; widely accepted.
Limitations: at least 15 samples are required here and 20 or more are preferable; memory and runtime increase with gene number; results are sensitive to outliers and preprocessing.

GENIE3 regulatory inference
Strengths: predicts directed regulator-to-target rankings and can incorporate a supplied bacterial transcription-factor list.
Limitations: computationally intensive, sensitive to sample size and regulator quality, and produces hypotheses rather than validated regulatory edges.
'@
$networkMethodGroup = New-Group '3. Network method and preprocessing' 0 194
$networkMethodLabel = New-Label 'Method' 16 29 100 24
$networkMethodCombo = New-ComboBox 125 27 360 @('CEMiTool automatic modules', 'WGCNA advanced modules', 'GENIE3 regulatory inference')
$networkMethodHelp = New-HelpButton 495 27 'Network methods' $networkMethodHelpText
$networkSampleColumnLabel = New-Label 'Sample ID column' 16 70 120 24
$networkSampleColumnCombo = New-ComboBox 145 68 155 @()
$networkCorrelationLabel = New-Label 'Edge correlation' 320 70 110 24
$networkCorrelationCombo = New-ComboBox 435 68 120 @('Pearson', 'Spearman')
$networkTypeLabel = New-Label 'WGCNA type' 16 109 120 24
$networkTypeCombo = New-ComboBox 145 107 155 @('Signed', 'Unsigned')
$softPowerLabel = New-Label 'Soft power' 320 109 110 24
$softPowerText = New-TextBox 435 107 120 'auto'
$maxGenesLabel = New-Label 'Maximum genes' 16 148 120 24
$maxGenesText = New-TextBox 145 146 155 '5000'
$networkLogTransform = New-Object System.Windows.Forms.CheckBox
$networkLogTransform.Text = 'Apply log2(x + 1) before network analysis'
$networkLogTransform.Location = [System.Drawing.Point]::new(320, 146)
$networkLogTransform.Size = [System.Drawing.Size]::new(300, 25)
$networkLogTransform.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
$networkLogTransform.Checked = $true
$networkMethodGroup.Controls.AddRange(@($networkMethodLabel, $networkMethodCombo, $networkMethodHelp, $networkSampleColumnLabel, $networkSampleColumnCombo, $networkCorrelationLabel, $networkCorrelationCombo, $networkTypeLabel, $networkTypeCombo, $softPowerLabel, $softPowerText, $maxGenesLabel, $maxGenesText, $networkLogTransform))
$networkInputPanel.Controls.Add($networkMethodGroup)
$networkMethodGroup.Add_Resize({
    $w = $networkMethodGroup.ClientSize.Width
    $networkMethodHelp.Left = [Math]::Max(495, $w - 43)
    $networkMethodCombo.Width = [Math]::Max(250, $networkMethodHelp.Left - $networkMethodCombo.Left - 10)
    $half = [int](($w - 42) / 2)
    $rightX = 22 + $half
    foreach ($label in @($networkCorrelationLabel, $softPowerLabel)) { $label.Left = $rightX }
    foreach ($control in @($networkCorrelationCombo, $softPowerText)) { $control.Left = $rightX + 115; $control.Width = [Math]::Max(105, $w - $control.Left - 18) }
    foreach ($control in @($networkSampleColumnCombo, $networkTypeCombo, $maxGenesText)) { $control.Width = [Math]::Max(120, $half - $control.Left + 12) }
    $networkLogTransform.Left = $rightX
    $networkLogTransform.Width = [Math]::Max(220, $w - $rightX - 18)
})

$networkSettingsGroup = New-Group '4. Co-expression settings' 0 106
$minModuleHelpText = @'
Accepted range: 5 through 5,000 genes.

Recommended starting value: 20 for bacterial genomes.

Trade-off: smaller modules recover compact pathways and regulons but are less stable. Larger modules are more robust but can merge distinct biological programs.
'@
$edgeThresholdHelpText = @'
Accepted range: 0 through 1.

Recommended starting value: 0.70 for exported co-expression edges.

Trade-off: lower thresholds retain more weak relationships and rapidly create dense, noisy networks. Higher thresholds improve specificity but can disconnect genuine modules.
'@
$maxEdgesHelpText = @'
Accepted range: 100 through 10,000,000 edges.

Recommended starting value: 5,000.

Trade-off: more edges preserve information for downstream tables but make interactive networks slower and harder to interpret. This limit affects exported edges, not the fitted model itself.
'@
$nTreesHelpText = @'
Accepted range: 100 through 10,000 trees.

Recommended starting value: 1,000 for GENIE3.

Trade-off: more trees improve stability but increase runtime and memory use. Values below 500 are best treated as quick exploratory runs.
'@
$threadsHelpText = @'
Accepted range: 1 through 128 threads, subject to the available processor count.

Recommended starting value: 4 or the number of cores you can spare without making the computer unresponsive.

Trade-off: more threads can reduce GENIE3 runtime but increase memory pressure and may provide diminishing speed gains.
'@
# Spacious network settings. Full labels are retained; controls are distributed across the available width.
$minModuleLabel = New-Label 'Minimum module size' 16 31 132 24
$minModuleText = New-TextBox 152 29 64 '20'
$minModuleHelp = New-HelpButton 222 30 'Minimum module size' $minModuleHelpText 22
$edgeThresholdLabel = New-Label 'Edge threshold' 270 31 96 24
$edgeThresholdText = New-TextBox 370 29 64 '0.70'
$edgeThresholdHelp = New-HelpButton 440 30 'Edge threshold' $edgeThresholdHelpText 22
$maxEdgesLabel = New-Label 'Maximum exported edges' 488 31 150 24
$maxEdgesText = New-TextBox 642 29 72 '5000'
$maxEdgesHelp = New-HelpButton 720 30 'Maximum exported edges' $maxEdgesHelpText 22
$nTreesLabel = New-Label 'GENIE3 trees' 768 31 96 24
$nTreesText = New-TextBox 868 29 72 '1000'
$nTreesHelp = New-HelpButton 946 30 'GENIE3 trees' $nTreesHelpText 22
$threadsLabel = New-Label 'CPU threads' 994 31 88 24
$threadsText = New-TextBox 1086 29 64 '4'
$threadsHelp = New-HelpButton 1156 30 'CPU threads' $threadsHelpText 22
$networkExploratory = New-Object System.Windows.Forms.CheckBox
$networkExploratory.Text = 'Exploratory mode below 15 samples'
$networkExploratory.Location = [System.Drawing.Point]::new(16, 66)
$networkExploratory.Size = [System.Drawing.Size]::new(242, 28)
$networkExploratory.Font = New-Object System.Drawing.Font('Segoe UI', [single]8.75, [System.Drawing.FontStyle]::Regular)
$networkExploratory.AutoEllipsis = $false
$networkExploratory.Checked = $true
$networkAutoModules = New-CheckBox 'Automatic module detection enabled' 252 66 290 $true
$networkAutoModules.AutoCheck = $false
$networkParameterHelp = New-Button 'Parameter guide' 700 65 118 30
$networkAdvancedPackageButton = New-Button 'Guided package options' 826 65 184 30
$networkAdvancedPackageButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$runNetworkButton = New-Button 'Run network analysis' 1008 64 188 32 -Primary
$runNetworkButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$networkSettingsGroup.Controls.AddRange(@($minModuleLabel, $minModuleText, $minModuleHelp, $edgeThresholdLabel, $edgeThresholdText, $edgeThresholdHelp, $maxEdgesLabel, $maxEdgesText, $maxEdgesHelp, $nTreesLabel, $nTreesText, $nTreesHelp, $threadsLabel, $threadsText, $threadsHelp, $networkExploratory, $networkParameterHelp, $networkAdvancedPackageButton, $runNetworkButton))
$networkAutoModules.Location = [System.Drawing.Point]::new(16, 178)
$networkAutoModules.Width = 360
$networkMethodGroup.Height = 222
$networkMethodGroup.Controls.Add($networkAutoModules)
$networkInputPanel.Controls.Add($networkSettingsGroup)
$layoutNetworkSettings = {
    $w=[Math]::Max(900,$networkSettingsGroup.ClientSize.Width)
    $left=16; $right=[Math]::Max(850,$w-18)
    $widths=@(210,190,245,190,175)
    $fixed=0; foreach($n in $widths){$fixed+=$n}
    $gap=[Math]::Max(14,[int](($right-$left-$fixed)/4))
    $x=$left
    $defs=@(
      @($minModuleLabel,$minModuleText,$minModuleHelp,132,64,$widths[0]),
      @($edgeThresholdLabel,$edgeThresholdText,$edgeThresholdHelp,96,64,$widths[1]),
      @($maxEdgesLabel,$maxEdgesText,$maxEdgesHelp,150,72,$widths[2]),
      @($nTreesLabel,$nTreesText,$nTreesHelp,96,72,$widths[3]),
      @($threadsLabel,$threadsText,$threadsHelp,88,64,$widths[4])
    )
    foreach($d in $defs){
      $d[0].Left=$x; $d[0].Width=[int]$d[3]
      $d[1].Left=$x+[int]$d[3]+6; $d[1].Width=[int]$d[4]
      $d[2].Left=$d[1].Right+6
      $x += [int]$d[5] + $gap
    }
    # Action buttons are positioned by the dedicated action-row layout below.
    # Keeping them out of this earlier size handler prevents two independent
    # resize handlers from fighting over Parameter guide / Interactive report.
}.GetNewClosure()
$networkSettingsGroup.Add_SizeChanged($layoutNetworkSettings)
& $layoutNetworkSettings
$networkGuidanceText = @'
Sample ID: must exactly match expression-matrix sample columns.
Log transform: keep selected for non-negative normalized counts or CPM; clear for VST, rlog, voom, z-scores, or any negative values.
Correlation: Pearson is suited to approximately linear profiles; Spearman is more resistant to monotonic outliers.
WGCNA type: Signed is recommended because negative correlations are not treated as equivalent to positive co-expression.
Soft power: auto is recommended, or use an integer from 1 to 30.
Maximum genes: 100-50,000; 5,000 is practical for a workstation.
Minimum module size: 5-5,000; 20 is recommended for bacterial genomes.
Edge threshold: 0-1; 0.70 is recommended for exported co-expression edges.
Maximum exported edges: 100-10,000,000; 5,000 keeps plots readable.
GENIE3 trees: 100-10,000; 1,000 is recommended.
CPU threads: 1-128; 4 is conservative.
Exploratory sample size: below 15 samples the combined workflow selects exploratory mode automatically; 20 or more independent samples are preferable.
'@
$networkParameterHelp.Add_Click({ Show-StructuredGuideDialog $networkGuidanceText 'Network parameter guide' })
$networkAdvancedPackageButton.Add_Click({ Show-AdvancedPackageOptions 'network' })
Set-ParameterTip $networkMethodCombo 'CEMiTool for automated modules, WGCNA for detailed co-expression control, or GENIE3 for directed regulator-target predictions. CEMiTool/WGCNA runs also export a module expression Z-score heatmap with functional-enrichment labels and per-module expression trend panels without changing the inferred network.'
Set-ParameterTip $networkSampleColumnCombo 'Metadata column containing unique sample IDs that match expression-matrix sample columns.'
Set-ParameterTip $networkCorrelationLabel 'Pearson is suited to approximately linear profiles. Spearman is more resistant to monotonic outliers.'
Set-ParameterTip $networkCorrelationCombo 'Pearson is suited to approximately linear profiles. Spearman is more resistant to monotonic outliers.'
Set-ParameterTip $networkTypeCombo 'Signed is recommended. Unsigned treats strong negative and positive correlations similarly.'
Set-ParameterTip $softPowerText 'Use auto or an integer from 1 to 30. Auto is recommended.'
Set-ParameterTip $maxGenesText 'Accepted range 100-50,000. Recommended 5,000 for a typical workstation.'
Set-ParameterTip $networkLogTransform 'Select only for non-negative normalized counts or CPM. Clear for VST, rlog, voom, z-scores, or negative values.'
Set-ParameterTip $minModuleText 'Accepted range 5-5,000. Recommended 20.'
Set-ParameterTip $edgeThresholdText 'Accepted range 0-1. Recommended 0.70 for exported co-expression edges.'
Set-ParameterTip $maxEdgesText 'Accepted range 100-10,000,000. Recommended 5,000.'
Set-ParameterTip $nTreesText 'Accepted range 100-10,000. Recommended 1,000 for GENIE3.'
Set-ParameterTip $threadsText 'Accepted range 1-128. Recommended 4 or the number of CPU cores you can spare.'
Set-ParameterTip $networkExploratory 'Allows a warning-labelled co-expression run below 15 samples. Results may be unstable and should not be treated as confirmatory.'
Set-ParameterTip $networkAutoModules 'Enabled by default. CEMiTool determines modules automatically; WGCNA uses dynamic tree cutting and module merging. Detected module display names can be edited later in the interactive report.'
Set-ParameterTip $networkAdvancedPackageButton 'Configure named, typed arguments for the selected WGCNA, CEMiTool, or GENIE3 functions. Exact options and effective calls are retained in the run log.'
Set-ParameterTip $networkExampleButton 'Open a bundled example workbook showing the required network input structure.'
Set-ParameterTip $networkScanFolderButton 'Select a Results folder. The software searches it recursively for normalized_counts.tsv, analysis/sample metadata, and an optional regulator list.'
Set-ParameterTip $networkOnlineAnnotation 'When selected, gene functions and GO terms are added to network nodes and GO enrichment is calculated for detected modules when annotations are available.'
Set-ParameterTip $networkAnnotationOrganismText 'Type an organism or choose a common bacterium. No organism / no taxonomy ID enables a lower-confidence unrestricted search; an organism or taxonomy ID is strongly recommended.'
Set-ParameterTip $networkAnnotationSequenceText 'Protein FASTA uses DIAMOND blastp and CDS nucleotide FASTA uses DIAMOND blastx. FASTA identifiers are reconciled to expression-matrix gene_id values through retained RNA-processing aliases when available.'

$networkExpressionFileTip = @'
ACCEPTED INPUT
Files: .tsv, .txt, or .csv.
Structure: first column = unique gene IDs; remaining columns = numeric expression values, one column per sample.
Sample column names must match metadata sample IDs. Use normalized expression; enable log2(x + 1) only for appropriate non-negative values such as normalized counts or CPM.
'@
Set-InputPathTip @($networkExprText, $networkExprBrowse, $networkExprLabel) $networkExpressionFileTip

$networkMetadataFileTip = @'
ACCEPTED INPUT
Files: .tsv, .txt, or .csv with a header row.
Required: one column of unique sample IDs matching the expression-matrix sample columns.
Optional: condition, batch, phenotype, time point, or other sample-trait columns for downstream module-trait interpretation.
'@
Set-InputPathTip @($networkMetadataText, $networkMetadataBrowse, $networkMetadataLabel) $networkMetadataFileTip

$networkRegulatorFileTip = @'
OPTIONAL GENIE3 INPUT
Files: .tsv, .txt, or .csv.
The first column must contain regulator gene IDs; additional columns are ignored.
Regulator IDs must also exist in the expression matrix. This file is used only when the GENIE3 method is selected.
'@
Set-InputPathTip @($networkRegulatorText, $networkRegulatorBrowse, $networkRegulatorLabel) $networkRegulatorFileTip

$networkSequenceFileTip = @'
ONLINE ANNOTATION INPUT
Files: .fa, .fasta, .faa, .fna, .fa.gz, or .fasta.gz.
Protein FASTA is searched with DIAMOND blastp; CDS nucleotide FASTA is searched with DIAMOND blastx.
FASTA record identifiers are reconciled to expression-matrix gene_id values through retained RNA-processing aliases when available.
'@
Set-InputPathTip @($networkAnnotationSequenceText, $networkAnnotationSequenceBrowse, $networkAnnotationSequenceLabel) $networkSequenceFileTip

$networkOutputFolderTip = @'
OUTPUT LOCATION
Select a writable folder, not a file. The software creates a named Co-expression / Network analysis subfolder inside it.
Existing folders are accepted; generated results are organized inside the analysis subfolder.
'@
Set-InputPathTip @($networkOutputText, $networkOutputBrowse, $networkOutputLabel) $networkOutputFolderTip

$openNetworkStudioButton = New-Button 'Open interactive report' 0 0 176 30
$openNetworkStudioButton.Font = New-Object System.Drawing.Font('Segoe UI', [single]8.75, [System.Drawing.FontStyle]::Bold)
$openNetworkStudioButton.AutoEllipsis = $false
Set-ParameterTip $openNetworkStudioButton 'Generated automatically after a successful network run.'
$networkWarning = New-Group 'Sample-size and interpretation warning' 10 196
$networkWarning.Size = New-Object System.Drawing.Size(700, 58)
$warningTitle = New-Label 'RECOMMENDED: AT LEAST 20 INDEPENDENT SAMPLES' 12 18 650 18 -Bold
$warningTitle.ForeColor = $orange
$warningBody = New-Label 'Below 15 samples requires exploratory mode. Hover here for the full interpretation warning.' 12 36 650 18
$warningBody.Font = New-Object System.Drawing.Font('Segoe UI', [single]8.5)
$networkWarningFullText = 'Below 15 samples, exploratory mode is selected automatically and results are hypothesis-generating. At least 20 independent samples are preferable. Do not build a network only from DEGs; use the appropriately normalized expression matrix. Co-expression is not proof of regulation.'
Set-ParameterTip $networkWarning $networkWarningFullText
Set-ParameterTip $warningTitle $networkWarningFullText
Set-ParameterTip $warningBody $networkWarningFullText
$networkWarning.BackColor = $orangeSoft
$networkWarning.Controls.AddRange(@($warningTitle,$warningBody))
$networkWarning.Add_Resize({
    $inside = [Math]::Max(320, $networkWarning.ClientSize.Width - 24)
    $warningTitle.Width = $inside
    $warningBody.Width = $inside
})
$networkSettingsGroup.Controls.Add($openNetworkStudioButton)
$networkWarning.Margin = New-Object System.Windows.Forms.Padding(0,0,0,4)
$networkInputPanel.Controls.Add($networkWarning)
$networkInputPanel.Controls.SetChildIndex($networkWarning,0)
$layoutNetworkActions = {
    # Keep exploratory mode at the left. On the right use one deterministic
    # action-row layout: Parameter guide -> Open interactive report -> Guided
    # package options -> Run. Explicit gaps and slightly wider controls prevent
    # text overlap at high-DPI Windows scaling.
    $y = 64
    $gap = 8
    $networkExploratory.SetBounds(16,$y,224,28)
    $w = [Math]::Max(900, $networkSettingsGroup.ClientSize.Width)
    $runWidth = 166
    $guidedWidth = 190
    $reportWidth = 170
    $guideWidth = 126
    $runNetworkButton.SetBounds(($w-$runWidth-18),$y-2,$runWidth,32)
    $networkAdvancedPackageButton.SetBounds(($runNetworkButton.Left-$guidedWidth-$gap),$y-1,$guidedWidth,30)
    $openNetworkStudioButton.SetBounds(($networkAdvancedPackageButton.Left-$reportWidth-$gap),$y-1,$reportWidth,30)
    $networkParameterHelp.SetBounds(($openNetworkStudioButton.Left-$guideWidth-$gap),$y-1,$guideWidth,30)
}.GetNewClosure()
$networkSettingsGroup.Add_SizeChanged($layoutNetworkActions)
& $layoutNetworkActions

# The expression matrix and metadata are scientifically required, but they are
# selected only once in section 1. Move those manual fallbacks into the shared
# input card and keep the co-expression section focused only on analysis choices.
$networkExprLabel.Text = 'Normalized expression matrix'
$networkMetadataLabel.Text = 'Sample metadata'
$networkRegulatorLabel.Text = 'Regulator list (optional)'
$useLastDEButton.Text = 'Use latest DE analysis results'
$enrichExampleButton.Text = 'Combined example'
$enrichScanFolderButton.Text = 'Scan DE / functional folder'
$enrichInputGroup.Controls.AddRange(@(
    $networkExprLabel,$networkExprText,$networkExprBrowse,
    $networkMetadataLabel,$networkMetadataText,$networkMetadataBrowse,
    $networkRegulatorLabel,$networkRegulatorText,$networkRegulatorBrowse
))
$enrichInputGroup.MinimumSize = [System.Drawing.Size]::new(760, 180)
$enrichInputGroup.Height = 180
$layoutCombinedInputs = {
    $w = [Math]::Max(760, $enrichInputGroup.ClientSize.Width)
    $outer = 16
    $columnGap = 24
    $half = [int](($w - (2 * $outer) - $columnGap) / 2)
    $rightX = $outer + $half + $columnGap
    $labelWidth = [Math]::Min(180, [Math]::Max(148, [int]($half * 0.36)))
    $browseWidth = 68
    $leftBrowse = $outer + $half - $browseWidth
    $rightBrowse = $w - $outer - $browseWidth
    $leftTextX = $outer + $labelWidth
    $rightTextX = $rightX + $labelWidth
    $leftTextWidth = [Math]::Max(92, $leftBrowse - $leftTextX - 8)
    $rightTextWidth = [Math]::Max(92, $rightBrowse - $rightTextX - 8)

    $leftRows = @(
        @($enrichResultLabel,$enrichResultText,$enrichResultBrowse,29),
        @($networkMetadataLabel,$networkMetadataText,$networkMetadataBrowse,68),
        @($enrichUniverseLabel,$enrichUniverseText,$enrichUniverseBrowse,107)
    )
    foreach ($row in $leftRows) {
        $y = [int]$row[3]
        $row[0].SetBounds($outer,$y,$labelWidth,24)
        $row[1].SetBounds($leftTextX,$y-2,$leftTextWidth,25)
        $row[2].SetBounds($leftBrowse,$y-4,$browseWidth,29)
    }
    $rightRows = @(
        @($networkExprLabel,$networkExprText,$networkExprBrowse,29),
        @($enrichOutputLabel,$enrichOutputText,$enrichOutputBrowse,68),
        @($networkRegulatorLabel,$networkRegulatorText,$networkRegulatorBrowse,107)
    )
    foreach ($row in $rightRows) {
        $y = [int]$row[3]
        $row[0].SetBounds($rightX,$y,$labelWidth,24)
        $row[1].SetBounds($rightTextX,$y-2,$rightTextWidth,25)
        $row[2].SetBounds($rightBrowse,$y-4,$browseWidth,29)
    }

    $useLastDEButton.SetBounds(16,144,240,29)
    $enrichManualExcelButton.SetBounds(264,144,180,29)
    $enrichScanFolderButton.SetBounds(452,144,260,29)

}.GetNewClosure()
$enrichInputGroup.Add_SizeChanged($layoutCombinedInputs)
& $layoutCombinedInputs

# Co-expression uses the same source/database controls and the same run action as
# enrichment. Each detail toggle now belongs to its corresponding method card;
# the compact unnumbered action row avoids a separate fifth settings section.
$combinedNetworkGroup = New-Group '4. Network method and co-expression preprocessing' 0 282
$networkMethodGroup.Text = ''
$networkSettingsGroup.Text = 'Co-expression settings'
$networkMethodCombo.SelectedIndex = 0
$networkAutoModules.Checked = $true
$networkMethodLabel.Visible = $true
$networkMethodCombo.Visible = $true
$networkMethodHelp.Visible = $true
$networkAutoModules.Visible = $true
$networkTypeLabel.Visible = $true
$networkTypeCombo.Visible = $true
$softPowerLabel.Visible = $true
$softPowerText.Visible = $true
$networkMethodLabel.Location = [System.Drawing.Point]::new(16,29)
$networkMethodCombo.Location = [System.Drawing.Point]::new(125,27)
$networkMethodHelp.Location = [System.Drawing.Point]::new(495,27)
$networkSampleColumnLabel.Location = [System.Drawing.Point]::new(16,70)
$networkSampleColumnCombo.Location = [System.Drawing.Point]::new(145,68)
$networkCorrelationLabel.Location = [System.Drawing.Point]::new(320,70)
$networkCorrelationCombo.Location = [System.Drawing.Point]::new(435,68)
$networkTypeLabel.Location = [System.Drawing.Point]::new(16,109)
$networkTypeCombo.Location = [System.Drawing.Point]::new(145,107)
$softPowerLabel.Location = [System.Drawing.Point]::new(320,109)
$softPowerText.Location = [System.Drawing.Point]::new(435,107)
$maxGenesLabel.Location = [System.Drawing.Point]::new(16,148)
$maxGenesText.Location = [System.Drawing.Point]::new(145,146)
$networkLogTransform.Location = [System.Drawing.Point]::new(320,146)
$networkAutoModules.Location = [System.Drawing.Point]::new(16,178)
$networkAutoModules.Width = 270
$networkMethodGroup.Height = 210
$useLastNormalizedButton.Visible = $false
$networkOutputLabel.Visible = $false
$networkOutputText.Visible = $false
$networkOutputBrowse.Visible = $false
$networkExampleButton.Visible = $false
$networkScanFolderButton.Visible = $false
$networkParameterHelp.Visible = $false
$networkAdvancedPackageButton.Visible = $false
$runNetworkButton.Visible = $false
$openNetworkStudioButton.Visible = $false
$networkWarning.Visible = $false
$combinedNetworkBaseControls = @(
    $networkMethodLabel,$networkMethodCombo,$networkMethodHelp,
    $networkSampleColumnLabel,$networkSampleColumnCombo,$networkCorrelationLabel,$networkCorrelationCombo,
    $networkTypeLabel,$networkTypeCombo,$softPowerLabel,$softPowerText,
    $maxGenesLabel,$maxGenesText,$networkLogTransform,$networkAutoModules
)
$combinedNetworkGroup.Controls.AddRange($combinedNetworkBaseControls)

$combinedMethodsRow = New-Object System.Windows.Forms.TableLayoutPanel
$combinedMethodsRow.ColumnCount = 2
$combinedMethodsRow.RowCount = 1
$combinedMethodsRow.Height = 288
$combinedMethodsRow.BackColor = $background
$combinedMethodsRow.Margin = New-Object System.Windows.Forms.Padding(0,0,0,4)
[void]$combinedMethodsRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$combinedMethodsRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$combinedMethodsRow.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$enrichMethodGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$combinedNetworkGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$enrichMethodGroup.Margin = New-Object System.Windows.Forms.Padding(0,0,5,0)
$combinedNetworkGroup.Margin = New-Object System.Windows.Forms.Padding(5,0,0,0)
[void]$combinedMethodsRow.Controls.Add($enrichMethodGroup,0,0)
[void]$combinedMethodsRow.Controls.Add($combinedNetworkGroup,1,0)
$enrichInputPanel.Controls.Add($combinedMethodsRow)

$combinedMethodsRow.Visible = $true
$enrichAdvancedPackageButton.Text = 'Guided package options'
Set-ParameterTip $enrichAdvancedPackageButton 'Configure documented enrichment and network arguments plus the integrated KEGG organism code and STRING taxonomy, network type, confidence score, added partners, and optional alias-table settings. Selected overrides are retained in the combined run log.'
$enrichSettingsGroup.Remove_SizeChanged($layoutEnrichmentGeneSet)
$functionalSettingsGroup = New-Group 'Gene selection and gene-set sizes' 8 210
$functionalSettingsGroup.Controls.AddRange(@(
    $enrichDirectionLabel,$enrichDirectionCombo,$enrichDirectionHelp,
    $enrichPadjLabel,$enrichPadj,$enrichPadjHelp,
    $enrichLfcLabel,$enrichLfc,$enrichLfcHelp,
    $minSetLabel,$minSet,$minSetHelp,$maxSetLabel,$maxSet,$maxSetHelp
))
$enrichMethodGroup.Dock=[System.Windows.Forms.DockStyle]::Fill
$networkMethodGroup.Dock=[System.Windows.Forms.DockStyle]::None
$enrichMethodGroup.Text='3. Functional enrichment method and annotation columns'
$networkSettingsGroup.Text='Module, edge, and regulatory settings'
$functionalSettingsGroup.Visible=$false
$networkSettingsGroup.Visible=$false
$functionalSettingsGroup.Dock=[System.Windows.Forms.DockStyle]::None
$networkSettingsGroup.Dock=[System.Windows.Forms.DockStyle]::None
$enrichMethodGroup.Controls.Add($functionalSettingsGroup)
$combinedNetworkGroup.Controls.Add($networkSettingsGroup)
$showFunctionalSettings = New-CheckBox 'Show gene selection and gene-set settings' 16 218 390 $false
$showNetworkSettings = New-CheckBox 'Show module, edge, and regulatory settings' 298 178 390 $false
Set-ParameterTip $showFunctionalSettings 'Tick to reveal direction, adjusted-p-value, fold-change, and gene-set-size settings. Leave clear to keep the recommended defaults and save page space.'
Set-ParameterTip $showNetworkSettings 'Tick to reveal module size, edge threshold, edge limit, GENIE3 trees, CPU threads, and exploratory-mode settings. Leave clear to keep the recommended defaults.'
$enrichMethodGroup.Controls.Add($showFunctionalSettings)
$combinedNetworkGroup.Controls.Add($showNetworkSettings)
$layoutCompactFields = {
    param($group,$definitions)
    $width=[Math]::Max(330,$group.ClientSize.Width)
    $columns=if($width -ge 700){3}else{2}
    $slot=[int](($width-32)/$columns)
    for($i=0;$i -lt $definitions.Count;$i++){
        $d=$definitions[$i];$x=16+($i%$columns)*$slot;$y=24+[int][Math]::Floor($i/$columns)*53
        $d[0].SetBounds($x,$y,$slot-18,20)
        $d[1].SetBounds($x,$y+21,[Math]::Max(72,[Math]::Min(175,$slot-48)),25)
        $d[2].SetBounds($d[1].Right+7,$y+22,22,22)
    }
}.GetNewClosure()
$functionalFieldDefs=@(@($enrichDirectionLabel,$enrichDirectionCombo,$enrichDirectionHelp),@($enrichPadjLabel,$enrichPadj,$enrichPadjHelp),@($enrichLfcLabel,$enrichLfc,$enrichLfcHelp),@($minSetLabel,$minSet,$minSetHelp),@($maxSetLabel,$maxSet,$maxSetHelp))
$networkFieldDefs=@(@($minModuleLabel,$minModuleText,$minModuleHelp),@($edgeThresholdLabel,$edgeThresholdText,$edgeThresholdHelp),@($maxEdgesLabel,$maxEdgesText,$maxEdgesHelp),@($nTreesLabel,$nTreesText,$nTreesHelp),@($threadsLabel,$threadsText,$threadsHelp))
$functionalSettingsGroup.Add_SizeChanged({ & $layoutCompactFields $functionalSettingsGroup $functionalFieldDefs }.GetNewClosure())
$networkSettingsGroup.Add_SizeChanged({
    & $layoutCompactFields $networkSettingsGroup $networkFieldDefs
    $columns=if($networkSettingsGroup.ClientSize.Width -ge 700){3}else{2}
    $exploratoryY=if($columns -eq 3){135}else{184}
    $networkExploratory.SetBounds(16,$exploratoryY,[Math]::Max(250,$networkSettingsGroup.ClientSize.Width-32),26)
}.GetNewClosure())

$combinedActionPanel = New-Object System.Windows.Forms.Panel
$combinedActionPanel.Height = 48
$combinedActionPanel.MinimumSize = [System.Drawing.Size]::new(760,48)
$combinedActionPanel.BackColor = $surface
$combinedActionPanel.Margin = New-Object System.Windows.Forms.Padding(0,0,0,4)
$integratedKeggEnabled = New-CheckBox 'Use KEGG pathway database' 16 6 300 $true
$integratedKeggOrganism = New-ComboBox 16 36 240 @(
    'amys · Amycolatopsis sp. TNS106','aori · Amycolatopsis orientalis','eco · Escherichia coli K-12 MG1655',
    'bsu · Bacillus subtilis 168','pae · Pseudomonas aeruginosa PAO1','sco · Streptomyces coelicolor A3(2)',
    'mtu · Mycobacterium tuberculosis H37Rv','vch · Vibrio cholerae O1 El Tor N16961'
)
$integratedKeggOrganism.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
$integratedKeggOrganism.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::SuggestAppend
$integratedKeggOrganism.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::ListItems
$integratedKeggFind = New-Button 'Browse' 264 34 68 29
$integratedKeggTest = New-Button 'Test' 340 34 58 29
$integratedStringEnabled = New-CheckBox 'Use STRING protein-interaction database' 410 6 330 $true
$integratedStringOrganism = New-ComboBox 410 36 240 @(
    'Amycolatopsis orientalis [taxid: 31958]','Amycolatopsis mediterranei S699 [taxid: 713604]',
    'Escherichia coli K-12 MG1655 [taxid: 511145]','Bacillus subtilis 168 [taxid: 224308]',
    'Pseudomonas aeruginosa PAO1 [taxid: 208964]','Streptomyces coelicolor A3(2) [taxid: 100226]',
    'Mycobacterium tuberculosis H37Rv [taxid: 83332]'
)
$integratedStringOrganism.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
$integratedStringOrganism.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::SuggestAppend
$integratedStringOrganism.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::ListItems
$integratedStringFind = New-Button 'Browse' 658 34 68 29
$integratedStringTest = New-Button 'Test' 734 34 58 29
$integratedOptionalMappingToggle = New-CheckBox 'Show optional pathway-mapping inputs' 16 70 330 $false
$integratedStringTypeLabel = New-Label 'Interaction type' 410 72 95 24
$integratedStringType = New-ComboBox 510 68 130 @('Physical','Functional')
$integratedStringScoreLabel = New-Label 'Minimum score' 650 72 92 24
$integratedStringScore = New-TextBox 746 69 62 '700'
$integratedTerm2GeneLabel = New-Label 'Custom TERM2GENE' 16 108 220 24
$integratedTerm2GeneText = New-TextBox 246 105 390
$integratedTerm2GeneBrowse = New-Button 'Browse' 646 103 72 29
$integratedBioCycLabel = New-Label 'BioCyc pathway mapping' 16 142 220 24
$integratedBioCycText = New-TextBox 246 139 390
$integratedBioCycBrowse = New-Button 'Browse' 646 137 72 29
$integratedMetaCycLabel = New-Label 'MetaCyc pathway mapping' 16 176 220 24
$integratedMetaCycText = New-TextBox 246 173 390
$integratedMetaCycBrowse = New-Button 'Browse' 646 171 72 29
$keggMapEnabled = New-CheckBox 'Map expression onto KEGG pathways' 16 208 365 $false
$keggMapOffline = New-CheckBox 'Use cached KEGG maps only' 410 208 320 $false
$keggMapIdsLabel = New-Label 'KEGG pathway IDs' 16 243 220 24
$keggMapIdsText = New-TextBox 246 240 330
$runKeggMapButton = New-Button 'Map pathways' 646 238 110 29
$keggMapIdsHelp = New-Label 'Examples: 00010, eco00020, ko00010. Uses the DE result table in section 1.' 16 310 700 22
$keggMapGeneLabel = New-Label 'Gene-ID mapping (optional)' 16 277 220 24
$keggMapGeneText = New-TextBox 246 274 390
$keggMapGeneBrowse = New-Button 'Browse' 646 272 72 29
Set-ParameterTip $keggMapEnabled 'Adds native KEGG expression maps to the combined workbook and HTML report. Map pathways runs this sub-operation alone, using all measured DE genes. Run all analyses includes it when ticked.'
Set-ParameterTip $keggMapIdsText 'Enter up to 12 pathway IDs separated by commas or spaces. Bare numbers and map IDs use the selected KEGG organism. Explicit ko IDs require KO assignments. Choose the same organism as the transcriptome.'
Set-ParameterTip $keggMapGeneText 'Optional TSV/CSV/XLSX with gene_id and kegg_id (for example eco:b0001) and/or ko_id (for example K00001). Use it when transcriptome IDs differ from KEGG IDs. This is separate from pathway TERM2GENE, BioCyc and MetaCyc inputs.'
Set-ParameterTip $keggMapOffline 'Uses previously downloaded PNG/KGML files only. Leave clear for the first run. No KEGG requests are made when opening this module.'
Set-ParameterTip $runKeggMapButton 'Map the DE table onto the requested native KEGG diagrams. Does not require an expression matrix, sample metadata or GO mapping, and does not rerun enrichment or networks.'
$runEnrichmentButton.Text = 'Run all analyses'
Set-ParameterTip $integratedKeggEnabled 'Uses the same selected genes and tested-gene universe as GO enrichment, then adds online KEGG pathway results to the same workbook and interactive report.'
Set-ParameterTip $integratedKeggOrganism 'Choose or type a KEGG organism code. The adjacent button opens the complete official organism list; no placeholder option is needed.'
Set-ParameterTip $integratedKeggFind 'Open the official KEGG organism list to find the three- or four-letter organism code.'
Set-ParameterTip $integratedKeggTest 'Test whether the KEGG REST database can be reached from this computer.'
Set-ParameterTip $integratedStringEnabled 'Uses the same selected gene list and combines STRING associations with the co-expression edge evidence in the same result package.'
Set-ParameterTip $integratedStringOrganism 'Choose a supported STRING v12 organism or type its numeric taxonomy ID. The adjacent button opens STRING for additional organisms.'
Set-ParameterTip $integratedStringFind 'Open the STRING organism browser to find a taxonomy ID.'
Set-ParameterTip $integratedStringTest 'Test whether the STRING v12 identifier-mapping API can be reached from this computer.'
Set-ParameterTip $integratedStringScore 'Minimum STRING confidence score from 0 through 1000. Higher values keep stronger evidence but usually return fewer edges.'
Set-ParameterTip $integratedOptionalMappingToggle 'Shows optional custom, BioCyc, and MetaCyc pathway-to-gene mapping inputs. Existing values are retained when the inputs are hidden.'
Set-ParameterTip $integratedTerm2GeneText 'Optional two-column pathway-to-gene mapping. It can be used alone or merged with KEGG, BioCyc, and MetaCyc mappings.'
Set-ParameterTip $integratedBioCycText 'Optional BioCyc pathway-to-gene mapping table to merge into the pathway analysis.'
Set-ParameterTip $integratedMetaCycText 'Optional MetaCyc pathway-to-gene mapping table to merge into the pathway analysis.'
$integratedMappingPanel = New-Object System.Windows.Forms.Panel
$integratedMappingPanel.BackColor = $surface
$integratedMappingPanel.Location = [System.Drawing.Point]::new(0,102)
$integratedMappingPanel.Size = [System.Drawing.Size]::new(760,101)
$integratedMappingPanel.TabStop = $false
$integratedMappingPanel.Controls.AddRange(@(
    $integratedKeggEnabled,$integratedKeggOrganism,$integratedKeggFind,$integratedKeggTest,
    $integratedStringEnabled,$integratedStringOrganism,$integratedStringFind,$integratedStringTest,$integratedStringTypeLabel,$integratedStringType,$integratedStringScoreLabel,$integratedStringScore,
    $integratedOptionalMappingToggle,
    $integratedTerm2GeneLabel,$integratedTerm2GeneText,$integratedTerm2GeneBrowse,
    $integratedBioCycLabel,$integratedBioCycText,$integratedBioCycBrowse,
    $integratedMetaCycLabel,$integratedMetaCycText,$integratedMetaCycBrowse,
    $keggMapEnabled,$keggMapOffline,$keggMapIdsLabel,$keggMapIdsText,$runKeggMapButton,$keggMapIdsHelp,
    $keggMapGeneLabel,$keggMapGeneText,$keggMapGeneBrowse
))
$enrichAnnotationGroup.Controls.Add($integratedMappingPanel)
$combinedActionPanel.Controls.AddRange(@($enrichParameterHelp,$enrichAdvancedPackageButton,$runEnrichmentButton,$openEnrichmentStudioButton))
$enrichInputPanel.Controls.Remove($enrichSettingsGroup)
$enrichSettingsGroup.Visible=$false
$enrichInputPanel.Controls.Add($combinedActionPanel)
$integratedMappingLayoutState=[pscustomobject]@{Busy=$false;LastKey=''}
$layoutIntegratedMappingControls={
    if($integratedMappingLayoutState.Busy){return}
    $w=[Math]::Max(760,$enrichAnnotationGroup.ClientSize.Width);$left=16;$gap=8;$half=[int](($w-48)/2);$right=$left+$half+16
    # Keep the organism check inline. GetNewClosure creates a dynamic module in
    # Windows PowerShell 5.1, where calling the ordinary helper function caused
    # the v24 Get-OrganismQueryText startup failure.
    $organismDisplay=if($enrichAnnotationOrganismText){([string]$enrichAnnotationOrganismText.Text).Trim()}else{''}
    $organismMissing=[string]::IsNullOrWhiteSpace($organismDisplay) -or $organismDisplay -like 'No organism / no taxonomy ID*' -or $organismDisplay -like 'No organism / unknown*' -or $organismDisplay -like 'Other / more organisms*'
    $unrestricted=$enrichOnlineAnnotation.Checked -and $organismMissing
    $base=if($enrichOnlineAnnotation.Checked){if($unrestricted){214}else{176}}else{102}
    $mappingVisible=[bool]$integratedOptionalMappingToggle.Checked
    $mapVisible=[bool]$keggMapEnabled.Checked
    $mapTop=if($mappingVisible){208}else{101}
    $panelHeight=$mapTop+32+$(if($mapVisible){104}else{0})
    $layoutKey="$w|$base|$mappingVisible|$mapVisible"
    if($integratedMappingLayoutState.LastKey -eq $layoutKey){return}
    $integratedMappingLayoutState.Busy=$true
    $enrichAnnotationGroup.SuspendLayout();$integratedMappingPanel.SuspendLayout()
    try{
        $integratedMappingPanel.SetBounds(0,$base,$w,$panelHeight)
        $integratedKeggEnabled.SetBounds($left,0,$half,26)
        $integratedStringEnabled.SetBounds($right,0,$half,26)
        $smallButton=62;$comboWidth=[Math]::Max(130,$half-($smallButton*2)-($gap*2))
        $browserY=29
        $integratedKeggOrganism.SetBounds($left,$browserY,$comboWidth,29)
        $integratedKeggFind.SetBounds($integratedKeggOrganism.Right+$gap,$browserY-2,$smallButton,29)
        $integratedKeggTest.SetBounds($integratedKeggFind.Right+$gap,$browserY-2,$smallButton,29)
        $integratedStringOrganism.SetBounds($right,$browserY,$comboWidth,29)
        $integratedStringFind.SetBounds($integratedStringOrganism.Right+$gap,$browserY-2,$smallButton,29)
        $integratedStringTest.SetBounds($integratedStringFind.Right+$gap,$browserY-2,$smallButton,29)
        $settingsY=65
        $integratedOptionalMappingToggle.SetBounds($left,$settingsY,$half,27)
        $integratedStringTypeLabel.SetBounds($right,$settingsY+3,95,24)
        $typeWidth=[Math]::Max(92,[int](($half-213)/2))
        $integratedStringType.SetBounds($right+100,$settingsY-1,$typeWidth,29)
        $integratedStringScoreLabel.SetBounds($integratedStringType.Right+10,$settingsY+3,92,24)
        $integratedStringScore.SetBounds($integratedStringScoreLabel.Right+5,$settingsY,58,27)
        foreach($control in @($integratedTerm2GeneLabel,$integratedTerm2GeneText,$integratedTerm2GeneBrowse,$integratedBioCycLabel,$integratedBioCycText,$integratedBioCycBrowse,$integratedMetaCycLabel,$integratedMetaCycText,$integratedMetaCycBrowse)){$control.Visible=$mappingVisible}
        $browseLeft=$w-88;$fieldX=246;$mappingWidth=[Math]::Max(190,$browseLeft-$fieldX-8);$mappingTop=102
        $mappingRows=@(
          @($integratedTerm2GeneLabel,$integratedTerm2GeneText,$integratedTerm2GeneBrowse,$mappingTop),
          @($integratedBioCycLabel,$integratedBioCycText,$integratedBioCycBrowse,($mappingTop+34)),
          @($integratedMetaCycLabel,$integratedMetaCycText,$integratedMetaCycBrowse,($mappingTop+68))
        )
        foreach($row in $mappingRows){$row[0].SetBounds($left,[int]$row[3]+2,220,24);$row[1].SetBounds($fieldX,[int]$row[3],$mappingWidth,27);$row[2].SetBounds($browseLeft,[int]$row[3]-2,72,29)}
        $keggMapEnabled.SetBounds($left,$mapTop,$half,27)
        $keggMapOffline.SetBounds($right,$mapTop,$half,27)
        foreach($control in @($keggMapOffline,$keggMapIdsLabel,$keggMapIdsText,$runKeggMapButton,$keggMapIdsHelp,$keggMapGeneLabel,$keggMapGeneText,$keggMapGeneBrowse)){$control.Visible=$mapVisible}
        $keggMapIdsLabel.SetBounds($left,($mapTop+35),220,24)
        $keggMapIdsText.SetBounds($fieldX,($mapTop+33),[Math]::Max(160,$w-$fieldX-150),27)
        $runKeggMapButton.SetBounds(($w-140),($mapTop+31),124,29)
        $keggMapGeneLabel.SetBounds($left,($mapTop+69),220,24)
        $keggMapGeneText.SetBounds($fieldX,($mapTop+67),$mappingWidth,27)
        $keggMapGeneBrowse.SetBounds($browseLeft,($mapTop+65),72,29)
        $keggMapIdsHelp.SetBounds($left,($mapTop+101),($w-32),24)
        $targetHeight=$base+$panelHeight
        if($enrichAnnotationGroup.Height -ne $targetHeight){$enrichAnnotationGroup.Height=$targetHeight}
        $integratedMappingLayoutState.LastKey=$layoutKey
    }finally{$integratedMappingPanel.ResumeLayout($false);$enrichAnnotationGroup.ResumeLayout($false);$integratedMappingLayoutState.Busy=$false}
}.GetNewClosure()
$enrichAnnotationGroup.Add_SizeChanged($layoutIntegratedMappingControls)
$layoutCombinedActions={
    $w=[Math]::Max(760,$combinedActionPanel.ClientSize.Width);$gap=8;$buttons=@($runEnrichmentButton,$openEnrichmentStudioButton,$enrichParameterHelp,$enrichAdvancedPackageButton);$slot=[int](($w-16-($gap*3))/4)
    for($i=0;$i -lt $buttons.Count;$i++){$buttons[$i].SetBounds(0+$i*($slot+$gap),6,$slot,34)}
}.GetNewClosure()
$combinedActionPanel.Add_SizeChanged($layoutCombinedActions)
& $layoutCombinedActions
$integratedKeggFind.Add_Click({ try { [void](Start-Process -FilePath 'https://www.genome.jp/kegg/catalog/org_list.html') } catch { Show-Error 'Could not open the official KEGG organism list.' } })
$integratedStringFind.Add_Click({ try { [void](Start-Process -FilePath 'https://string-db.org/') } catch { Show-Error 'Could not open the STRING organism search.' } })
$integratedKeggTest.Add_Click({ Test-KEGGDatabaseConnection })
$integratedStringTest.Add_Click({ Test-STRINGDatabaseConnection })
$integratedTerm2GeneBrowse.Add_Click({$p=Select-InputFile 'Select custom TERM2GENE mapping' 'Mapping tables (*.tsv;*.txt;*.csv;*.gmt)|*.tsv;*.txt;*.csv;*.gmt|All files (*.*)|*.*';if($p){$integratedTerm2GeneText.Text=$p}})
$integratedBioCycBrowse.Add_Click({$p=Select-InputFile 'Select BioCyc pathway mapping' 'Mapping tables (*.tsv;*.txt;*.csv)|*.tsv;*.txt;*.csv|All files (*.*)|*.*';if($p){$integratedBioCycText.Text=$p}})
$integratedMetaCycBrowse.Add_Click({$p=Select-InputFile 'Select MetaCyc pathway mapping' 'Mapping tables (*.tsv;*.txt;*.csv)|*.tsv;*.txt;*.csv|All files (*.*)|*.*';if($p){$integratedMetaCycText.Text=$p}})
$keggMapGeneBrowse.Add_Click({$p=Select-InputFile 'Select gene-to-KEGG ID mapping' 'Gene mapping tables (*.tsv;*.txt;*.csv;*.xlsx)|*.tsv;*.txt;*.csv;*.xlsx|All files (*.*)|*.*';if($p){$keggMapGeneText.Text=$p}})
$updateIntegratedDatabaseControls = {
    foreach($control in @($integratedKeggOrganism,$integratedKeggFind,$integratedKeggTest)){ $control.Enabled=($integratedKeggEnabled.Checked -or $keggMapEnabled.Checked) }
    foreach($control in @($integratedStringOrganism,$integratedStringFind,$integratedStringTest,$integratedStringTypeLabel,$integratedStringType,$integratedStringScoreLabel,$integratedStringScore)){ $control.Enabled=$integratedStringEnabled.Checked }
}.GetNewClosure()
$integratedKeggEnabled.Add_CheckedChanged($updateIntegratedDatabaseControls)
$integratedStringEnabled.Add_CheckedChanged($updateIntegratedDatabaseControls)
$integratedOptionalMappingToggle.Add_CheckedChanged({& $layoutIntegratedMappingControls;if($enrichInputPanel){$enrichInputPanel.PerformLayout()}}.GetNewClosure())
$keggMapEnabled.Add_CheckedChanged({& $updateIntegratedDatabaseControls;& $layoutIntegratedMappingControls;if($enrichInputPanel){$enrichInputPanel.PerformLayout()}}.GetNewClosure())
& $updateIntegratedDatabaseControls
& $layoutIntegratedMappingControls

$combinedLayoutState=[pscustomobject]@{Busy=$false}
$layoutCombinedSections={
    if($combinedLayoutState.Busy){return};$combinedLayoutState.Busy=$true
    try{
        $functionalSettingsGroup.Visible=$showFunctionalSettings.Checked
        $networkSettingsGroup.Visible=$showNetworkSettings.Checked
        $functionalSettingsGroup.SetBounds(8,246,[Math]::Max(330,$enrichMethodGroup.ClientSize.Width-16),210)
        $networkSettingsGroup.SetBounds(8,210,[Math]::Max(330,$combinedNetworkGroup.ClientSize.Width-16),214)
        $showFunctionalSettings.Width=[Math]::Max(260,$enrichMethodGroup.ClientSize.Width-32)
        $networkWidth=[Math]::Max(330,$combinedNetworkGroup.ClientSize.Width)
        $networkHelpLeft=[Math]::Max(300,$networkWidth-43)
        $networkMethodHelp.Left=$networkHelpLeft
        $networkMethodCombo.Width=[Math]::Max(150,$networkHelpLeft-$networkMethodCombo.Left-10)
        $networkHalf=[int](($networkWidth-42)/2);$networkRightX=22+$networkHalf
        foreach($label in @($networkCorrelationLabel,$softPowerLabel)){$label.Left=$networkRightX}
        foreach($control in @($networkCorrelationCombo,$softPowerText)){$control.Left=$networkRightX+115;$control.Width=[Math]::Max(92,$networkWidth-$control.Left-18)}
        foreach($control in @($networkSampleColumnCombo,$networkTypeCombo,$maxGenesText)){$control.Width=[Math]::Max(100,$networkHalf-$control.Left+12)}
        $networkLogTransform.Left=$networkRightX;$networkLogTransform.Width=[Math]::Max(180,$networkWidth-$networkRightX-18)
        $networkAutoModules.SetBounds(16,178,[Math]::Max(220,[int]($networkWidth*.43)),26)
        $showNetworkSettings.SetBounds($networkAutoModules.Right+12,178,[Math]::Max(210,$networkWidth-$networkAutoModules.Right-28),26)
        if($functionalSettingsGroup.Visible){& $layoutCompactFields $functionalSettingsGroup $functionalFieldDefs}
        if($networkSettingsGroup.Visible){
            & $layoutCompactFields $networkSettingsGroup $networkFieldDefs
            $columns=if($networkSettingsGroup.ClientSize.Width -ge 700){3}else{2}
            $exploratoryY=if($columns -eq 3){135}else{184}
            $networkExploratory.SetBounds(16,$exploratoryY,[Math]::Max(250,$networkSettingsGroup.ClientSize.Width-32),26)
        }
        # Size from the last visible controls, not an oversized fixed card.
        $functionalBottom=if($showFunctionalSettings.Checked){$functionalSettingsGroup.Bottom}else{$showFunctionalSettings.Bottom}
        $networkBottom=if($showNetworkSettings.Checked){$networkSettingsGroup.Bottom}else{$showNetworkSettings.Bottom}
        $targetHeight=[Math]::Max($functionalBottom,$networkBottom)+8
        if($combinedMethodsRow.Height -ne $targetHeight){$combinedMethodsRow.Height=$targetHeight}
        & $layoutCombinedActions
        if($enrichInputPanel){$enrichInputPanel.PerformLayout()}
    }finally{$combinedLayoutState.Busy=$false}
}.GetNewClosure()
$enrichMethodGroup.Add_SizeChanged($layoutCombinedSections)
$combinedNetworkGroup.Add_SizeChanged($layoutCombinedSections)
$showFunctionalSettings.Add_CheckedChanged($layoutCombinedSections)
$showNetworkSettings.Add_CheckedChanged($layoutCombinedSections)
& $layoutCombinedSections
$enrichInputPanel.Controls.SetChildIndex($enrichInputGroup,0)
$enrichInputPanel.Controls.SetChildIndex($enrichAnnotationGroup,1)
$enrichInputPanel.Controls.SetChildIndex($combinedMethodsRow,2)
$enrichInputPanel.Controls.SetChildIndex($combinedActionPanel,3)
} # Functional-module construction

# Keep every page responsive at normal and high-DPI display scaling.
function Initialize-ResponsiveFlow([System.Windows.Forms.FlowLayoutPanel]$Flow, [System.Windows.Forms.Control[]]$Children) {
    $Flow.Tag = $Children
    $Flow.Add_Resize({
        $usable = [Math]::Max(320, $this.ClientSize.Width - $this.Padding.Horizontal - 26)
        foreach ($child in [System.Windows.Forms.Control[]]$this.Tag) { $child.Width = $usable; $child.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4) }
    })
}
Initialize-ResponsiveFlow $deInputPanel @($deRecommendation, $deInputGroup, $deDesignGroup, $deSettingsGroup)
if ($script:InitialTab -ne 'de') {
    Initialize-ResponsiveFlow $enrichInputPanel @($enrichInputGroup, $enrichAnnotationGroup, $combinedMethodsRow, $combinedActionPanel)
    $enrichSplit.Add_Resize({ Set-ResponsiveSplitter $enrichSplit 0.58 })
    $networkSplit.Add_Resize({ Set-ResponsiveSplitter $networkSplit 0.58 })
}

$deSplit.Add_Resize({ Set-ResponsiveSplitter $deSplit 0.58 })
$form.Add_Shown({
    Set-ResponsiveSplitter $deSplit 0.58
    $flows = @($deInputPanel)
    if ($script:InitialTab -ne 'de') {
        Set-ResponsiveSplitter $enrichSplit 0.58
        Set-ResponsiveSplitter $networkSplit 0.58
        $flows += $enrichInputPanel
    }
    foreach ($flow in $flows) {
        if (-not $flow.Tag) { continue }
        $usable = [Math]::Max(320, $flow.ClientSize.Width - $flow.Padding.Horizontal - 26)
        foreach ($child in [System.Windows.Forms.Control[]]$flow.Tag) { $child.Width = $usable; $child.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4) }
    }
})

$script:UpdatingEnrichmentMappingMode = $false
function Update-EnrichmentAnnotationControls {
    if (-not $enrichOfflineMapping.Checked -and -not $enrichOnlineAnnotation.Checked) {
        $script:UpdatingEnrichmentMappingMode = $true
        $enrichOfflineMapping.Checked = $true
        $script:UpdatingEnrichmentMappingMode = $false
    }
    $onlineEnabled = [bool]$enrichOnlineAnnotation.Checked
    $offlineEnabled = -not $onlineEnabled
    $offlineControls = @($enrichMappingLabel,$enrichMappingText,$enrichMappingBrowse)
    $onlineControls = @(
        $enrichAnnotationModeLabel,$enrichAnnotationModeCombo,$enrichAnnotationDatabaseLabel,$enrichAnnotationDatabaseCombo,
        $enrichAnnotationOrganismLabel,$enrichAnnotationOrganismText,$enrichFindOrganism,$enrichAnnotationSequenceLabel,$enrichAnnotationSequenceText,
        $enrichAnnotationSequenceBrowse,$enrichAnnotationRefresh,$enrichAnnotationTestButton,$enrichOrganismWarning
    )
    foreach ($control in $offlineControls) { $control.Visible = $offlineEnabled; $control.Enabled = $offlineEnabled }
    foreach ($control in $onlineControls) { $control.Visible = $onlineEnabled }
    $unrestrictedSelected = $onlineEnabled -and [string]::IsNullOrWhiteSpace((Get-OrganismQueryText $enrichAnnotationOrganismText))
    $enrichOrganismWarning.Visible = $unrestrictedSelected
    $enrichInputPanel.AutoScroll = $true
    $mode = Get-OnlineAnnotationModeKey ([string]$enrichAnnotationModeCombo.SelectedItem)
    foreach ($control in @($enrichAnnotationModeLabel,$enrichAnnotationModeCombo,$enrichAnnotationDatabaseLabel,$enrichAnnotationDatabaseCombo,$enrichAnnotationTestButton)) { $control.Enabled = $onlineEnabled }
    $idMode = $mode -eq 'gene_ids'
    # Organism filtering improves both identifier lookup and organism-specific
    # DIAMOND sequence databases, so keep the searchable organism field usable
    # for every online annotation mode.
    $enrichAnnotationOrganismLabel.Enabled = $onlineEnabled
    $enrichAnnotationOrganismText.Enabled = $onlineEnabled
    $enrichFindOrganism.Enabled = $onlineEnabled
    $sequenceMode = $onlineEnabled -and -not $idMode
    foreach ($control in @($enrichAnnotationSequenceLabel,$enrichAnnotationSequenceText,$enrichAnnotationSequenceBrowse)) { $control.Enabled = $sequenceMode }
    $enrichAnnotationRefresh.Enabled = $onlineEnabled
    if ($onlineEnabled) {
        $enrichSourceCombo.SelectedItem = 'GO'
        foreach ($control in @($mapGeneLabel,$mapGeneText,$mapTermLabel,$mapTermText,$mapNameLabel,$mapNameText,$mapSourceLabel,$mapSourceText,$enrichSourceLabel,$enrichSourceCombo)) { $control.Enabled = $false }
        if ($idMode) { Fill-Combo $enrichAnnotationDatabaseCombo @('UniProtKB/Swiss-Prot (reviewed)','UniProtKB (reviewed + TrEMBL)') 'UniProtKB (reviewed + TrEMBL)' }
        else { Fill-Combo $enrichAnnotationDatabaseCombo @('UniProtKB/Swiss-Prot (reviewed)') 'UniProtKB/Swiss-Prot (reviewed)' }
    } else {
        foreach ($control in @($mapGeneLabel,$mapGeneText,$mapTermLabel,$mapTermText,$mapNameLabel,$mapNameText,$mapSourceLabel,$mapSourceText,$enrichSourceLabel,$enrichSourceCombo)) { if ($null -ne $control) { $control.Enabled = $true } }
    }
    if ($null -ne $layoutIntegratedMappingControls) { & $layoutIntegratedMappingControls }
    if ($enrichInputPanel) { $enrichInputPanel.PerformLayout() }
}

function Update-NetworkAnnotationControls {
    $enabled = [bool]$networkOnlineAnnotation.Checked
    $detailControls = @(
        $networkAnnotationModeLabel,$networkAnnotationModeCombo,$networkAnnotationDatabaseLabel,$networkAnnotationDatabaseCombo,
        $networkAnnotationOrganismLabel,$networkAnnotationOrganismText,$networkAnnotationSequenceLabel,$networkAnnotationSequenceText,
        $networkAnnotationSequenceBrowse,$networkAnnotationRefresh,$networkAnnotationTestButton
    )
    $networkAnnotationGroup.Height = if ($enabled) { 214 } else { 52 }
    foreach ($control in $detailControls) { $control.Visible = $enabled }
    if ($networkInputPanel) { $networkInputPanel.PerformLayout() }
    $mode = Get-OnlineAnnotationModeKey ([string]$networkAnnotationModeCombo.SelectedItem)
    foreach ($control in @($networkAnnotationModeLabel,$networkAnnotationModeCombo,$networkAnnotationDatabaseLabel,$networkAnnotationDatabaseCombo,$networkAnnotationTestButton)) { $control.Enabled = $enabled }
    $idMode = $mode -eq 'gene_ids'
    $networkAnnotationOrganismLabel.Enabled = $enabled
    $networkAnnotationOrganismText.Enabled = $enabled
    $sequenceMode = $enabled -and -not $idMode
    foreach ($control in @($networkAnnotationSequenceLabel,$networkAnnotationSequenceText,$networkAnnotationSequenceBrowse)) { $control.Enabled = $sequenceMode }
    $networkAnnotationRefresh.Enabled = $enabled
    if ($enabled -and $idMode) { Fill-Combo $networkAnnotationDatabaseCombo @('UniProtKB/Swiss-Prot (reviewed)','UniProtKB (reviewed + TrEMBL)') 'UniProtKB/Swiss-Prot (reviewed)' }
    elseif ($enabled) { Fill-Combo $networkAnnotationDatabaseCombo @('UniProtKB/Swiss-Prot (reviewed)') 'UniProtKB/Swiss-Prot (reviewed)' }
}

function Update-NetworkControls {
    $selected = [string]$networkMethodCombo.SelectedItem
    $isWgcna = $selected -like 'WGCNA*'
    $isGenie = $selected -like 'GENIE3*'
    $isCoexpression = -not $isGenie

    $networkCorrelationCombo.Enabled = $isCoexpression
    $networkTypeCombo.Enabled = $isWgcna
    $softPowerText.Enabled = $isWgcna
    $minModuleText.Enabled = $isWgcna
    $edgeThresholdText.Enabled = $isCoexpression
    $networkExploratory.Enabled = $isCoexpression
    $networkRegulatorText.Enabled = $isGenie
    $networkRegulatorBrowse.Enabled = $isGenie
    $nTreesText.Enabled = $isGenie
    $threadsText.Enabled = $isGenie
}

# Example input workbooks
$deExampleButton.Add_Click({ Open-ExampleWorkbook 'Differential Expression example inputs.xlsx' })
if ($script:InitialTab -ne 'de') {
$enrichExampleButton.Add_Click({ Open-ExampleWorkbook 'Functional Enrichment and Co-expression example inputs.xlsx' })
$networkExampleButton.Add_Click({ Open-ExampleWorkbook 'Co-expression and Networks example inputs.xlsx' })
$enrichAnnotationSequenceBrowse.Add_Click({ $p = Select-InputFile 'Select protein or CDS FASTA for functional annotation' 'FASTA files (*.fa;*.fasta;*.faa;*.fna;*.fa.gz;*.fasta.gz)|*.fa;*.fasta;*.faa;*.fna;*.fa.gz;*.fasta.gz|All files (*.*)|*.*'; if ($p) { $enrichAnnotationSequenceText.Text = $p } })
$networkAnnotationSequenceBrowse.Add_Click({ $p = Select-InputFile 'Select protein or CDS FASTA for functional annotation' 'FASTA files (*.fa;*.fasta;*.faa;*.fna;*.fa.gz;*.fasta.gz)|*.fa;*.fasta;*.faa;*.fna;*.fa.gz;*.fasta.gz|All files (*.*)|*.*'; if ($p) { $networkAnnotationSequenceText.Text = $p } })
$enrichAnnotationTestButton.Add_Click({ Test-OnlineAnnotationDatabase })
$enrichFindOrganism.Add_Click({
    try { [void](Start-Process -FilePath 'https://www.ncbi.nlm.nih.gov/taxonomy') }
    catch { Show-Error 'Could not open NCBI Taxonomy. Open https://www.ncbi.nlm.nih.gov/taxonomy manually.' }
})
$networkAnnotationTestButton.Add_Click({ Test-OnlineAnnotationDatabase })
$enrichOfflineMapping.Add_CheckedChanged({
    if ($script:UpdatingEnrichmentMappingMode) { return }
    $script:UpdatingEnrichmentMappingMode = $true
    if ($enrichOfflineMapping.Checked) { $enrichOnlineAnnotation.Checked = $false }
    elseif (-not $enrichOnlineAnnotation.Checked) { $enrichOnlineAnnotation.Checked = $true }
    $script:UpdatingEnrichmentMappingMode = $false
    Update-EnrichmentAnnotationControls
})
$enrichOnlineAnnotation.Add_CheckedChanged({
    if ($script:UpdatingEnrichmentMappingMode) { return }
    $script:UpdatingEnrichmentMappingMode = $true
    if ($enrichOnlineAnnotation.Checked) { $enrichOfflineMapping.Checked = $false }
    elseif (-not $enrichOfflineMapping.Checked) { $enrichOfflineMapping.Checked = $true }
    $script:UpdatingEnrichmentMappingMode = $false
    Update-EnrichmentAnnotationControls
})
$enrichAnnotationModeCombo.Add_SelectedIndexChanged({ Update-EnrichmentAnnotationControls })
$enrichAnnotationOrganismText.Add_TextChanged({ Update-EnrichmentAnnotationControls })
$networkOnlineAnnotation.Add_CheckedChanged({ Update-NetworkAnnotationControls })
$networkAnnotationModeCombo.Add_SelectedIndexChanged({ Update-NetworkAnnotationControls })
Update-EnrichmentAnnotationControls
Update-NetworkAnnotationControls
}

$script:DEMultiTestLevels = @()

function Get-DEConditionLevels {
    $metadataPath = if ($deMetadataText) { [string]$deMetadataText.Text } else { '' }
    $metadataPath = $metadataPath.Trim()
    $column = [string]$deConditionCombo.SelectedItem
    if ([string]::IsNullOrWhiteSpace($metadataPath) -or [string]::IsNullOrWhiteSpace($column)) { return @() }
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return @() }
    # Always wrap imported rows. A one-row metadata table is otherwise a scalar
    # PSCustomObject and does not expose .Count, which previously crashed folder scan
    # when ComboBox selection events fired during automatic metadata loading.
    $rows = @(Read-MetadataRows $metadataPath)
    if ($rows.Count -eq 0) { return @() }
    return @($rows | ForEach-Object { [string]($_.PSObject.Properties[$column].Value) } | Where-Object { $_ } | Sort-Object -Unique)
}

function Update-DEMultiContrastUI {
    $enabled = [bool]$deMultiContrast.Checked
    $deTestCombo.Enabled = -not $enabled
    $deMultiSelectButton.Visible = $enabled
    $deMultiSummary.Visible = $enabled
    $deDesignNote.Visible = -not $enabled
    if ($enabled) {
        $metadataPath = if ($deMetadataText) { [string]$deMetadataText.Text } else { '' }
        $metadataPath = $metadataPath.Trim()
        $conditionColumn = [string]$deConditionCombo.SelectedItem
        $reference = [string]$deReferenceCombo.SelectedItem
        $levels = @(Get-DEConditionLevels | Where-Object { $_ -and $_ -ne $reference })
        $readyForSelection = (-not [string]::IsNullOrWhiteSpace($metadataPath)) -and
            (Test-Path -LiteralPath $metadataPath -PathType Leaf) -and
            (-not [string]::IsNullOrWhiteSpace($conditionColumn)) -and
            ($levels.Count -ge 2)
        $deMultiSelectButton.Enabled = $readyForSelection

        if (-not $readyForSelection) {
            $script:DEMultiTestLevels = @()
            if ([string]::IsNullOrWhiteSpace($metadataPath) -or -not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
                $deMultiSummary.Text = 'Multiple-treatment mode enabled. First select the sample metadata file containing Control and all treatment groups.'
            } elseif ([string]::IsNullOrWhiteSpace($conditionColumn)) {
                $deMultiSummary.Text = 'Multiple-treatment mode enabled. Choose the metadata condition column, then select the shared control/reference.'
            } else {
                $deMultiSummary.Text = 'Multiple-treatment mode needs at least two treatment groups in addition to the selected control/reference.'
            }
            return
        }

        $script:DEMultiTestLevels = @($script:DEMultiTestLevels | Where-Object { $levels -contains $_ -and $_ -ne $reference })
        if (-not $script:DEMultiTestLevels.Count) { $script:DEMultiTestLevels = @($levels) }
        $selectedText = if ($script:DEMultiTestLevels.Count) { $script:DEMultiTestLevels -join ', ' } else { 'none selected' }
        $deMultiSummary.Text = "Recommended: one raw-count matrix + one metadata table containing all groups. Selected treatments: $selectedText"
    } else {
        $deMultiSelectButton.Enabled = $true
    }
}

function Show-DEMultiContrastDialog {
    $metadataPath = if ($deMetadataText) { [string]$deMetadataText.Text } else { '' }
    $metadataPath = $metadataPath.Trim()
    if ([string]::IsNullOrWhiteSpace($metadataPath) -or -not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        Show-Error 'Select the sample metadata file first. It should contain the shared control and all treatment groups.'
        return
    }
    $reference = [string]$deReferenceCombo.SelectedItem
    $levels = @(Get-DEConditionLevels | Where-Object { $_ -and $_ -ne $reference })
    if ($levels.Count -lt 2) {
        Show-Error 'Multiple-treatment mode requires at least two treatment levels in addition to the selected control/reference.'
        return
    }
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Choose treatment groups'
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.ClientSize = [System.Drawing.Size]::new(650, 480)
    $dialog.MinimumSize = [System.Drawing.Size]::new(600, 440)
    $dialog.BackColor = $background
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $intro = New-Label "Reference/control: $reference`r`nSelect two or more treatment groups. The model will be fitted once using all samples, then one treatment-versus-control contrast will be extracted for each checked level." 18 16 610 66
    $intro.ForeColor = $muted
    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Location = [System.Drawing.Point]::new(18, 92)
    $list.Size = [System.Drawing.Size]::new(614, 290)
    $list.CheckOnClick = $true
    $list.BackColor = $surface
    $list.ForeColor = $ink
    $list.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    foreach ($level in $levels) {
        $index = $list.Items.Add($level)
        if ($script:DEMultiTestLevels -contains $level) { $list.SetItemChecked($index, $true) }
    }
    $cancel = New-Button 'Cancel' 402 402 100 34
    $ok = New-Button 'Use selected groups' 512 402 120 34 -Primary
    $cancel.Add_Click({ $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dialog.Close() })
    $ok.Add_Click({
        $selected = @($list.CheckedItems | ForEach-Object { [string]$_ })
        if ($selected.Count -lt 2) { Show-Error 'Select at least two treatment groups for multiple-treatment mode.'; return }
        $script:DEMultiTestLevels = @($selected)
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })
    $dialog.Controls.AddRange(@($intro, $list, $cancel, $ok))
    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()
    Update-DEMultiContrastUI
}

$deMultiContrast.Add_CheckedChanged({ Update-DEMultiContrastUI })
$deMultiSelectButton.Add_Click({ Show-DEMultiContrastDialog })
$deReferenceCombo.Add_SelectedIndexChanged({ Update-DEMultiContrastUI })

$deManualExcelButton.Add_Click({
    try {
        $result = Invoke-ManualWorkbookInput 'de'
        if ($null -eq $result) { return }
        $counts = Get-ManualWorkbookFile $result 'raw_counts.tsv'
        $metadata = Get-ManualWorkbookFile $result 'sample_metadata.tsv'
        $coordinates = Get-ManualWorkbookFile $result 'gene_coordinates.tsv'
        if (-not $counts -or -not $metadata) { throw 'The input workbook did not produce both required count and metadata tables.' }
        $deCountText.Text = $counts
        Load-DEMetadataControls $metadata
        $deAnnotationText.Text = $coordinates
        if (-not $deOutputText.Text.Trim()) { $deOutputText.Text = [System.IO.Path]::GetDirectoryName($result.Workbook) }
        Show-Message "The input workbook was validated and assigned.`r`n`r`nRaw counts: $counts`r`nSample metadata: $metadata`r`nGene coordinates: $(if($coordinates){$coordinates}else{'not supplied (optional)'})" 'Manual Differential Expression input'
    } catch { Show-Error $_.Exception.Message }
})

if ($script:InitialTab -ne 'de') {
$enrichManualExcelButton.Add_Click({
    try {
        $result = Invoke-ManualWorkbookInput 'combined'
        if ($null -eq $result) { return }
        $deResult = Get-ManualWorkbookFile $result 'differential_expression.tsv'
        $expression = Get-ManualWorkbookFile $result 'normalized_expression.tsv'
        $metadata = Get-ManualWorkbookFile $result 'sample_metadata.tsv'
        $mapping = Get-ManualWorkbookFile $result 'gene_to_term_mapping.tsv'
        $universe = Get-ManualWorkbookFile $result 'gene_universe.tsv'
        $regulators = Get-ManualWorkbookFile $result 'regulators.tsv'
        if (-not $deResult -or -not $expression -or -not $metadata) { throw 'The input workbook did not produce the required DE, normalized-expression, and sample-metadata tables.' }
        $enrichResultText.Text = $deResult
        $networkExprText.Text = $expression
        $networkMetadataText.Text = $metadata
        $headers = @(Get-TableHeaders $metadata)
        Fill-Combo $networkSampleColumnCombo $headers $(if ($headers.Count) { $headers[0] } else { '' })
        if ($mapping) {
            $enrichMappingText.Text = $mapping
            $enrichOfflineMapping.Checked = $true
        } else {
            $enrichMappingText.Text = ''
            $enrichOnlineAnnotation.Checked = $true
        }
        $enrichUniverseText.Text = $universe
        $networkRegulatorText.Text = $regulators
        if (-not $enrichOutputText.Text.Trim()) { $enrichOutputText.Text = [System.IO.Path]::GetDirectoryName($result.Workbook) }
        Show-Message "The input workbook was validated and assigned.`r`n`r`nDE result: $deResult`r`nNormalized expression: $expression`r`nSample metadata: $metadata`r`nMapping: $(if($mapping){$mapping}else{'online annotation remains selected'})`r`nUniverse: $(if($universe){$universe}else{'not supplied (optional)'})`r`nRegulators: $(if($regulators){$regulators}else{'not supplied (optional)'})" 'Manual functional/co-expression input'
    } catch { Show-Error $_.Exception.Message }
})

}

# Folder auto-scan handlers. Keep every WinForms click boundary guarded so a
# malformed or unusually small metadata table produces a normal application
# message instead of escaping into the .NET JIT exception dialog.
$deScanFolderButton.Add_Click({
    try { Scan-DownstreamResultFolder 'de' }
    catch { Show-Error ("Folder scan could not be completed.`r`n`r`n" + $_.Exception.Message) }
})
if ($script:InitialTab -ne 'de') {
$enrichScanFolderButton.Add_Click({
    try { Scan-DownstreamResultFolder 'enrichment' }
    catch { Show-Error ("Folder scan could not be completed.`r`n`r`n" + $_.Exception.Message) }
})
$networkScanFolderButton.Add_Click({
    try { Scan-DownstreamResultFolder 'network' }
    catch { Show-Error ("Folder scan could not be completed.`r`n`r`n" + $_.Exception.Message) }
})

}

# Browse handlers
$deCountBrowse.Add_Click({ $p = Select-InputFile 'Select raw gene count matrix' 'Delimited tables (*.tsv;*.txt;*.csv)|*.tsv;*.txt;*.csv|All files (*.*)|*.*'; if ($p) { $deCountText.Text = $p } })
$deMetadataBrowse.Add_Click({
    $p = Select-InputFile 'Select sample metadata' 'Delimited tables (*.tsv;*.txt;*.csv)|*.tsv;*.txt;*.csv|All files (*.*)|*.*'
    if ($p) {
        Load-DEMetadataControls $p
    }
})
$deAnnotationBrowse.Add_Click({ $p = Select-InputFile 'Select gene-coordinate table' 'Delimited tables (*.tsv;*.txt;*.csv)|*.tsv;*.txt;*.csv|All files (*.*)|*.*'; if ($p) { $deAnnotationText.Text = $p } })
$deOutputBrowse.Add_Click({ $p = Select-OutputFolder 'Select differential-expression result folder'; if ($p) { $deOutputText.Text = $p } })
$deConditionCombo.Add_SelectedIndexChanged({
    try {
        # Keep row collections as arrays even for one biological sample.
        $rows = @(Read-MetadataRows $deMetadataText.Text)
        $column = [string]$deConditionCombo.SelectedItem
        if ($rows.Count -gt 0 -and $column) {
            $levels = @($rows | ForEach-Object {
                $property = $_.PSObject.Properties[$column]
                if ($null -ne $property) { [string]$property.Value }
            } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
            Fill-Combo $deReferenceCombo $levels
            Fill-Combo $deTestCombo $levels $(if ($levels.Count -gt 1) { $levels[1] } else { '' })
            $script:DEMultiTestLevels = @($levels | Where-Object { $_ -ne [string]$deReferenceCombo.SelectedItem })
            Update-DEMultiContrastUI
        } else {
            Fill-Combo $deReferenceCombo @()
            Fill-Combo $deTestCombo @()
            $script:DEMultiTestLevels = @()
        }
    } catch {
        # Never allow a ComboBox selection event to escape into the WinForms JIT dialog.
        Fill-Combo $deReferenceCombo @()
        Fill-Combo $deTestCombo @()
        $script:DEMultiTestLevels = @()
        Show-Error ("Could not read metadata condition levels.`r`n`r`n" + $_.Exception.Message)
    }
})
if ($script:InitialTab -ne 'de') {
$enrichResultBrowse.Add_Click({ $p = Select-InputFile 'Select differential-expression result table' 'Delimited tables (*.tsv;*.txt;*.csv)|*.tsv;*.txt;*.csv|All files (*.*)|*.*'; if ($p) { $enrichResultText.Text = $p } })
$enrichMappingBrowse.Add_Click({ $p = Select-InputFile 'Select gene-to-term mapping' 'Delimited tables (*.tsv;*.txt;*.csv;*.gmt)|*.tsv;*.txt;*.csv;*.gmt|All files (*.*)|*.*'; if ($p) { $enrichMappingText.Text = $p } })
$enrichUniverseBrowse.Add_Click({ $p = Select-InputFile 'Select custom gene universe' 'Delimited tables (*.tsv;*.txt;*.csv)|*.tsv;*.txt;*.csv|All files (*.*)|*.*'; if ($p) { $enrichUniverseText.Text = $p } })
$enrichOutputBrowse.Add_Click({ $p = Select-OutputFolder 'Select the combined functional-analysis result folder'; if ($p) { $enrichOutputText.Text = $p } })
$networkExprBrowse.Add_Click({ $p = Select-InputFile 'Select normalized expression matrix' 'Delimited tables (*.tsv;*.txt;*.csv)|*.tsv;*.txt;*.csv|All files (*.*)|*.*'; if ($p) { $networkExprText.Text = $p } })
$networkMetadataBrowse.Add_Click({
    $p = Select-InputFile 'Select sample metadata' 'Delimited tables (*.tsv;*.txt;*.csv)|*.tsv;*.txt;*.csv|All files (*.*)|*.*'
    if ($p) {
        $networkMetadataText.Text = $p
        $headers = @(Get-TableHeaders $p)
        Fill-Combo $networkSampleColumnCombo $headers $(if ($headers.Count) { $headers[0] } else { '' })
    }
})
$networkRegulatorBrowse.Add_Click({ $p = Select-InputFile 'Select regulator list' 'Delimited tables (*.tsv;*.txt;*.csv)|*.tsv;*.txt;*.csv|All files (*.*)|*.*'; if ($p) { $networkRegulatorText.Text = $p } })
$networkOutputBrowse.Add_Click({ $p = Select-OutputFolder 'Select network result folder'; if ($p) { $networkOutputText.Text = $p } })
$networkExprText.Add_TextChanged({
    $path = $networkExprText.Text.Trim()
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    try {
        $sampleColumns = [Math]::Max(0, (@(Get-TableHeaders $path)).Count - 1)
        if ($sampleColumns -gt 0 -and $sampleColumns -lt 15) { $networkExploratory.Checked = $true }
    } catch { }
})

$networkMethodCombo.Add_SelectedIndexChanged({ Update-NetworkControls })
Update-NetworkControls
}

$deOutputText.Add_TextChanged({
    $candidate = $deOutputText.Text.Trim()
    if ($candidate -and (Find-AnalysisDataFile $candidate 'differential_expression.tsv')) {
        $script:LastDEOutput = $candidate
    } elseif ($script:LastDEOutput -ne $candidate) {
        $script:LastDEOutput = ''
    }
})
if ($script:InitialTab -ne 'de') {
$enrichOutputText.Add_TextChanged({
    $candidate = $enrichOutputText.Text.Trim()
    if ($candidate -and (Find-AnalysisDataFile $candidate 'enrichment_results.tsv') -and (Find-AnalysisDataFile $candidate 'network_edges.tsv')) {
        $script:LastFunctionalOutput = $candidate
        $script:LastEnrichmentOutput = $candidate
        $script:LastNetworkOutput = $candidate
    } elseif ($script:LastEnrichmentOutput -ne $candidate) {
        $script:LastFunctionalOutput = ''
        $script:LastEnrichmentOutput = ''
        $script:LastNetworkOutput = ''
    }
})
$networkOutputText.Add_TextChanged({
    $candidate = $networkOutputText.Text.Trim()
    if ($candidate -and (Find-AnalysisDataFile $candidate 'network_edges.tsv')) {
        $script:LastNetworkOutput = $candidate
    } elseif ($script:LastNetworkOutput -ne $candidate) {
        $script:LastNetworkOutput = ''
    }
})

}

# Analysis handlers
$runDEButton.Add_Click({
    if (-not (Test-RequiredPath $deCountText 'Raw count matrix')) { return }
    if (-not (Test-RequiredPath $deMetadataText 'Sample metadata')) { return }
    if (-not (Test-RequiredPath $deOutputText 'Results folder' -Folder)) { return }
    if (-not $deConditionCombo.SelectedItem -or -not $deReferenceCombo.SelectedItem) { Show-Error 'Select the metadata condition column and reference level.'; return }
    if ($deMultiContrast.Checked) {
        if ($script:DEMultiTestLevels.Count -lt 2) { Show-Error 'Multiple-treatment mode requires at least two selected treatment groups. Click Choose treatment groups.'; return }
        if ($script:DEMultiTestLevels -contains [string]$deReferenceCombo.SelectedItem) { Show-Error 'The reference/control cannot also be one of the selected treatment groups.'; return }
    } else {
        if (-not $deTestCombo.SelectedItem) { Show-Error 'Select the test level.'; return }
        if ([string]$deReferenceCombo.SelectedItem -eq [string]$deTestCombo.SelectedItem) { Show-Error 'Reference and test levels must be different.'; return }
    }
    $validatedMinCount = 0
    $validatedMinSamples = 0
    $validatedPadj = 0.0
    $validatedLfc = 0.0
    if (-not (Test-IntegerRange $deMinCount 'Minimum count' 0 10000000 ([ref]$validatedMinCount))) { return }
    if (-not (Test-IntegerRange $deMinSamples 'Minimum samples' 3 10000 ([ref]$validatedMinSamples))) { return }
    if (-not (Test-DoubleRange $dePadj 'Adjusted p-value' 0 1 $false ([ref]$validatedPadj))) { return }
    if (-not (Test-DoubleRange $deLfc 'Absolute log2 fold-change threshold' 0 50 $true ([ref]$validatedLfc))) { return }
    $metadataRows = Read-MetadataRows $deMetadataText.Text
    $conditionName = [string]$deConditionCombo.SelectedItem
    if ($metadataRows.Count -and $conditionName) {
        $referenceName = [string]$deReferenceCombo.SelectedItem
        $testsToValidate = if ($deMultiContrast.Checked) { @($script:DEMultiTestLevels) } else { @([string]$deTestCombo.SelectedItem) }
        $referenceCount = @($metadataRows | Where-Object { [string]($_.PSObject.Properties[$conditionName].Value) -eq $referenceName }).Count
        if ($referenceCount -lt 3) { Show-Error "At least three biological samples are required in the reference/control '$referenceName'. Detected $referenceCount."; return }
        foreach ($testName in $testsToValidate) {
            $testCount = @($metadataRows | Where-Object { [string]($_.PSObject.Properties[$conditionName].Value) -eq $testName }).Count
            if ($testCount -lt 3) { Show-Error "At least three biological samples are required in treatment '$testName'. Detected $testCount."; return }
        }
    }
    $distro = Get-WslDistroLocal
    try {
        $engine = switch -Wildcard ([string]$deEngineCombo.SelectedItem) { 'DESeq2*' { 'deseq2' } 'edgeR*' { 'edger' } default { 'limma-voom' } }
        $analysisOutput = Get-OrganizedAnalysisOutput 'de' $deOutputText.Text $engine
        [void][System.IO.Directory]::CreateDirectory($analysisOutput)
        $deOutputText.Text = $analysisOutput
        $config = @{
            count_file = Convert-ToWslPathLocal $deCountText.Text $distro
            metadata_file = Convert-ToWslPathLocal $deMetadataText.Text $distro
            annotation_file = if ($deAnnotationText.Text.Trim()) { Convert-ToWslPathLocal $deAnnotationText.Text $distro } else { '' }
            output_dir = Convert-ToWslPathLocal $analysisOutput $distro
            engine = $engine
            gene_column = ''
            sample_column = [string]$deSampleColumnCombo.SelectedItem
            condition_column = [string]$deConditionCombo.SelectedItem
            batch_column = if ([string]$deBatchCombo.SelectedItem -eq 'None') { '' } else { [string]$deBatchCombo.SelectedItem }
            reference_level = [string]$deReferenceCombo.SelectedItem
            test_level = if ($deMultiContrast.Checked) { [string]$script:DEMultiTestLevels[0] } else { [string]$deTestCombo.SelectedItem }
            test_levels = if ($deMultiContrast.Checked) { @($script:DEMultiTestLevels) } else { @([string]$deTestCombo.SelectedItem) }
            multi_contrast = [bool]$deMultiContrast.Checked
            min_count = $validatedMinCount
            min_samples = $validatedMinSamples
            padj_cutoff = $validatedPadj
            lfc_cutoff = $validatedLfc
            advanced_package_options = (Get-AdvancedPackageConfig 'de')
            plots = @()
        }
        Start-AnalysisJob 'de' $config $analysisOutput
    } catch { Show-Error $_.Exception.Message }
})

if ($script:InitialTab -ne 'de') {
$runKeggMapButton.Add_Click({
    if (-not (Test-RequiredPath $enrichResultText 'Differential-expression result table')) { return }
    if (-not (Test-RequiredPath $enrichOutputText 'Results folder' -Folder)) { return }
    if ([string]::IsNullOrWhiteSpace($keggMapIdsText.Text)) { Show-Error 'Enter at least one KEGG pathway ID, for example 00010 or ko00010.'; return }
    if ($keggMapGeneText.Text.Trim() -and -not (Test-RequiredPath $keggMapGeneText 'Gene-ID mapping table')) { return }
    $mapPadj = 0.0; $mapLfc = 0.0
    if (-not (Test-DoubleRange $enrichPadj 'Gene adjusted p-value' 0 1 $false ([ref]$mapPadj))) { return }
    if (-not (Test-DoubleRange $enrichLfc 'Absolute log2 fold-change threshold' 0 50 $true ([ref]$mapLfc))) { return }
    try {
        $distro = Get-WslDistroLocal
        $analysisOutput = Get-OrganizedAnalysisOutput 'combined' $enrichOutputText.Text
        $config = @{
            result_file = Convert-ToWslPathLocal $enrichResultText.Text $distro
            output_dir = Convert-ToWslPathLocal $analysisOutput $distro
            result_gene_column = 'gene_id'; lfc_column = 'log2FoldChange'; padj_column = 'padj'
            padj_cutoff = $mapPadj; lfc_cutoff = $mapLfc
            integrated_kegg_organism = $integratedKeggOrganism.Text.Trim()
            kegg_map_enabled = $true
            kegg_map_pathway_ids = $keggMapIdsText.Text.Trim()
            kegg_map_gene_mapping = if($keggMapGeneText.Text.Trim()){Convert-ToWslPathLocal $keggMapGeneText.Text $distro}else{''}
            kegg_map_offline = [bool]$keggMapOffline.Checked
        }
        $enrichOutputText.Text = $analysisOutput
        Start-AnalysisJob 'pathway_map' $config $analysisOutput
    } catch { Show-Error $_.Exception.Message }
})
$runEnrichmentButton.Add_Click({
    if (-not (Test-RequiredPath $enrichResultText 'Differential-expression result table')) { return }
    if (-not (Test-RequiredPath $networkExprText 'Normalized expression matrix')) { return }
    if (-not (Test-RequiredPath $networkMetadataText 'Sample metadata')) { return }
    if (-not $networkSampleColumnCombo.SelectedItem) { Show-Error 'Select the sample-ID column from the shared sample metadata.'; return }
    $onlineAnnotation = [bool]$enrichOnlineAnnotation.Checked
    $offlineAnnotation = [bool]$enrichOfflineMapping.Checked
    if (-not $onlineAnnotation -and -not $offlineAnnotation) { Show-Error 'Choose either Gene-to-term mapping (offline) or Gene-to-term mapping (online).'; return }
    if ($onlineAnnotation -and $enrichAnnotationOrganismText.Text -like 'Other / more organisms*') { Show-Error 'Click Find organism, then replace Other / more organisms with the exact organism name or NCBI taxonomy ID.'; return }
    $annotationMode = Get-OnlineAnnotationModeKey ([string]$enrichAnnotationModeCombo.SelectedItem)
    $annotationOrganism = Get-OrganismQueryText $enrichAnnotationOrganismText
    if ($offlineAnnotation -and -not (Test-RequiredPath $enrichMappingText 'Gene-to-term mapping file')) { return }
    if ($onlineAnnotation -and [string]::IsNullOrWhiteSpace($annotationOrganism) -and -not (Confirm-UnrestrictedOrganismSearch)) { return }
    if ($onlineAnnotation -and $annotationMode -ne 'gene_ids' -and -not (Test-RequiredPath $enrichAnnotationSequenceText 'Sequence FASTA')) { return }
    if (-not (Test-RequiredPath $enrichOutputText 'Combined results folder' -Folder)) { return }

    $integratedTerm2GenePath = $integratedTerm2GeneText.Text.Trim()
    $integratedBioCycPath = $integratedBioCycText.Text.Trim()
    $integratedMetaCycPath = $integratedMetaCycText.Text.Trim()
    foreach($mappingInput in @(
        @('Custom TERM2GENE mapping',$integratedTerm2GenePath,$integratedTerm2GeneText),
        @('BioCyc mapping',$integratedBioCycPath,$integratedBioCycText),
        @('MetaCyc mapping',$integratedMetaCycPath,$integratedMetaCycText)
    )) {
        if([string]::IsNullOrWhiteSpace([string]$mappingInput[1])){continue}
        if(-not (Test-Path -LiteralPath ([string]$mappingInput[1]) -PathType Leaf)){Show-Error "$($mappingInput[0]) was not found.`r`n$($mappingInput[1])";$mappingInput[2].Focus();return}
    }

    $integratedKeggQuery = ''
    if ($keggMapEnabled.Checked) {
        if ([string]::IsNullOrWhiteSpace($keggMapIdsText.Text)) { Show-Error 'Enter KEGG pathway IDs for expression mapping, or clear Map expression onto KEGG pathways.'; return }
        if ($keggMapGeneText.Text.Trim() -and -not (Test-RequiredPath $keggMapGeneText 'Gene-ID mapping table')) { return }
    }
    if ($integratedKeggEnabled.Checked -or $keggMapEnabled.Checked) {
        $integratedKeggQuery = $integratedKeggOrganism.Text.Trim()
        if (-not $integratedKeggQuery) { Show-Error 'Choose or type an online KEGG organism code.'; return }
        if ($integratedKeggQuery -match '^\s*([A-Za-z][A-Za-z0-9]{2,5})\s*[·|]') { $integratedKeggQuery = [string]$Matches[1] }
    }
    $integratedStringTaxid = 0
    $integratedStringScoreValue = 0
    if ($integratedStringEnabled.Checked) {
        $stringOrganismValue = $integratedStringOrganism.Text.Trim()
        if ($stringOrganismValue -match '(?i)taxid\s*:\s*(\d+)') { $integratedStringTaxid = [int]$Matches[1] }
        elseif (-not [int]::TryParse($stringOrganismValue, [ref]$integratedStringTaxid)) { Show-Error 'Choose a supported STRING organism or enter its numeric taxonomy ID.'; return }
        if ($integratedStringTaxid -lt 1) { Show-Error 'STRING taxonomy ID must be a positive integer.'; return }
        if (-not (Test-IntegerRange $integratedStringScore 'Minimum STRING score' 0 1000 ([ref]$integratedStringScoreValue))) { return }
    }

    $validatedEnrichPadj = 0.0
    $validatedEnrichLfc = 0.0
    $validatedMinSet = 0
    $validatedMaxSet = 0
    if (-not (Test-DoubleRange $enrichPadj 'Gene adjusted p-value' 0 1 $false ([ref]$validatedEnrichPadj))) { return }
    if (-not (Test-DoubleRange $enrichLfc 'Absolute log2 fold-change threshold' 0 50 $true ([ref]$validatedEnrichLfc))) { return }
    if (-not (Test-IntegerRange $minSet 'Minimum gene-set size' 1 100000 ([ref]$validatedMinSet))) { return }
    if (-not (Test-IntegerRange $maxSet 'Maximum gene-set size' 1 1000000 ([ref]$validatedMaxSet))) { return }
    if ($validatedMaxSet -lt $validatedMinSet) { Show-Error 'Maximum gene-set size must be greater than or equal to minimum gene-set size.'; return }

    $validatedMaxGenes = 0
    $validatedMinModule = 0
    $validatedEdgeThreshold = 0.0
    $validatedMaxEdges = 0
    $validatedTrees = 0
    $validatedThreads = 0
    if (-not (Test-IntegerRange $maxGenesText 'Maximum genes' 100 50000 ([ref]$validatedMaxGenes))) { return }
    if (-not (Test-IntegerRange $minModuleText 'Minimum module size' 5 5000 ([ref]$validatedMinModule))) { return }
    if (-not (Test-DoubleRange $edgeThresholdText 'Edge threshold' 0 1 $true ([ref]$validatedEdgeThreshold))) { return }
    if (-not (Test-IntegerRange $maxEdgesText 'Maximum exported edges' 100 10000000 ([ref]$validatedMaxEdges))) { return }
    if (-not (Test-IntegerRange $nTreesText 'GENIE3 trees' 100 10000 ([ref]$validatedTrees))) { return }
    if (-not (Test-IntegerRange $threadsText 'CPU threads' 1 128 ([ref]$validatedThreads))) { return }
    $softPowerValue = $softPowerText.Text.Trim().ToLowerInvariant()
    if ($softPowerValue -ne 'auto') {
        $validatedSoftPower = 0
        if (-not [int]::TryParse($softPowerValue, [ref]$validatedSoftPower) -or $validatedSoftPower -lt 1 -or $validatedSoftPower -gt 30) {
            Show-Error 'Soft power must be auto or a whole number from 1 to 30.'
            $softPowerText.Focus()
            return
        }
        $softPowerValue = [string]$validatedSoftPower
    }
    $headers = Get-TableHeaders $networkExprText.Text
    $sampleCount = [Math]::Max(0, $headers.Count - 1)
    if ($sampleCount -gt 0 -and $sampleCount -lt 15) {
        # Small-sample network inference is permitted only as an explicitly
        # exploratory analysis. Select the flag automatically so one combined
        # run proceeds smoothly while the report retains the warning label.
        $networkExploratory.Checked = $true
    }
    $enrichmentMethod = switch -Wildcard ([string]$enrichMethodCombo.SelectedItem) { 'clusterProfiler*' { 'ora' } 'fgsea*' { 'fgsea' } default { 'topgo' } }
    $networkMethod = switch -Wildcard ([string]$networkMethodCombo.SelectedItem) { 'CEMiTool*' { 'cemitool' } 'WGCNA*' { 'wgcna' } default { 'genie3' } }
    if ($networkMethod -in @('cemitool', 'wgcna') -and $sampleCount -lt 15 -and -not $networkExploratory.Checked) {
        Show-Error "Only $sampleCount sample columns were detected. CEMiTool and WGCNA require at least 15 samples in this interface. Select exploratory mode only when you accept that the network will be unstable."
        return
    }

    $distro = Get-WslDistroLocal
    try {
        $analysisOutput = Get-OrganizedAnalysisOutput 'combined' $enrichOutputText.Text
        [void][System.IO.Directory]::CreateDirectory($analysisOutput)
        $enrichOutputText.Text = $analysisOutput
        $networkOutputText.Text = $analysisOutput
        $mappingWsl = if ($onlineAnnotation) { '' } else { Convert-ToWslPathLocal $enrichMappingText.Text $distro }
        $config = @{
            result_file = Convert-ToWslPathLocal $enrichResultText.Text $distro
            expression_file = Convert-ToWslPathLocal $networkExprText.Text $distro
            metadata_file = Convert-ToWslPathLocal $networkMetadataText.Text $distro
            regulator_file = if ($networkRegulatorText.Text.Trim()) { Convert-ToWslPathLocal $networkRegulatorText.Text $distro } else { '' }
            mapping_file = $mappingWsl
            universe_file = if ($enrichUniverseText.Text.Trim()) { Convert-ToWslPathLocal $enrichUniverseText.Text $distro } else { '' }
            output_dir = Convert-ToWslPathLocal $analysisOutput $distro
            method = $enrichmentMethod
            enrichment_method = $enrichmentMethod
            network_method = $networkMethod
            annotation_source = [string]$enrichSourceCombo.SelectedItem
            result_gene_column = 'gene_id'
            gene_column = ''
            sample_column = [string]$networkSampleColumnCombo.SelectedItem
            mapping_gene_column = $mapGeneText.Text.Trim()
            mapping_term_column = $mapTermText.Text.Trim()
            mapping_name_column = $mapNameText.Text.Trim()
            mapping_source_column = $mapSourceText.Text.Trim()
            padj_column = 'padj'
            lfc_column = 'log2FoldChange'
            rank_column = $rankColumnText.Text.Trim()
            direction = ([string]$enrichDirectionCombo.SelectedItem).ToLowerInvariant()
            padj_cutoff = $validatedEnrichPadj
            lfc_cutoff = $validatedEnrichLfc
            min_gene_set_size = $validatedMinSet
            max_gene_set_size = $validatedMaxSet
            term_padj_cutoff = 0.05
            p_adjust_method = 'BH'
            go_ontology = [string]$goOntologyCombo.SelectedItem
            log_transform = [bool]$networkLogTransform.Checked
            minimum_mean_expression = 0
            maximum_genes = $validatedMaxGenes
            correlation_method = ([string]$networkCorrelationCombo.SelectedItem).ToLowerInvariant()
            network_type = ([string]$networkTypeCombo.SelectedItem).ToLowerInvariant()
            soft_power = $softPowerValue
            scale_free_r2 = 0.80
            minimum_module_size = $validatedMinModule
            merge_cut_height = 0.25
            edge_threshold = $validatedEdgeThreshold
            max_edges = $validatedMaxEdges
            max_plot_edges = 500
            plots = @()
            graph_layout = 'spring'
            show_node_labels = $false
            node_label_count = 30
            n_trees = $validatedTrees
            threads = $validatedThreads
            exploratory_override = [bool]$networkExploratory.Checked
            automatic_module_detection = [bool]$networkAutoModules.Checked
            online_annotation_enabled = $onlineAnnotation
            annotation_mapping_file = $mappingWsl
            annotation_input_mode = $annotationMode
            annotation_database = Get-OnlineAnnotationDatabaseKey ([string]$enrichAnnotationDatabaseCombo.SelectedItem)
            annotation_organism = $annotationOrganism
            annotation_sequence_file = if ($onlineAnnotation -and $annotationMode -ne 'gene_ids') { Convert-ToWslPathLocal $enrichAnnotationSequenceText.Text $distro } else { '' }
            annotation_refresh_database = [bool]$enrichAnnotationRefresh.Checked
            annotation_evalue = 0.00001
            annotation_min_identity = 30.0
            integrated_pathway_enabled = [bool]($integratedKeggEnabled.Checked -or $integratedTerm2GenePath -or $integratedBioCycPath -or $integratedMetaCycPath)
            kegg_map_enabled = [bool]$keggMapEnabled.Checked
            kegg_map_pathway_ids = $keggMapIdsText.Text.Trim()
            kegg_map_gene_mapping = if($keggMapGeneText.Text.Trim()){Convert-ToWslPathLocal $keggMapGeneText.Text $distro}else{''}
            kegg_map_offline = [bool]$keggMapOffline.Checked
            integrated_kegg_enabled = [bool]$integratedKeggEnabled.Checked
            integrated_kegg_organism = $integratedKeggQuery
            integrated_pathway_term2gene = if($integratedTerm2GenePath){Convert-ToWslPathLocal $integratedTerm2GenePath $distro}else{''}
            integrated_pathway_biocyc_mapping = if($integratedBioCycPath){Convert-ToWslPathLocal $integratedBioCycPath $distro}else{''}
            integrated_pathway_metacyc_mapping = if($integratedMetaCycPath){Convert-ToWslPathLocal $integratedMetaCycPath $distro}else{''}
            # The former acknowledgement checkbox was removed from the guided UI.
            # Keep the backend flag explicit so KEGG retrieval remains deterministic.
            integrated_kegg_confirmed = $true
            integrated_string_enabled = [bool]$integratedStringEnabled.Checked
            integrated_string_taxid = $integratedStringTaxid
            integrated_string_network_type = ([string]$integratedStringType.SelectedItem).ToLowerInvariant()
            integrated_string_required_score = $integratedStringScoreValue
            integrated_string_add_nodes = 0
            integrated_string_identifier_aliases = ''
            advanced_package_options = (Get-AdvancedPackageConfig 'combined')
        }
        Start-AnalysisJob 'combined' $config $analysisOutput
    } catch { Show-Error $_.Exception.Message }
})

# Legacy hidden control delegates to the only supported coordinated run.
$runNetworkButton.Add_Click({ $runEnrichmentButton.PerformClick() })
}

# Result, environment, and navigation handlers
$instructionsButton.Add_Click({
    $path = $script:InstructionPath
    if (Test-Path -LiteralPath $path -PathType Leaf) { Start-Process -FilePath $path | Out-Null }
    else { Show-Error 'The instruction file for this analysis application was not found.' }
})
$openDEStudioButton.Add_Click({ Open-VisualizationStudio 'de' $(if ($script:LastDEOutput) { $script:LastDEOutput } else { $deOutputText.Text.Trim() }) })
if ($script:InitialTab -ne 'de') {
    $openEnrichmentStudioButton.Add_Click({ Open-VisualizationStudio 'combined' $(if ($script:LastFunctionalOutput) { $script:LastFunctionalOutput } else { $enrichOutputText.Text.Trim() }) })
    $openNetworkStudioButton.Add_Click({ Open-VisualizationStudio 'combined' $(if ($script:LastFunctionalOutput) { $script:LastFunctionalOutput } else { $enrichOutputText.Text.Trim() }) })
}
$useLatestRnaSeqButton.Add_Click({
    $ready = Get-LatestRnaSeqAnalysisReady
    if (-not $ready) {
        Show-Error 'No completed RNA-seq processing result was found in this suite session. Complete RNA-seq processing first, or browse to raw counts and metadata manually.'
        return
    }
    $countPath = Select-LatestRnaSeqCountMatrix $ready
    $metadataCandidates = @(
        (Join-Path $ready 'intermediate\Metadata\sample metadata.tsv'),
        (Join-Path $ready 'intermediate\Metadata\sample_metadata.tsv'),
        (Join-Path $ready 'Intermediate files\Metadata\sample metadata.tsv'),
        (Join-Path $ready 'Intermediate files\Metadata\sample_metadata.tsv'),
        (Join-Path $ready 'metadata\sample_metadata.tsv')
    )
    $metadataPath = ''
    foreach ($candidate in $metadataCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $metadataPath = $candidate; break }
    }
    $coordinateCandidates = @(
        (Join-Path $ready 'Intermediate files\Browser files\Reference\gene_coordinates.tsv'),
        (Join-Path $ready 'intermediate\Browser files\Reference\gene_coordinates.tsv'),
        (Join-Path $ready 'reference\gene_coordinates.tsv'),
        (Join-Path $ready 'Reference\gene_coordinates.tsv'),
        (Join-Path $ready 'intermediate\Reference\gene_coordinates.tsv'),
        (Join-Path $ready 'Intermediate files\Browser files\Reference\gene_metadata.tsv'),
        (Join-Path $ready 'intermediate\Reference\gene metadata.tsv'),
        (Join-Path $ready 'intermediate\Reference\gene_metadata.tsv'),
        (Join-Path $ready 'Reference\gene metadata.tsv'),
        (Join-Path $ready 'Reference\gene_metadata.tsv'),
        (Join-Path $ready 'reference\gene_metadata.tsv'),
        (Join-Path $ready 'metadata\gene_metadata.tsv'),
        (Join-Path $ready 'Intermediate files\Browser files\Reference\features.saf')
    )
    if (-not $countPath) {
        Show-Error "No internal raw-count handoff table could be selected from the completed RNA-seq Results folder:`r`n$ready"
        return
    }
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        Show-Error "The latest RNA-seq result does not contain the internal sample metadata table. Browse to a metadata table manually."
        return
    }
    $deCountText.Text = $countPath
    Load-DEMetadataControls $metadataPath
    foreach ($candidate in $coordinateCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $deAnnotationText.Text = $candidate; break }
    }
    if (-not $deOutputText.Text.Trim()) {
        $projectRoot = Split-Path -Parent $ready
        $deOutputText.Text = $projectRoot
    }
    Show-Message "Loaded the latest RNA-seq analysis-ready export.`r`n`r`nCounts:`r`n$countPath`r`n`r`nMetadata:`r`n$metadataPath`r`n`r`nReview the condition, reference, test, batch, and filtering settings before running." 'Latest RNA-seq result loaded'
})
if ($script:InitialTab -ne 'de') {
$useLastDEButton.Add_Click({
    $folder = Get-SharedAnalysisOutput 'de'
    if (-not $folder) { Show-Error 'No completed differential-expression result was found. Run Differential Expression first, use Scan DE / functional folder, or use Manual Excel input.'; return }
    $dePath = Find-AnalysisDataFile $folder 'differential_expression.tsv'
    $expressionPath = Find-AnalysisDataFile $folder 'normalized_counts.tsv'
    $metadataPath = Find-AnalysisDataFile $folder 'analysis_metadata.tsv'
    if ($dePath) { $enrichResultText.Text = $dePath }
    if ($expressionPath) { $networkExprText.Text = $expressionPath }
    if ($metadataPath) {
        $networkMetadataText.Text = $metadataPath
        $headers = @(Get-TableHeaders $metadataPath)
        Fill-Combo $networkSampleColumnCombo $headers $(if ($headers.Count) { $headers[0] } else { '' })
    }
    $files = @(Get-ScanCandidateFiles $folder)
    $mapping = Find-ScannedFile $files @('term2gene.tsv','term_to_gene.tsv','gene_to_term.tsv') @('*term2gene*.tsv','*term*gene*.tsv','*gene*term*.tsv','*.gmt')
    $universe = Find-AnalysisDataFile $folder 'gene_universe_used.tsv'
    $regulators = Find-ScannedFile $files @('regulators.tsv','regulator_list.tsv') @('*regulator*.tsv')
    if ($mapping) { $enrichMappingText.Text = $mapping; $enrichOfflineMapping.Checked = $true }
    if ($universe) { $enrichUniverseText.Text = $universe }
    if ($regulators) { $networkRegulatorText.Text = $regulators }
    if (-not $enrichOutputText.Text.Trim()) { $enrichOutputText.Text = (Split-Path -Parent $folder) }
    $missing = @()
    if (-not $dePath) { $missing += 'differential-expression result' }
    if (-not $expressionPath) { $missing += 'normalized expression matrix' }
    if (-not $metadataPath) { $missing += 'sample metadata' }
    if ($missing.Count) {
        Show-Error ('The latest DE analysis was found, but these required combined inputs are missing: ' + ($missing -join ', ') + '. Use the section 1 Browse fields, Scan DE / functional folder, or Manual Excel input.')
        return
    }
    Show-Message "Loaded the latest DE result, normalized expression matrix, and sample metadata in one step. Mapping, universe, and regulator files were also loaded when available." 'Combined inputs loaded'
})
$useLastNormalizedButton.Add_Click({
    $useLastDEButton.PerformClick()
})
}
$checkEnvironmentButton.Add_Click({
    $distro = Get-WslDistroLocal
    if (-not $distro) { Show-Error 'No runnable WSL2 Linux distribution was found. Verify that the shared Ubuntu WSL2 environment can start, then use Install or update if the downstream analysis environment is not installed.'; return }
    try {
        $scriptWsl = Convert-ToWslPathLocal $script:CheckScript $distro
        $logPath = New-DownstreamLogPath 'environment_check'
        Start-BashJob 'check' "bash $(Quote-Bash $scriptWsl)" $logPath ''
    } catch { Show-Error $_.Exception.Message }
})
$installEnvironmentButton.Add_Click({
    $installPrompt = if ($script:InitialTab -eq 'de') { 'Check and repair Differential Expression packages? Existing working functional-analysis packages will not be pruned or updated.' } else { 'Install or update the one shared environment for annotation, functional enrichment, co-expression modules, and network inference? The first installation requires Internet access and can take substantial time and disk space.' }; $answer = [System.Windows.Forms.MessageBox]::Show($form, $installPrompt, 'Install combined functional-analysis environment', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $distro = Get-WslDistroLocal
    if (-not $distro) { Show-Error 'No runnable WSL2 Linux distribution was found. Verify that the shared Ubuntu WSL2 environment can start, then use Install or update if the downstream analysis environment is not installed.'; return }
    try {
        $scriptWsl = Convert-ToWslPathLocal $script:SetupScript $distro
        $logPath = New-DownstreamLogPath 'environment_install'
        Start-BashJob 'install' "bash $(Quote-Bash $scriptWsl)" $logPath ''
    } catch { Show-Error $_.Exception.Message }
})
$stopButton.Add_Click({
    if ($script:JobProcess -and -not $script:JobProcess.HasExited) {
        [void](Stop-DownstreamJob 'Stop requested by user')
    }
})
$backButton.Add_Click({
    if ($script:JobProcess -and -not $script:JobProcess.HasExited) { Show-Error 'Stop the current analysis job before returning to the analysis modules.'; return }
    if ($script:EmbeddedMode) {
        $global:BacterialRNAAnalysisReturnTarget = 'home'
        $form.Hide()
    } else { $form.Close() }
})

$form.Add_FormClosing({
    Hide-ParameterHelpPopup
    foreach ($studioProcess in @($script:StudioProcesses)) {
        try { if ($studioProcess -and -not $studioProcess.HasExited) { Stop-Process -Id $studioProcess.Id -Force -ErrorAction SilentlyContinue } } catch { }
    }
    if ($script:SuiteLifecycleTimer) { $script:SuiteLifecycleTimer.Stop() }
    if ($script:SuiteRequestedClose) {
        if ($script:JobProcess -and -not $script:JobProcess.HasExited) {
            [void](Stop-DownstreamJob 'Main suite is closing')
        } else { Remove-JobWrapper }
        return
    }
    if ($script:JobProcess -and -not $script:JobProcess.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show($form, 'An analysis job is still running. Stop the complete Linux job and close only after it has stopped?', 'Job running', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $_.Cancel = $true; return }
        if (-not (Stop-DownstreamJob 'Window close requested')) { $_.Cancel = $true; return }
    } else { Remove-JobWrapper }
})

if (-not $script:EmbeddedMode -and $script:SuiteReadySignal) {
    $form.Add_Shown({
        try {
            $encoding = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($script:SuiteReadySignal, "ready $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))", $encoding)
        } catch { }
    })
}

if (-not $script:EmbeddedMode -and ($script:SuiteShutdownSignal -or $script:SuiteParentPid -gt 0)) {
    $script:SuiteLifecycleTimer = New-Object System.Windows.Forms.Timer
    $script:SuiteLifecycleTimer.Interval = 250
    $script:SuiteLifecycleTimer.Add_Tick({
        if ($script:SuiteRequestedClose) { return }
        $suiteExitRequested = $false
        if ($script:SuiteShutdownSignal -and (Test-Path -LiteralPath $script:SuiteShutdownSignal -PathType Leaf)) {
            $suiteExitRequested = $true
        }
        if (-not $suiteExitRequested -and $script:SuiteParentPid -gt 0) {
            try { [void][System.Diagnostics.Process]::GetProcessById($script:SuiteParentPid) }
            catch { $suiteExitRequested = $true }
        }
        if ($suiteExitRequested) {
            $script:SuiteRequestedClose = $true
            if ($script:JobProcess -and -not $script:JobProcess.HasExited) {
                [void](Stop-DownstreamJob 'Main suite shutdown requested')
            }
            $form.Close()
        }
    })
    $script:SuiteLifecycleTimer.Start()
}

$script:BuildingDownstreamUi = $false
for ($index=$script:DeferredLayoutControls.Count-1; $index -ge 0; $index--) {
    $script:DeferredLayoutControls[$index].ResumeLayout($true)
}
$script:DeferredLayoutControls.Clear()
$root.ResumeLayout($true)
$form.ResumeLayout($true)
$script:UiStartupWatch.Stop()
Append-Log ("$($script:ModuleDisplayName) UI v30 initialized in $($script:UiStartupWatch.ElapsedMilliseconds) ms. No analysis or database check is run when opening this page.")
Append-Log ("$($script:ModuleDisplayName) is ready. The exact R and Python source used by every run will appear in this console and be saved with the results.")

if ($script:EmbeddedMode) {
    $form.TopLevel = $false
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.MinimumSize = [System.Drawing.Size]::new([int]0, [int]0)
    $form.ClientSize = [System.Drawing.Size]::new([int]1500, [int]900)
    $form.Dock = [System.Windows.Forms.DockStyle]::Fill
    $form.ShowInTaskbar = $false
    [void]$script:EmbeddedHost.Controls.Add($form)
    $form.Show()
    if ($script:AutoLoadLatestRnaSeq -and $script:InitialTab -eq 'de') {
        [System.Windows.Forms.Application]::DoEvents()
        $useLatestRnaSeqButton.PerformClick()
    }
    while (-not $form.IsDisposed -and $form.Visible) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 20
    }
    if (-not $form.IsDisposed) {
        $script:EmbeddedHost.Controls.Remove($form)
        $form.Dispose()
    }
} else {
    if ($script:AutoLoadLatestRnaSeq -and $script:InitialTab -eq 'de') {
        $form.Add_Shown({ $useLatestRnaSeqButton.PerformClick() })
    }
    [void]$form.ShowDialog()
}
