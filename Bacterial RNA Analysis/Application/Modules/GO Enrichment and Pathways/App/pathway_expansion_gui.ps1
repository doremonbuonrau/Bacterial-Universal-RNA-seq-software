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
$formatScienceScanSummary = ${function:Format-ScienceScanSummary}
$getScienceKeggOrganismQuery = ${function:Get-ScienceKeggOrganismQuery}
$script:SuiteRoot = try { [string](Get-Variable -Name BacterialRNAAnalysisSuiteRoot -Scope Global -ValueOnly -ErrorAction Stop) } catch { '' }
if (-not $script:SuiteRoot) { $script:SuiteRoot = Find-ScienceSuiteRoot $PSScriptRoot }
$suiteRoot = $script:SuiteRoot
$pathwayState = [pscustomobject]@{ RunLog = ''; ReportPath = '' }

$hostView = New-ScienceModuleHost 'Functional analysis - Pathway Database Analysis' 'Run pathway over-representation with online KEGG or user-authorized TERM2GENE, BioCyc, and MetaCyc mappings, then inspect a linked interactive report.' '< Back to functional analysis'
$body = $hostView.Body
$body.AutoScroll = $false
$hostView.Library.Visible = $false

$header = $hostView.Back.Parent
$hostView.Back.Size = New-Object System.Drawing.Size(170, 34)
$instructions = New-ScienceButton 'Instructions'
$instructions.Size = New-Object System.Drawing.Size(120, 34)
$header.Controls.Add($instructions)
$instructions.Add_Click({
    try {
        $guide = Join-Path $suiteRoot 'Modules\GO Enrichment and Pathways\Documentation\Pathway Database Analysis Instructions.html'
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
[void]$page.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 215)))
[void]$page.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 276)))
[void]$page.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$body.Controls.Add($page)

$inputSection = New-ScienceSection '1. Selected genes, tested universe, and output' 209
$inputSection.Dock = [System.Windows.Forms.DockStyle]::Fill
$inputSection.Padding = New-Object System.Windows.Forms.Padding(14, 21, 14, 8)
$inputPanel = New-Object System.Windows.Forms.Panel
$inputPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$inputSection.Controls.Add($inputPanel)
$page.Controls.Add($inputSection, 0, 0)

$genes = New-ScienceInputRow 'Selected gene list' '' 'Genes selected for pathway over-representation. TSV/CSV/XLSX and one-gene-per-line files are accepted.' 'file' 'Gene tables (*.txt;*.tsv;*.csv;*.xlsx)|*.txt;*.tsv;*.csv;*.xlsx|All files (*.*)|*.*'
$universe = New-ScienceInputRow 'Background / universe' '' 'All tested and mappable genes from the experiment.' 'file' 'Gene tables (*.txt;*.tsv;*.csv;*.xlsx)|*.txt;*.tsv;*.csv;*.xlsx|All files (*.*)|*.*'
$geneColumn = New-ScienceInputRow 'Gene column (optional)' '' 'One shared identifier-column name for the selected-gene and universe tables; blank enables automatic detection.' 'text'
$output = New-ScienceInputRow 'Results folder' '' 'Writable folder for Pathway enrichment.xlsx, the run log, and reproducibility files.' 'folder'
$inputRows = @($genes, $universe, $geneColumn, $output)
for ($index = 0; $index -lt $inputRows.Count; $index++) {
    $inputRows[$index].Panel.Dock = [System.Windows.Forms.DockStyle]::None
    $inputRows[$index].Panel.Location = New-Object System.Drawing.Point(10, ($index * 34))
    $inputPanel.Controls.Add($inputRows[$index].Panel)
}
$scanInputs = New-ScienceButton 'Scan DE / functional results folder'
$scanInputs.Location = New-Object System.Drawing.Point(10, 143)
$scanInputs.Size = New-Object System.Drawing.Size(275, 31)
$manualInput = New-ScienceButton 'Manual Excel input'
$manualInput.Location = New-Object System.Drawing.Point(295, 143)
$manualInput.Size = New-Object System.Drawing.Size(175, 31)
$inputPanel.Controls.AddRange(@($scanInputs, $manualInput))

