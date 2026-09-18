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
$tuState = [pscustomobject]@{ RunLog = ''; ReviewPath = '' }

$hostView = New-ScienceModuleHost 'Operon - TU Architecture & Manual Curation' 'Combine coverage-inferred transcript boundaries with translation-start and terminator evidence, then review and export curated transcription units.' '< Back to operon methods'
$body = $hostView.Body
$body.AutoScroll = $false
$header = $hostView.Back.Parent
$hostView.Back.Size = New-Object System.Drawing.Size(210, 34)
$backHome = New-ScienceButton '< Back to analysis modules'
$backHome.Size = New-Object System.Drawing.Size(190, 34)
$instructions = New-ScienceButton 'Instructions'
$instructions.Size = New-Object System.Drawing.Size(120, 34)
$header.Controls.AddRange(@($instructions, $backHome))
$backHome.Add_Click({ try { $global:BacterialRNAAnalysisReturnTarget = 'home' } catch { }; $hostView.Back.PerformClick() }.GetNewClosure())
$instructions.Add_Click({
    try {
        $guide = Join-Path $suiteRoot 'Modules\Operon Prediction Suite\Applications\TU Architecture\Instructions.html'
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
[void]$page.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 240)))
[void]$page.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 235)))
[void]$page.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$body.Controls.Add($page)

$top = New-Object System.Windows.Forms.TableLayoutPanel
$top.Dock = [System.Windows.Forms.DockStyle]::Fill
$top.ColumnCount = 2
$top.RowCount = 1
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 57)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 43)))
$page.Controls.Add($top, 0, 0)

$inputSec = New-ScienceSection '1. Inputs' 234
$inputSec.Dock = [System.Windows.Forms.DockStyle]::Fill
$inputSec.Padding = New-Object System.Windows.Forms.Padding(14, 21, 14, 8)
$inputPanel = New-Object System.Windows.Forms.Panel
$inputPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$inputSec.Controls.Add($inputPanel)
$top.Controls.Add($inputSec, 0, 0)
$analysis = New-ScienceInputRow 'RNA Processing result folder' '' 'Completed RNA Processing result folder.' 'folder'
$tx = New-ScienceInputRow 'Predicted transcripts TSV' '' 'predicted_transcripts.tsv from Transcript Discovery.' 'file' 'Transcript tables (*.tsv;*.txt)|*.tsv;*.txt|All files (*.*)|*.*'
$fasta = New-ScienceInputRow 'Reference FASTA override' '' 'Optional matching FASTA.' 'file' 'FASTA (*.fa;*.fna;*.fasta)|*.fa;*.fna;*.fasta|All files (*.*)|*.*'
$gff = New-ScienceInputRow 'Annotation override' '' 'Optional matching GFF/GTF.' 'file' 'Annotation (*.gff;*.gff3;*.gtf)|*.gff;*.gff3;*.gtf|All files (*.*)|*.*'
$inputRows = @($analysis, $tx, $fasta, $gff)
for ($index = 0; $index -lt $inputRows.Count; $index++) {
    $inputRows[$index].Panel.Dock = [System.Windows.Forms.DockStyle]::None
    $inputRows[$index].Panel.Location = New-Object System.Drawing.Point(8, ($index * 36))
    $inputPanel.Controls.Add($inputRows[$index].Panel)
}
$scanInputs = New-ScienceButton 'Scan RNA / Transcript Discovery folder'
$scanInputs.Location = New-Object System.Drawing.Point(8, 150)
$scanInputs.Size = New-Object System.Drawing.Size(285, 31)
$manualInput = New-ScienceButton 'Manual Excel input'
$manualInput.Location = New-Object System.Drawing.Point(303, 150)
$manualInput.Size = New-Object System.Drawing.Size(170, 31)
$inputPanel.Controls.AddRange(@($scanInputs, $manualInput))

