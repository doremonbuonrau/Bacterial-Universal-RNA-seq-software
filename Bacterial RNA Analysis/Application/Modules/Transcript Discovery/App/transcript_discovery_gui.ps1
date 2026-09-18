Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$common = ''
try {
    $cachedCommon = Get-Variable -Name BacterialRNAAnalysisScienceCommonPath -Scope Global -ValueOnly -ErrorAction Stop
    if ($cachedCommon -and (Test-Path -LiteralPath $cachedCommon -PathType Leaf)) { $common = [string]$cachedCommon }
} catch { }
$current = if (-not $common) { Get-Item -LiteralPath $PSScriptRoot } else { $null }
for ($i = 0; $i -lt 10 -and $current; $i++) {
    $candidate = Join-Path $current.FullName 'Modules\Scientific Expansion\Backend\scientific_gui_common.ps1'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $common = $candidate; break }
    $current = $current.Parent
}
if (-not $common) { throw 'Cannot locate Modules\Scientific Expansion\Backend\scientific_gui_common.ps1.' }
. $common

$invokeScienceBackend = ${function:Invoke-ScienceBackend}
$invokeManualWorkbook = ${function:Invoke-ScienceManualWorkbook}
$getManualFile = ${function:Get-ScienceManualFile}
$showScienceError = ${function:Show-ScienceError}
$showScienceInfo = ${function:Show-ScienceInfo}
$selectScienceFolder = ${function:Select-ScienceFolder}
$getScienceScanInventory = ${function:Get-ScienceScanInventory}
$findScienceScanFile = ${function:Find-ScienceScanFile}
$findScienceScanFolder = ${function:Find-ScienceScanFolder}
$formatScienceScanSummary = ${function:Format-ScienceScanSummary}
$script:SuiteRoot = try { [string](Get-Variable -Name BacterialRNAAnalysisSuiteRoot -Scope Global -ValueOnly -ErrorAction Stop) } catch { '' }
if (-not $script:SuiteRoot) { $script:SuiteRoot = Find-ScienceSuiteRoot $PSScriptRoot }
$suiteRoot = $script:SuiteRoot
$transcriptState = [pscustomobject]@{ RunLog = '' }

$hostView = New-ScienceModuleHost 'Transcript Discovery' 'Find novel transcripts, antisense RNA, and sRNA candidates from existing strand-specific RNA-seq evidence.' '< Back to analysis modules'
$body = $hostView.Body
$body.AutoScroll = $false
$hostView.Back.Add_Click({ try { $global:BacterialRNAAnalysisReturnTarget = 'home' } catch { } }.GetNewClosure())
$header = $hostView.Back.Parent
$hostView.Back.Size = New-Object System.Drawing.Size(205, 34)
$instructions = New-ScienceButton 'Instructions'
$instructions.Size = New-Object System.Drawing.Size(120, 34)
$header.Controls.Add($instructions)
$instructions.Add_Click({
    try {
        $guide = Join-Path $suiteRoot 'Modules\Transcript Discovery\Documentation\Transcript Discovery Instructions.html'
        if (-not (Test-Path -LiteralPath $guide -PathType Leaf)) { throw "Instruction file not found: $guide" }
        [void](Start-Process -FilePath $guide)
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure())

$page = New-Object System.Windows.Forms.TableLayoutPanel
$page.Dock = [System.Windows.Forms.DockStyle]::Fill
$page.ColumnCount = 1
$page.RowCount = 3
$page.Padding = New-Object System.Windows.Forms.Padding(8, 5, 8, 8)
$page.BackColor = $script:ScienceBackground
[void]$page.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$page.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 270)))
[void]$page.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 194)))
[void]$page.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$body.Controls.Add($page)

$top = New-Object System.Windows.Forms.TableLayoutPanel
$top.Dock = [System.Windows.Forms.DockStyle]::Fill
$top.ColumnCount = 2
$top.RowCount = 1
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$page.Controls.Add($top, 0, 0)