$mappingSection = New-ScienceSection '2. Pathway database / mapping source' 270
$mappingSection.Dock = [System.Windows.Forms.DockStyle]::Fill
$mappingSection.Padding = New-Object System.Windows.Forms.Padding(14, 21, 14, 8)
$mappingPanel = New-Object System.Windows.Forms.Panel
$mappingPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$mappingSection.Controls.Add($mappingPanel)
$page.Controls.Add($mappingSection, 0, 1)

$mappingIntro = New-Object System.Windows.Forms.Label
$mappingIntro.Text = 'Default and easiest: choose an online KEGG organism. The list uses valid organism codes; local TERM2GENE, BioCyc, and MetaCyc imports remain optional.'
$mappingIntro.Location = New-Object System.Drawing.Point(18, 0)
$mappingIntro.Size = New-Object System.Drawing.Size(1040, 29)
$mappingIntro.ForeColor = $script:ScienceGreenDark
$mappingIntro.Font = $script:ScienceFontInputLabel
$mappingPanel.Controls.Add($mappingIntro)

$term2gene = New-ScienceInputRow 'TERM2GENE file (optional)' '' 'Two/three-column pathway-to-gene TSV/CSV/XLSX.' 'file' 'Mapping (*.tsv;*.csv;*.txt;*.xlsx)|*.tsv;*.csv;*.txt;*.xlsx|All files (*.*)|*.*'
$biocyc = New-ScienceInputRow 'BioCyc file (optional)' '' 'User-authorized BioCyc pathway-to-gene export.' 'file' 'Mapping (*.tsv;*.csv;*.txt;*.xlsx)|*.tsv;*.csv;*.txt;*.xlsx|All files (*.*)|*.*'
$metacyc = New-ScienceInputRow 'MetaCyc file (optional)' '' 'User-provided/licensed MetaCyc pathway-to-gene export.' 'file' 'Mapping (*.tsv;*.csv;*.txt;*.xlsx)|*.tsv;*.csv;*.txt;*.xlsx|All files (*.*)|*.*'
$kegg = New-ScienceInputRow 'Online KEGG organism' '' 'KEGG code, scientific name, or NCBI taxonomy ID.' 'text'
$kegg.Panel.Controls.Remove($kegg.Box)
$kegg.Box.Dispose()
$kegg.Box = New-ScienceKeggOrganismComboBox
$kegg.Box.Location = New-Object System.Drawing.Point(250, 4)
$kegg.Box.Size = New-Object System.Drawing.Size(520, 28)
$kegg.Box.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$kegg.Panel.Controls.Add($kegg.Box)
$validateKegg = New-ScienceButton 'Validate / resolve'
$validateKegg.Location = New-Object System.Drawing.Point(780, 2)
$validateKegg.Size = New-Object System.Drawing.Size(150, 31)
$validateKegg.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$findKegg = New-ScienceButton 'Find more KEGG organisms'
$findKegg.Location = New-Object System.Drawing.Point(940, 2)
$findKegg.Size = New-Object System.Drawing.Size(205, 31)
$findKegg.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$kegg.Panel.Controls.AddRange(@($validateKegg,$findKegg))
$script:ScienceToolTip.SetToolTip($kegg.Box, 'Choose a searchable KEGG organism entry or type a code, scientific name, T number, or NCBI taxonomy ID. BRITE IDs such as br08610 are not organism codes.')
$script:ScienceToolTip.SetToolTip($findKegg, 'Open the official complete KEGG organism list. Copy the short organism code from the Code column and paste it here.')
$mappingRows = @($term2gene, $biocyc, $metacyc, $kegg)
for ($index = 0; $index -lt $mappingRows.Count; $index++) {
    $row = $mappingRows[$index]
    $row.Panel.Dock = [System.Windows.Forms.DockStyle]::None
    $row.Panel.Location = New-Object System.Drawing.Point(10, (30 + ($index * 34)))
    $row.Label.Width = 245
    $row.Box.Left = 250
    $mappingPanel.Controls.Add($row.Panel)
}
$mappingNote = New-Object System.Windows.Forms.Label
$mappingNote.Text = 'Mappings are cached and reused.'
$mappingNote.Location = New-Object System.Drawing.Point(18, 174)
$mappingNote.Size = New-Object System.Drawing.Size(560, 34)
$mappingNote.ForeColor = $script:ScienceMuted
$mappingPanel.Controls.Add($mappingNote)
$createMappingTemplate = New-ScienceButton 'Create TERM2GENE template'
$createMappingTemplate.Location = New-Object System.Drawing.Point(590, 169)
$createMappingTemplate.Size = New-Object System.Drawing.Size(220, 31)
$mappingHelp = New-ScienceButton 'Open mapping guide'
$mappingHelp.Location = New-Object System.Drawing.Point(820, 169)
$mappingHelp.Size = New-Object System.Drawing.Size(170, 31)
$mappingPanel.Controls.AddRange(@($createMappingTemplate, $mappingHelp))