$evidenceSec = New-ScienceSection '2. Evidence and output' 234
$evidenceSec.Dock = [System.Windows.Forms.DockStyle]::Fill
$evidenceSec.Padding = New-Object System.Windows.Forms.Padding(14, 21, 14, 8)
$evidencePanel = New-Object System.Windows.Forms.Panel
$evidencePanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$evidenceSec.Controls.Add($evidencePanel)
$top.Controls.Add($evidenceSec, 1, 0)
$prodigal = New-Object System.Windows.Forms.CheckBox
$prodigal.Text = 'Prodigal RBS / translation-start evidence'
$prodigal.Checked = $true
$prodigal.Location = New-Object System.Drawing.Point(10, 0)
$prodigal.Size = New-Object System.Drawing.Size(380, 26)
$transterm = New-Object System.Windows.Forms.CheckBox
$transterm.Text = 'Record TransTermHP terminator evidence availability'
$transterm.Location = New-Object System.Drawing.Point(10, 28)
$transterm.Size = New-Object System.Drawing.Size(420, 26)
$termTable = New-ScienceInputRow 'Verified terminator table' '' 'Optional verified/imported terminator calls used as supporting evidence.' 'file' 'Tables (*.tsv;*.txt;*.csv)|*.tsv;*.txt;*.csv|All files (*.*)|*.*'
$termTable.Panel.Dock = [System.Windows.Forms.DockStyle]::None
$termTable.Panel.Location = New-Object System.Drawing.Point(8, 59)
$out = New-ScienceInputRow 'Results folder' '' 'Writable folder for the TU workbook, review state, browser files, and log.' 'folder'
$out.Panel.Dock = [System.Windows.Forms.DockStyle]::None
$out.Panel.Location = New-Object System.Drawing.Point(8, 95)
$evidencePanel.Controls.AddRange(@($prodigal, $transterm, $termTable.Panel, $out.Panel))
$evidenceNote = New-Object System.Windows.Forms.Label
$evidenceNote.Text = 'Coverage-derived boundaries remain labelled as inferred unless supported by independent experimental evidence.'
$evidenceNote.Location = New-Object System.Drawing.Point(16, 140)
$evidenceNote.Size = New-Object System.Drawing.Size(460, 40)
$evidenceNote.ForeColor = $script:ScienceMuted
$evidencePanel.Controls.Add($evidenceNote)

$reviewSec = New-ScienceSection '3. Manual TU review' 229
$reviewSec.Dock = [System.Windows.Forms.DockStyle]::Fill
$reviewSec.Padding = New-Object System.Windows.Forms.Padding(14, 21, 14, 8)
$reviewPanel = New-Object System.Windows.Forms.Panel
$reviewPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$reviewSec.Controls.Add($reviewPanel)
$page.Controls.Add($reviewSec, 0, 1)
$reviewHint = New-Object System.Windows.Forms.Label
$reviewHint.Text = 'Edit manual_assignment, locked, and notes. Save the review state before exporting curated transcription units.'
$reviewHint.Location = New-Object System.Drawing.Point(8, 0)
$reviewHint.Size = New-Object System.Drawing.Size(750, 26)
$reviewHint.ForeColor = $script:ScienceMuted
$save = New-ScienceButton 'Save manual edits'
$save.Location = New-Object System.Drawing.Point(770, 0)
$save.Size = New-Object System.Drawing.Size(155, 31)
$save.Enabled = $false
$apply = New-ScienceButton 'Export curated TU'
$apply.Location = New-Object System.Drawing.Point(933, 0)
$apply.Size = New-Object System.Drawing.Size(155, 31)
$apply.Enabled = $false
$reviewGrid = New-Object System.Windows.Forms.DataGridView
$reviewGrid.AllowUserToAddRows = $false
$reviewGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::DisplayedCells
$reviewGrid.BackgroundColor = $script:ScienceSurface
$reviewGrid.Location = New-Object System.Drawing.Point(8, 38)
$reviewGrid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$reviewPanel.Controls.AddRange(@($reviewHint, $save, $apply, $reviewGrid))

$workspace = New-ScienceConsoleWorkspace '4. Status, actions, and live console' 250 'Ready. Environment checks, architecture progress, and export messages appear here.'
$workspace.Section.Dock = [System.Windows.Forms.DockStyle]::Fill
$page.Controls.Add($workspace.Section, 0, 2)
$console = $workspace.Console
$status = $workspace.Status
$run = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Run TU architecture' -Primary)
$checkEnv = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Check environment / packages')
$installEnv = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Install or repair core')
$openLog = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Open run log')
$openLog.Enabled = $false
$openResults = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Open results folder')