$inputSec = New-ScienceSection '1. Input data' 264
$inputSec.Dock = [System.Windows.Forms.DockStyle]::Fill
$inputSec.Padding = New-Object System.Windows.Forms.Padding(14, 21, 14, 8)
$inputPanel = New-Object System.Windows.Forms.Panel
$inputPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$inputSec.Controls.Add($inputPanel)
$top.Controls.Add($inputSec, 0, 0)
$analysis = New-ScienceInputRow 'RNA Processing result folder' '' 'Completed RNA Processing Results folder.' 'folder'
$fasta = New-ScienceInputRow 'Reference FASTA override' '' 'Optional matching FASTA.' 'file' 'FASTA (*.fa;*.fna;*.fasta)|*.fa;*.fna;*.fasta|All files (*.*)|*.*'
$gff = New-ScienceInputRow 'Gene annotation override' '' 'Optional matching GFF3/GFF/GTF.' 'file' 'Annotation (*.gff;*.gff3;*.gtf)|*.gff;*.gff3;*.gtf|All files (*.*)|*.*'
$coverage = New-ScienceInputRow 'Coverage folder override' '' 'Optional folder containing strand-specific bedGraph tracks.' 'folder'
$rockhopper = New-ScienceInputRow 'Rockhopper evidence' '' 'Optional precomputed Rockhopper transcript table.' 'file' 'Tabular files (*.txt;*.tsv;*.csv)|*.txt;*.tsv;*.csv|All files (*.*)|*.*'
$inputRows = @($analysis, $fasta, $gff, $coverage, $rockhopper)
for ($index = 0; $index -lt $inputRows.Count; $index++) {
    $inputRows[$index].Panel.Dock = [System.Windows.Forms.DockStyle]::None
    $inputRows[$index].Panel.Location = New-Object System.Drawing.Point(8, ($index * 36))
    $inputPanel.Controls.Add($inputRows[$index].Panel)
}
$scanInputs = New-ScienceButton 'Scan RNA Processing results folder'
$scanInputs.Location = New-Object System.Drawing.Point(8, 184)
$scanInputs.Size = New-Object System.Drawing.Size(265, 31)
$manualInput = New-ScienceButton 'Manual Excel input'
$manualInput.Location = New-Object System.Drawing.Point(283, 184)
$manualInput.Size = New-Object System.Drawing.Size(170, 31)
$inputPanel.Controls.AddRange(@($scanInputs, $manualInput))

$paramSec = New-ScienceSection '2. Transcript discovery parameters' 264
$paramSec.Dock = [System.Windows.Forms.DockStyle]::Fill
$paramSec.Padding = New-Object System.Windows.Forms.Padding(14, 21, 14, 8)
$paramPanel = New-Object System.Windows.Forms.Panel
$paramPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$paramSec.Controls.Add($paramPanel)
$top.Controls.Add($paramSec, 1, 0)
$minLen = New-ScienceInputRow 'Minimum transcript length' '50' 'Candidate length in nucleotides.' 'text'
$minSamples = New-ScienceInputRow 'Minimum sample support' '2' 'Number of libraries with evidence.' 'text'
$minDepth = New-ScienceInputRow 'Minimum coverage depth' '1' 'Minimum strand-specific bedGraph depth.' 'text'
$maxGap = New-ScienceInputRow 'Maximum internal gap' '25' 'Maximum low/zero-coverage gap bridged inside one segment.' 'text'
$antiOverlap = New-ScienceInputRow 'Minimum antisense overlap' '30' 'Minimum opposite-strand overlap in nucleotides.' 'text'
$parameterRows = @($minLen, $minSamples, $minDepth, $maxGap, $antiOverlap)
for ($index = 0; $index -lt $parameterRows.Count; $index++) {
    $parameterRows[$index].Panel.Dock = [System.Windows.Forms.DockStyle]::None
    $parameterRows[$index].Panel.Location = New-Object System.Drawing.Point(8, ($index * 36))
    $paramPanel.Controls.Add($parameterRows[$index].Panel)
}