$workspace = New-ScienceConsoleWorkspace '3. Status, actions, and live console' 260 'Ready. The environment check, pathway run, and any database messages appear in this console.'
$workspace.Section.Dock = [System.Windows.Forms.DockStyle]::Fill
$page.Controls.Add($workspace.Section, 0, 2)
$console = $workspace.Console
$status = $workspace.Status
$run = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Run pathway enrichment' -Primary)
$checkEnvironment = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Check environment / packages')
$installEnvironment = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Install or repair core')
$openLog = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Open run log')
$openLog.Enabled = $false
$openResults = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Open results folder')
$openReport = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Open interactive report')
$openReport.Enabled = $false

$layoutRows = {
    $inputWidth = [Math]::Max(740, $inputPanel.ClientSize.Width - 20)
    foreach ($row in $inputRows) {
        $row.Panel.Width = $inputWidth
        if ($row.Browse) { $row.Browse.Left = $row.Panel.ClientSize.Width - $row.Browse.Width - 14; $row.Box.Width = [Math]::Max(220, $row.Browse.Left - $row.Box.Left - 12) }
        else { $row.Box.Width = [Math]::Max(220, $row.Panel.ClientSize.Width - $row.Box.Left - 14) }
    }
    $mappingWidth = [Math]::Max(740, $mappingPanel.ClientSize.Width - 20)
    foreach ($row in $mappingRows) {
        $row.Panel.Width = $mappingWidth
        if ($row.Browse) { $row.Browse.Left = $row.Panel.ClientSize.Width - $row.Browse.Width - 14; $row.Box.Width = [Math]::Max(220, $row.Browse.Left - $row.Box.Left - 12) }
        elseif ($row -eq $kegg) {
            $findKegg.Left = $row.Panel.ClientSize.Width - $findKegg.Width - 14
            $validateKegg.Left = $findKegg.Left - $validateKegg.Width - 8
            $row.Box.Width = [Math]::Max(220, $validateKegg.Left - $row.Box.Left - 10)
        }
        else { $row.Box.Width = [Math]::Max(220, $row.Panel.ClientSize.Width - $row.Box.Left - 14) }
    }
    $mappingIntro.Width = [Math]::Max(520, $mappingPanel.ClientSize.Width - 36)
    $mappingHelp.Left = [Math]::Max(590, $mappingPanel.ClientSize.Width - $mappingHelp.Width - 18)
    $createMappingTemplate.Left = $mappingHelp.Left - $createMappingTemplate.Width - 10
    $mappingNote.Width = [Math]::Max(260, $createMappingTemplate.Left - $mappingNote.Left - 12)
}.GetNewClosure()
$inputPanel.Add_SizeChanged($layoutRows)
$mappingPanel.Add_SizeChanged($layoutRows)
& $layoutRows