$layoutRows = {
    foreach ($row in $inputRows) {
        $row.Panel.Width = [Math]::Max(480, $inputPanel.ClientSize.Width - 16)
        if ($row.Browse) { $row.Browse.Left = $row.Panel.ClientSize.Width - $row.Browse.Width - 8; $row.Box.Width = [Math]::Max(135, $row.Browse.Left - $row.Box.Left - 8) }
    }
    foreach ($row in @($termTable, $out)) {
        $row.Panel.Width = [Math]::Max(390, $evidencePanel.ClientSize.Width - 16)
        $row.Label.Width = 178
        $row.Box.Left = 182
        if ($row.Browse) { $row.Browse.Left = $row.Panel.ClientSize.Width - $row.Browse.Width - 8; $row.Box.Width = [Math]::Max(100, $row.Browse.Left - $row.Box.Left - 8) }
    }
    $evidenceNote.Width = [Math]::Max(330, $evidencePanel.ClientSize.Width - 32)
    $apply.Left = [Math]::Max(600, $reviewPanel.ClientSize.Width - $apply.Width - 8)
    $save.Left = $apply.Left - $save.Width - 8
    $reviewHint.Width = [Math]::Max(260, $save.Left - $reviewHint.Left - 12)
    $reviewGrid.Size = New-Object System.Drawing.Size(([Math]::Max(600, $reviewPanel.ClientSize.Width - 16)), ([Math]::Max(110, $reviewPanel.ClientSize.Height - 46)))
}.GetNewClosure()
$inputPanel.Add_SizeChanged($layoutRows)
$evidencePanel.Add_SizeChanged($layoutRows)
$reviewPanel.Add_SizeChanged($layoutRows)
& $layoutRows

function Load-TuReview([string]$Path) {
    $reviewGrid.DataSource = $null
    $table = New-Object System.Data.DataTable
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    if ($lines.Count -lt 1) { return }
    $headers = $lines[0].Split("`t")
    foreach ($headerName in $headers) { [void]$table.Columns.Add($headerName) }
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if (-not $lines[$index]) { continue }
        $values = $lines[$index].Split("`t")
        $row = $table.NewRow()
        for ($column = 0; $column -lt $headers.Count; $column++) { if ($column -lt $values.Count) { $row[$column] = $values[$column] } }
        $table.Rows.Add($row)
    }
    $reviewGrid.DataSource = $table
    $tuState.ReviewPath = $Path
    $save.Enabled = $true
    $apply.Enabled = $true
}
$loadTuReview = ${function:Load-TuReview}

$manualInput.Add_Click({
    try {
        $result = & $invokeManualWorkbook -SuiteRoot $suiteRoot -Profile 'tu' -Console $console
        if ($null -eq $result) { return }
        foreach ($field in @($analysis, $fasta, $gff, $tx, $termTable)) { $field.Box.Text = '' }
        $pathsFile = & $getManualFile $result 'input_paths.tsv'
        if ($pathsFile) {
            foreach ($row in @(Import-Csv -LiteralPath $pathsFile -Delimiter "`t")) {
                $name = [string]$row.input_name
                $value = [string]$row.file_or_folder_path
                if (-not $value.Trim()) { continue }
                if ($name -match '(?i)RNA Processing') { $analysis.Box.Text = $value }
                elseif ($name -match '(?i)Reference FASTA') { $fasta.Box.Text = $value }
                elseif ($name -match '(?i)Annotation') { $gff.Box.Text = $value }
                elseif ($name -match '(?i)Predicted transcripts') { $tx.Box.Text = $value }
            }
        }
        $pastedTranscripts = & $getManualFile $result 'predicted_transcripts.tsv'
        $pastedTerminators = & $getManualFile $result 'terminator_evidence.tsv'
        if ($pastedTranscripts) { $tx.Box.Text = $pastedTranscripts }
        if ($pastedTerminators) { $termTable.Box.Text = $pastedTerminators; $transterm.Checked = $true }
        if (-not $out.Box.Text.Trim()) { $out.Box.Text = Join-Path ([System.IO.Path]::GetDirectoryName($result.Workbook)) 'TU Architecture Results' }
        $status.Text = 'Saved manual workbook loaded. Review assigned inputs and evidence.'
        $status.ForeColor = $script:ScienceGreen
        & $showScienceInfo 'The saved workbook was validated and its TU Architecture inputs were assigned.'
    } catch {
        $status.Text = 'Manual workbook could not be loaded. See the console.'
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        $console.AppendText($_.Exception.Message + "`r`n")
        & $showScienceError $_.Exception.Message
    }
}.GetNewClosure())