$evidenceSec = New-ScienceSection '3. Classification, RNA evidence, and output' 188
$evidenceSec.Dock = [System.Windows.Forms.DockStyle]::Fill
$evidenceSec.Padding = New-Object System.Windows.Forms.Padding(14, 21, 14, 8)
$evidencePanel = New-Object System.Windows.Forms.Panel
$evidencePanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$evidenceSec.Controls.Add($evidencePanel)
$page.Controls.Add($evidenceSec, 0, 1)
$antisense = New-Object System.Windows.Forms.CheckBox
$antisense.Text = 'Classify antisense transcripts'
$antisense.Checked = $true
$antisense.Location = New-Object System.Drawing.Point(10, 0)
$antisense.Size = New-Object System.Drawing.Size(260, 26)
$rnafold = New-Object System.Windows.Forms.CheckBox
$rnafold.Text = 'Run RNAfold for candidate sRNAs when installed'
$rnafold.Checked = $true
$rnafold.Location = New-Object System.Drawing.Point(280, 0)
$rnafold.Size = New-Object System.Drawing.Size(350, 26)
$rfam = New-Object System.Windows.Forms.CheckBox
$rfam.Text = 'Run Infernal/Rfam known ncRNA search'
$rfam.Location = New-Object System.Drawing.Point(640, 0)
$rfam.Size = New-Object System.Drawing.Size(330, 26)
$rfamCm = New-ScienceInputRow 'Rfam.cm' '' 'Imported once into the shared Database Library and reused.' 'file' 'Rfam CM (*.cm)|*.cm|All files (*.*)|*.*'
$rfamClan = New-ScienceInputRow 'Rfam.clanin' '' 'Imported once into the shared Database Library and reused.' 'file' 'Rfam clan (*.clanin)|*.clanin|All files (*.*)|*.*'
$output = New-ScienceInputRow 'Results folder' '' 'Writable folder for workbooks, GFF3/BED evidence, and the run log.' 'folder'
$evidenceRows = @($rfamCm, $rfamClan, $output)
for ($index = 0; $index -lt $evidenceRows.Count; $index++) {
    $evidenceRows[$index].Panel.Dock = [System.Windows.Forms.DockStyle]::None
    $evidenceRows[$index].Panel.Location = New-Object System.Drawing.Point(10, (30 + ($index * 36)))
    $evidencePanel.Controls.Add($evidenceRows[$index].Panel)
}
$evidencePanel.Controls.AddRange(@($antisense, $rnafold, $rfam))

$workspace = New-ScienceConsoleWorkspace '4. Status, actions, and live console' 270 'Ready. Environment checks, optional-tool status, and transcript-discovery progress appear here.'
$workspace.Section.Dock = [System.Windows.Forms.DockStyle]::Fill
$page.Controls.Add($workspace.Section, 0, 2)
$console = $workspace.Console
$status = $workspace.Status
$run = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Run transcript discovery' -Primary)
$checkEnv = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Check environment / packages')
$installEnv = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Install or repair core')
$openLog = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Open run log')
$openLog.Enabled = $false
$openResults = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Open results folder')