$manualInput.Add_Click({
    try {
        $result = & $invokeManualWorkbook -SuiteRoot $suiteRoot -Profile 'pathway' -Console $console
        if ($null -eq $result) { return }
        $selectedPath = & $getManualFile $result 'selected_genes.tsv'
        $universePath = & $getManualFile $result 'gene_universe.tsv'
        $termPath = & $getManualFile $result 'term2gene.tsv'
        $biocycPath = & $getManualFile $result 'biocyc_mapping.tsv'
        $metacycPath = & $getManualFile $result 'metacyc_mapping.tsv'
        if ($selectedPath) { $genes.Box.Text = $selectedPath }
        if ($universePath) { $universe.Box.Text = $universePath }
        $term2gene.Box.Text = $termPath
        $biocyc.Box.Text = $biocycPath
        $metacyc.Box.Text = $metacycPath
        if (-not $output.Box.Text.Trim()) { $output.Box.Text = Join-Path ([System.IO.Path]::GetDirectoryName($result.Workbook)) 'Pathway Database Analysis Results' }
        $status.Text = 'Saved manual workbook loaded. Select or enter the mapping source, then run.'
        $status.ForeColor = $script:ScienceGreen
        & $showScienceInfo 'The saved workbook was validated and its pathway-analysis inputs were assigned.'
    } catch {
        $status.Text = 'Manual workbook could not be loaded. See the console.'
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        $console.AppendText($_.Exception.Message + "`r`n")
        & $showScienceError $_.Exception.Message
    }
}.GetNewClosure())