$scanInputs.Add_Click({
    try {
        $root = & $selectScienceFolder 'Select the RNA Processing or Transcript Discovery results folder to scan recursively for TU Architecture inputs'
        if (-not $root) { return }
        $files = @(& $getScienceScanInventory -Root $root)
        $processing = & $findScienceScanFolder -Root $root -Patterns @('(?i)^RNA Processing Results$','(?i)RNA Processing','(?i)analysis.ready')
        if (-not $processing) { $processing = $root }
        $transcripts = & $findScienceScanFile -Files $files -Patterns @('(?i)^predicted[_ -]?transcripts\.tsv$','(?i)transcript.*discover.*\.tsv$','(?i)transcript.*\.tsv$') -Extensions @('.tsv','.txt') -ExcludePatterns @('(?i)manual|curated|summary|log')
        $reference = & $findScienceScanFile -Files $files -Patterns @('(?i)(reference|genome|assembly|contig).*(\.fna|\.fa|\.fasta)$','(?i)\.(fna|fasta|fa)$') -Extensions @('.fa','.fna','.fasta')
        $annotation = & $findScienceScanFile -Files $files -Patterns @('(?i)(annotation|genomic|genes?).*\.(gff3?|gtf)$','(?i)\.(gff3?|gtf)$') -Extensions @('.gff','.gff3','.gtf')
        $terminators = & $findScienceScanFile -Files $files -Patterns @('(?i)(verified[_ -]?)?terminator.*\.(tsv|txt|csv)$','(?i)transterm.*\.(tsv|txt|csv)$') -Extensions @('.tsv','.txt','.csv') -ExcludePatterns @('(?i)log')
        $analysis.Box.Text = $processing
        if ($transcripts) { $tx.Box.Text = $transcripts }
        if ($reference) { $fasta.Box.Text = $reference }
        if ($annotation) { $gff.Box.Text = $annotation }
        if ($terminators) { $termTable.Box.Text = $terminators; $transterm.Checked = $true }
        if (-not $out.Box.Text.Trim()) { $out.Box.Text = Join-Path $root 'TU Architecture Results' }
        $summary = & $formatScienceScanSummary -Assignments ([ordered]@{
            'Scanned RNA / Transcript Discovery folder' = $root
            'RNA Processing result folder' = $processing
            'Predicted transcripts TSV' = $transcripts
            'Reference FASTA' = $reference
            'Annotation' = $annotation
            'Terminator evidence' = $terminators
            'Results folder' = $out.Box.Text
        })
        $status.Text = 'RNA / Transcript Discovery folder scan completed. Review assigned inputs.'
        & $showScienceInfo ("RNA / Transcript Discovery folder scan completed.`r`n`r`n$summary")
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure())

$checkEnv.Add_Click({
    try {
        $console.Clear()
        $status.Text = 'Checking environment and TU/scientific packages...'
        $status.ForeColor = $script:ScienceMuted
        $null = & $invokeScienceBackend -SuiteRoot $suiteRoot -Arguments @('check') -Console $console
        $status.Text = 'Environment check completed. Optional TU tools are listed in the console.'
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
        if ($tuState.RunLog -and (Test-Path -LiteralPath $tuState.RunLog -PathType Leaf)) { [void](Start-Process -FilePath $tuState.RunLog) }
        else { & $showScienceInfo 'No TU Architecture run log has been created yet.' }
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure())
$openResults.Add_Click({
    if ($out.Box.Text.Trim() -and (Test-Path -LiteralPath $out.Box.Text.Trim() -PathType Container)) { [void](Start-Process explorer.exe $out.Box.Text.Trim()) }
    else { & $showScienceInfo 'Choose or create a TU Architecture results folder first.' }
}.GetNewClosure())

$run.Add_Click({
    try {
        if (-not $out.Box.Text.Trim()) { throw 'Choose a results folder.' }
        $arguments = @('tu','--output-dir',$out.Box.Text.Trim())
        if ($analysis.Box.Text.Trim()) { $arguments += @('--analysis-ready',$analysis.Box.Text.Trim()) }
        if ($tx.Box.Text.Trim()) { $arguments += @('--transcripts',$tx.Box.Text.Trim()) }
        if ($fasta.Box.Text.Trim()) { $arguments += @('--fasta',$fasta.Box.Text.Trim()) }
        if ($gff.Box.Text.Trim()) { $arguments += @('--gff',$gff.Box.Text.Trim()) }
        if ($prodigal.Checked) { $arguments += '--prodigal' }
        if ($transterm.Checked) { $arguments += '--transterm' }
        if ($termTable.Box.Text.Trim()) { $arguments += @('--terminator-table',$termTable.Box.Text.Trim()) }
        $console.Clear()
        $status.Text = 'Running TU Architecture...'
        $status.ForeColor = $script:ScienceMuted
        $null = & $invokeScienceBackend -SuiteRoot $suiteRoot -Arguments $arguments -Console $console
        $logDir = Join-Path $out.Box.Text.Trim() 'Intermediate files'
        [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
        $tuState.RunLog = Join-Path $logDir 'TU architecture run.log'
        Set-Content -LiteralPath $tuState.RunLog -Value $console.Text -Encoding UTF8
        $openLog.Enabled = $true
        $review = Join-Path $out.Box.Text.Trim() 'manual_tu_review.tsv'
        if (Test-Path -LiteralPath $review -PathType Leaf) { & $loadTuReview $review }
        $status.Text = 'TU Architecture completed. Review inferred boundaries and evidence.'
        $status.ForeColor = $script:ScienceGreen
        & $showScienceInfo 'TU Architecture completed. Ordinary RNA-seq boundaries remain labelled as coverage-inferred, not experimentally validated TSS/TTS.'
    } catch {
        $console.AppendText($_.Exception.Message + "`r`n")
        $status.Text = 'TU Architecture stopped. See the console.'
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        try {
            if ($out.Box.Text.Trim()) {
                $logDir = Join-Path $out.Box.Text.Trim() 'Intermediate files'
                [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
                $tuState.RunLog = Join-Path $logDir 'TU architecture run.log'
                Set-Content -LiteralPath $tuState.RunLog -Value $console.Text -Encoding UTF8
                $openLog.Enabled = $true
            }
        } catch { }
        & $showScienceError $_.Exception.Message
    }
}.GetNewClosure())

$saveHandler = {
    try {
        if (-not $tuState.ReviewPath) { return }
        $table = [System.Data.DataTable]$reviewGrid.DataSource
        $headers = @($table.Columns | ForEach-Object { $_.ColumnName })
        $lines = New-Object System.Collections.Generic.List[string]
        [void]$lines.Add(($headers -join "`t"))
        foreach ($row in $table.Rows) {
            $values = @()
            foreach ($headerName in $headers) { $values += ([string]$row[$headerName]).Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ') }
            [void]$lines.Add(($values -join "`t"))
        }
        [System.IO.File]::WriteAllLines($tuState.ReviewPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
        $status.Text = 'Manual TU review state saved.'
        & $showScienceInfo 'Manual TU review state saved.'
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure()
$save.Add_Click($saveHandler)
$apply.Add_Click({
    try {
        & $saveHandler
        $curated = Join-Path $out.Box.Text.Trim() 'Curated TU'
        if (-not (Test-Path -LiteralPath $curated -PathType Container)) { [void](New-Item -ItemType Directory -Path $curated -Force) }
        $null = & $invokeScienceBackend -SuiteRoot $suiteRoot -Arguments @('apply-tu','--review-tsv',$tuState.ReviewPath,'--output-dir',$curated) -Console $console
        $status.Text = 'Curated transcription units exported as GFF3 and BED.'
        & $showScienceInfo 'Curated transcription units exported as GFF3 and BED.'
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure())

Show-ScienceModuleHost $hostView