$layoutRows = {
    foreach ($row in $inputRows) {
        $row.Panel.Width = [Math]::Max(430, $inputPanel.ClientSize.Width - 16)
        if ($row.Browse) { $row.Browse.Left = $row.Panel.ClientSize.Width - $row.Browse.Width - 8; $row.Box.Width = [Math]::Max(115, $row.Browse.Left - $row.Box.Left - 8) }
    }
    foreach ($row in $parameterRows) {
        $row.Panel.Width = [Math]::Max(430, $paramPanel.ClientSize.Width - 16)
        $row.Box.Width = [Math]::Max(115, $row.Panel.ClientSize.Width - $row.Box.Left - 8)
    }
    $buttonGap=8
    $buttonArea=[Math]::Max(420,$inputPanel.ClientSize.Width-16)
    $manualWidth=[Math]::Max(150,[Math]::Min(180,[int]($buttonArea*.34)))
    $scanInputs.SetBounds(8,184,[Math]::Max(220,$buttonArea-$manualWidth-$buttonGap),31)
    $manualInput.SetBounds($scanInputs.Right+$buttonGap,184,$manualWidth,31)
    foreach ($row in $evidenceRows) {
        $row.Panel.Width = [Math]::Max(760, $evidencePanel.ClientSize.Width - 20)
        if ($row.Browse) { $row.Browse.Left = $row.Panel.ClientSize.Width - $row.Browse.Width - 12; $row.Box.Width = [Math]::Max(240, $row.Browse.Left - $row.Box.Left - 10) }
    }
    $checkGap = 12
    $checkWidth = [Math]::Max(220, [Math]::Floor(($evidencePanel.ClientSize.Width - 44 - ($checkGap * 2)) / 3))
    $antisense.Width = $checkWidth
    $rnafold.Left = $antisense.Left + $checkWidth + $checkGap
    $rnafold.Width = $checkWidth
    $rfam.Left = $rnafold.Left + $checkWidth + $checkGap
    $rfam.Width = $checkWidth
}.GetNewClosure()
$inputPanel.Add_SizeChanged($layoutRows)
$paramPanel.Add_SizeChanged($layoutRows)
$evidencePanel.Add_SizeChanged($layoutRows)
& $layoutRows

$manualInput.Add_Click({
    try {
        $result = & $invokeManualWorkbook -SuiteRoot $suiteRoot -Profile 'transcript' -Console $console
        if ($null -eq $result) { return }
        foreach ($field in @($analysis, $fasta, $gff, $coverage, $rockhopper)) { $field.Box.Text = '' }
        $pathsFile = & $getManualFile $result 'input_paths.tsv'
        if ($pathsFile) {
            $rows = @(Import-Csv -LiteralPath $pathsFile -Delimiter "`t")
            foreach ($row in $rows) {
                $name = [string]$row.input_name
                $value = [string]$row.file_or_folder_path
                if (-not $value.Trim()) { continue }
                if ($name -match '(?i)RNA Processing') { $analysis.Box.Text = $value }
                elseif ($name -match '(?i)Reference FASTA') { $fasta.Box.Text = $value }
                elseif ($name -match '(?i)annotation') { $gff.Box.Text = $value }
                elseif ($name -match '(?i)Coverage') { $coverage.Box.Text = $value }
            }
        }
        $rockhopperPath = & $getManualFile $result 'rockhopper_transcripts.tsv'
        $rockhopper.Box.Text = $rockhopperPath
        if (-not $output.Box.Text.Trim()) { $output.Box.Text = Join-Path ([System.IO.Path]::GetDirectoryName($result.Workbook)) 'Transcript Discovery Results' }
        $status.Text = 'Saved manual workbook loaded. Review assigned paths and parameters.'
        $status.ForeColor = $script:ScienceGreen
        & $showScienceInfo 'The saved workbook was validated and its Transcript Discovery inputs were assigned.'
    } catch {
        $status.Text = 'Manual workbook could not be loaded. See the console.'
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        $console.AppendText($_.Exception.Message + "`r`n")
        & $showScienceError $_.Exception.Message
    }
}.GetNewClosure())