$createMappingTemplate.Add_Click({
    try {
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Title = 'Save an editable TERM2GENE mapping template'
        $dialog.Filter = 'Tab-separated mapping (*.tsv)|*.tsv|Comma-separated mapping (*.csv)|*.csv'
        $dialog.FileName = 'TERM2GENE_template.tsv'
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $separator = if ([System.IO.Path]::GetExtension($dialog.FileName).ToLowerInvariant() -eq '.csv') { ',' } else { "`t" }
        $text = @(
            ('term_id' + $separator + 'gene_id' + $separator + 'term_name'),
            ('PATHWAY-001' + $separator + 'GENE_0001' + $separator + 'Example pathway'),
            ('PATHWAY-001' + $separator + 'GENE_0002' + $separator + 'Example pathway')
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($dialog.FileName, ($text + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        & $showScienceInfo ("TERM2GENE template created:`r`n" + $dialog.FileName)
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure())
$mappingHelp.Add_Click({ $instructions.PerformClick() }.GetNewClosure())
$findKegg.Add_Click({
    try { [void](Start-Process -FilePath 'https://www.genome.jp/kegg/catalog/org_list.html') }
    catch { & $showScienceError ('Could not open the KEGG organism list. Open this address manually: https://www.genome.jp/kegg/catalog/org_list.html') }
}.GetNewClosure())

$validateKegg.Add_Click({
    try {
        $query = & $getScienceKeggOrganismQuery $kegg.Box.Text
        $console.Clear()
        $status.Text = "Resolving KEGG organism '$query' against the official catalog..."
        $status.ForeColor = $script:ScienceMuted
        $resultText = & $invokeScienceBackend -SuiteRoot $suiteRoot -Arguments @('kegg-species','--organism',$query) -Console $console
        $codeMatch = [regex]::Match([string]$resultText, '"code"\s*:\s*"([^"]+)"')
        $nameMatch = [regex]::Match([string]$resultText, '"name"\s*:\s*"([^"]+)"')
        if ($codeMatch.Success) {
            $resolvedName = if ($nameMatch.Success) { $nameMatch.Groups[1].Value } else { 'resolved organism' }
            $kegg.Box.Text = $codeMatch.Groups[1].Value + ' · ' + $resolvedName
        }
        $status.Text = 'KEGG organism resolved. Review the code, then run.'
        $status.ForeColor = $script:ScienceGreen
    } catch {
        $status.Text = 'KEGG organism could not be resolved. See the live console.'
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        $console.AppendText($_.Exception.Message + "`r`n")
        & $showScienceError $_.Exception.Message
    }
}.GetNewClosure())

$scanInputs.Add_Click({
    try {
        $root = & $selectScienceFolder 'Select the Differential Expression or Functional Enrichment results folder to scan recursively for pathway inputs'
        if (-not $root) { return }
        $files = @(& $getScienceScanInventory -Root $root)
        $selectedPath = & $findScienceScanFile -Files $files -Patterns @('(?i)significant.*gene','(?i)selected.*gene','(?i)differential.*expression','(?i)deseq2.*result','(?i)edger.*result') -Extensions @('.xlsx','.tsv','.csv','.txt') -ExcludePatterns @('(?i)universe|background|mapping|term2gene|network[_ -]?edges')
        $universePath = & $findScienceScanFile -Files $files -Patterns @('(?i)tested.*gene.*universe','(?i)gene.*universe','(?i)background.*gene','(?i)all.*tested.*gene','(?i)universe') -Extensions @('.xlsx','.tsv','.csv','.txt') -ExcludePatterns @('(?i)mapping|term2gene')
        $termPath = & $findScienceScanFile -Files $files -Patterns @('(?i)term2gene','(?i)gene[_ -]?to[_ -]?term','(?i)gene2term','(?i)pathway.*mapping') -Extensions @('.tsv','.csv','.txt','.xlsx') -ExcludePatterns @('(?i)biocyc|metacyc')
        $biocycPath = & $findScienceScanFile -Files $files -Patterns @('(?i)biocyc.*mapping','(?i)biocyc') -Extensions @('.tsv','.csv','.txt','.xlsx')
        $metacycPath = & $findScienceScanFile -Files $files -Patterns @('(?i)metacyc.*mapping','(?i)metacyc') -Extensions @('.tsv','.csv','.txt','.xlsx')
        if ($selectedPath) { $genes.Box.Text = $selectedPath }
        if ($universePath) { $universe.Box.Text = $universePath }
        if ($termPath) { $term2gene.Box.Text = $termPath }
        if ($biocycPath) { $biocyc.Box.Text = $biocycPath }
        if ($metacycPath) { $metacyc.Box.Text = $metacycPath }
        if (-not $output.Box.Text.Trim()) { $output.Box.Text = Join-Path $root 'Pathway Database Analysis Results' }
        $summary = & $formatScienceScanSummary -Assignments ([ordered]@{
            'Scanned DE / functional folder' = $root
            'Selected genes' = $selectedPath
            'Tested-gene universe' = $universePath
            'TERM2GENE mapping' = $termPath
            'BioCyc mapping' = $biocycPath
            'MetaCyc mapping' = $metacycPath
            'Results folder' = $output.Box.Text
        })
        $status.Text = 'DE / functional results-folder scan completed. Review the assigned mapping source.'
        & $showScienceInfo ("DE / functional results-folder scan completed.`r`n`r`n$summary")
    } catch { & $showScienceError ("Automatic input assignment failed.`r`n`r`n" + $_.Exception.Message) }
}.GetNewClosure())

$checkEnvironment.Add_Click({
    try {
        $console.Clear()
        $status.Text = 'Checking the environment and scientific packages...'
        $status.ForeColor = $script:ScienceMuted
        $null = & $invokeScienceBackend -SuiteRoot $suiteRoot -Arguments @('check') -Console $console
        $status.Text = 'Environment check completed. Optional tools are listed in the console.'
        $status.ForeColor = $script:ScienceGreen
    } catch {
        $status.Text = 'Environment/package check failed. See the console.'
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        $console.AppendText($_.Exception.Message + "`r`n")
    }
}.GetNewClosure())
$installEnvironment.Add_Click({
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
        if ($pathwayState.RunLog -and (Test-Path -LiteralPath $pathwayState.RunLog -PathType Leaf)) { [void](Start-Process -FilePath $pathwayState.RunLog) }
        else { & $showScienceInfo 'No pathway run log has been created yet.' }
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure())
$openResults.Add_Click({
    if ($output.Box.Text.Trim() -and (Test-Path -LiteralPath $output.Box.Text.Trim() -PathType Container)) { [void](Start-Process explorer.exe $output.Box.Text.Trim()) }
    else { & $showScienceInfo 'Choose or create a pathway results folder first.' }
}.GetNewClosure())
$openReport.Add_Click({
    try {
        $candidate = if ($pathwayState.ReportPath) { $pathwayState.ReportPath } else { Join-Path $output.Box.Text.Trim() 'Pathway enrichment interactive.html' }
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { [void](Start-Process -FilePath $candidate) }
        else { & $showScienceInfo 'No pathway interactive report has been created yet. Run pathway enrichment first.' }
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure())

$run.Add_Click({
    try {
        if (-not $genes.Box.Text.Trim()) { throw 'Choose a selected gene list.' }
        if (-not $universe.Box.Text.Trim()) { throw 'Choose the tested-gene background / universe.' }
        if (-not $output.Box.Text.Trim()) { throw 'Choose a results folder.' }
        if (-not ($term2gene.Box.Text.Trim() -or $biocyc.Box.Text.Trim() -or $metacyc.Box.Text.Trim() -or $kegg.Box.Text.Trim())) { throw 'Choose at least one mapping source: online KEGG, TERM2GENE, BioCyc, or MetaCyc.' }
        $arguments = @('pathway','--gene-list',$genes.Box.Text.Trim(),'--universe',$universe.Box.Text.Trim(),'--output-dir',$output.Box.Text.Trim())
        if ($geneColumn.Box.Text.Trim()) { $arguments += @('--gene-column',$geneColumn.Box.Text.Trim(),'--universe-column',$geneColumn.Box.Text.Trim()) }
        if ($term2gene.Box.Text.Trim()) { $arguments += @('--term2gene',$term2gene.Box.Text.Trim()) }
        if ($biocyc.Box.Text.Trim()) { $arguments += @('--biocyc-mapping',$biocyc.Box.Text.Trim()) }
        if ($metacyc.Box.Text.Trim()) { $arguments += @('--metacyc-mapping',$metacyc.Box.Text.Trim()) }
        if ($kegg.Box.Text.Trim()) {
            $keggQuery = & $getScienceKeggOrganismQuery $kegg.Box.Text
            $arguments += @('--kegg-organism',$keggQuery,'--kegg-confirmed')
        }
        $console.Clear()
        $status.Text = 'Running pathway enrichment and recording mapping provenance...'
        $status.ForeColor = $script:ScienceMuted
        $null = & $invokeScienceBackend -SuiteRoot $suiteRoot -Arguments $arguments -Console $console
        $logDir = Join-Path $output.Box.Text.Trim() 'Intermediate files'
        [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
        $pathwayState.RunLog = Join-Path $logDir 'Pathway run.log'
        Set-Content -LiteralPath $pathwayState.RunLog -Value $console.Text -Encoding UTF8
        $openLog.Enabled = $true
        $pathwayState.ReportPath = Join-Path $output.Box.Text.Trim() 'Pathway enrichment interactive.html'
        $openReport.Enabled = Test-Path -LiteralPath $pathwayState.ReportPath -PathType Leaf
        $status.Text = 'Pathway enrichment completed. Open the linked interactive report or review universe, coverage, and provenance.'
        $status.ForeColor = $script:ScienceGreen
        & $showScienceInfo 'Pathway enrichment completed. Use Open interactive report for linked pathway plots and member genes; the workbook retains the tested universe, annotation coverage, and database provenance.'
    } catch {
        $console.AppendText($_.Exception.Message + "`r`n")
        $status.Text = 'Pathway analysis stopped. See the full message in the console.'
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        try {
            if ($output.Box.Text.Trim()) {
                $logDir = Join-Path $output.Box.Text.Trim() 'Intermediate files'
                [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
                $pathwayState.RunLog = Join-Path $logDir 'Pathway run.log'
                Set-Content -LiteralPath $pathwayState.RunLog -Value $console.Text -Encoding UTF8
                $openLog.Enabled = $true
            }
        } catch { }
        & $showScienceError $_.Exception.Message
    }
}.GetNewClosure())

Show-ScienceModuleHost $hostView