$scanInputs.Add_Click({
    try {
        $root = & $selectScienceFolder 'Select the completed RNA Processing Results folder to scan recursively for Transcript Discovery inputs'
        if (-not $root) { return }
        $files = @(& $getScienceScanInventory -Root $root)
        $analysisRoot = & $findScienceScanFolder -Root $root -Patterns @('(?i)^RNA Processing Results$','(?i)RNA[_ -]?Processing','(?i)analysis[_ -]?ready')
        if (-not $analysisRoot) { $analysisRoot = $root }
        $fastaPath = & $findScienceScanFile -Files $files -Patterns @('(?i)reference.*\.(fa|fna|fasta)$','(?i)genome.*\.(fa|fna|fasta)$','(?i)\.(fna|fasta|fa)$') -Extensions @('.fa','.fna','.fasta') -ExcludePatterns @('(?i)protein|amino|transcript|cds')
        $gffPath = & $findScienceScanFile -Files $files -Patterns @('(?i)annotation.*\.(gff3?|gtf)$','(?i)genomic.*\.(gff3?|gtf)$','(?i)\.(gff3?|gtf)$') -Extensions @('.gff','.gff3','.gtf') -ExcludePatterns @('(?i)curated|predicted[_ -]?transcript')
        $coverageFile = & $findScienceScanFile -Files $files -Patterns @('(?i)(plus|minus)[_ -]?transcript.*\.bedgraph$','(?i)strand.*coverage.*\.bedgraph$','(?i)\.bedgraph$') -Extensions @('.bedgraph') -ExcludePatterns @('(?i)igv.*gene|log2')
        $rockhopperPath = & $findScienceScanFile -Files $files -Patterns @('(?i)rockhopper.*transcript','(?i)transcripts?[_ -]?predicted.*rockhopper') -Extensions @('.txt','.tsv','.csv')
        $rfamCmPath = & $findScienceScanFile -Files $files -Patterns @('(?i)^Rfam\.cm$','(?i)rfam.*\.cm$') -Extensions @('.cm')
        $rfamClanPath = & $findScienceScanFile -Files $files -Patterns @('(?i)^Rfam\.clanin$','(?i)rfam.*\.clanin$') -Extensions @('.clanin')
        $coverageFolder = if ($coverageFile) { Split-Path -Parent $coverageFile } else { '' }
        $analysis.Box.Text = $analysisRoot
        if ($fastaPath) { $fasta.Box.Text = $fastaPath }
        if ($gffPath) { $gff.Box.Text = $gffPath }
        if ($coverageFolder) { $coverage.Box.Text = $coverageFolder }
        if ($rockhopperPath) { $rockhopper.Box.Text = $rockhopperPath }
        if ($rfamCmPath) { $rfamCm.Box.Text = $rfamCmPath }
        if ($rfamClanPath) { $rfamClan.Box.Text = $rfamClanPath }
        if (-not $output.Box.Text.Trim()) { $output.Box.Text = Join-Path $root 'Transcript Discovery Results' }
        $summary = & $formatScienceScanSummary -Assignments ([ordered]@{
            'Scanned RNA Processing folder' = $root
            'RNA Processing result folder' = $analysisRoot
            'Reference FASTA' = $fastaPath
            'Annotation' = $gffPath
            'Coverage folder' = $coverageFolder
            'Rockhopper evidence' = $rockhopperPath
            'Rfam.cm' = $rfamCmPath
            'Rfam.clanin' = $rfamClanPath
            'Results folder' = $output.Box.Text
        })
        $status.Text = 'RNA Processing results-folder scan completed. Review assigned evidence.'
        & $showScienceInfo ("RNA Processing results-folder scan completed.`r`n`r`n$summary")
    } catch { & $showScienceError ("Automatic input assignment failed.`r`n`r`n" + $_.Exception.Message) }
}.GetNewClosure())

$checkEnv.Add_Click({
    try {
        $console.Clear()
        $status.Text = 'Checking environment and optional RNA tools...'
        $status.ForeColor = $script:ScienceMuted
        $null = & $invokeScienceBackend -SuiteRoot $suiteRoot -Arguments @('check') -Console $console
        $status.Text = 'Environment check completed. Optional RNA tools are listed in the console.'
        $status.ForeColor = $script:ScienceGreen
    } catch {
        $status.Text = 'Environment/package check failed. See the console.'
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        $console.AppendText($_.Exception.Message + "`r`n")
    }
}.GetNewClosure())
$installEnv.Add_Click({
    try {
        $installer = Join-Path $suiteRoot 'App\environment\setup_windows_wsl.ps1'
        if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Core installer not found: $installer" }
        [void](Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $installer + '" -AnalysisType both'))
        $status.Text = 'Core/scientific installer opened in a separate console.'
        $console.AppendText("Run Check environment / packages after the installer finishes.`r`n")
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure())
$openLog.Add_Click({
    try {
        if ($transcriptState.RunLog -and (Test-Path -LiteralPath $transcriptState.RunLog -PathType Leaf)) { [void](Start-Process -FilePath $transcriptState.RunLog) }
        else { & $showScienceInfo 'No Transcript Discovery run log has been created yet.' }
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure())
$openResults.Add_Click({
    if ($output.Box.Text.Trim() -and (Test-Path -LiteralPath $output.Box.Text.Trim() -PathType Container)) { [void](Start-Process explorer.exe $output.Box.Text.Trim()) }
    else { & $showScienceInfo 'Choose or create a Transcript Discovery results folder first.' }
}.GetNewClosure())

$run.Add_Click({
    try {
        if ([string]::IsNullOrWhiteSpace($output.Box.Text)) { throw 'Choose a results folder.' }
        $arguments = New-Object System.Collections.Generic.List[string]
        [void]$arguments.Add('discover')
        if ($analysis.Box.Text) { [void]$arguments.Add('--analysis-ready'); [void]$arguments.Add($analysis.Box.Text) }
        if ($fasta.Box.Text) { [void]$arguments.Add('--fasta'); [void]$arguments.Add($fasta.Box.Text) }
        if ($gff.Box.Text) { [void]$arguments.Add('--gff'); [void]$arguments.Add($gff.Box.Text) }
        if ($coverage.Box.Text) { [void]$arguments.Add('--coverage-root'); [void]$arguments.Add($coverage.Box.Text) }
        if ($rockhopper.Box.Text) { [void]$arguments.Add('--rockhopper-transcripts'); [void]$arguments.Add($rockhopper.Box.Text) }
        foreach ($pair in @(@('--output-dir',$output.Box.Text),@('--min-length',$minLen.Box.Text),@('--min-samples',$minSamples.Box.Text),@('--min-depth',$minDepth.Box.Text),@('--max-gap',$maxGap.Box.Text),@('--min-antisense-overlap',$antiOverlap.Box.Text))) {
            [void]$arguments.Add($pair[0]); [void]$arguments.Add($pair[1])
        }
        if ($rnafold.Checked) { [void]$arguments.Add('--rnafold') }
        if ($rfam.Checked) {
            [void]$arguments.Add('--rfam')
            if ($rfamCm.Box.Text) { [void]$arguments.Add('--rfam-cm'); [void]$arguments.Add($rfamCm.Box.Text) }
            if ($rfamClan.Box.Text) { [void]$arguments.Add('--rfam-clanin'); [void]$arguments.Add($rfamClan.Box.Text) }
        }
        $console.Clear()
        $status.Text = 'Running Transcript Discovery...'
        $status.ForeColor = $script:ScienceMuted
        $null = & $invokeScienceBackend -SuiteRoot $suiteRoot -Arguments $arguments.ToArray() -Console $console
        $logDir = Join-Path $output.Box.Text 'Intermediate files'
        [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
        $transcriptState.RunLog = Join-Path $logDir 'Transcript discovery run.log'
        Set-Content -LiteralPath $transcriptState.RunLog -Value $console.Text -Encoding UTF8
        $openLog.Enabled = $true
        $status.Text = 'Transcript Discovery completed. Review workbook and genomic evidence.'
        $status.ForeColor = $script:ScienceGreen
        & $showScienceInfo 'Transcript Discovery completed. Review the Excel workbook together with GFF3/BED evidence before biological interpretation.'
    } catch {
        $console.AppendText($_.Exception.Message + "`r`n")
        $status.Text = 'Transcript Discovery stopped. See the console.'
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        try {
            if ($output.Box.Text) {
                $logDir = Join-Path $output.Box.Text 'Intermediate files'
                [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
                $transcriptState.RunLog = Join-Path $logDir 'Transcript discovery run.log'
                Set-Content -LiteralPath $transcriptState.RunLog -Value $console.Text -Encoding UTF8
                $openLog.Enabled = $true
            }
        } catch { }
        & $showScienceError $_.Exception.Message
    }
}.GetNewClosure())

Show-ScienceModuleHost $hostView
