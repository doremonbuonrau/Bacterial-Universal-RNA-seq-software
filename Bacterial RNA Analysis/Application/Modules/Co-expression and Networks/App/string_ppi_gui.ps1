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

# Event handlers execute in closure modules; capture every shared function they use.
$invokeScienceBackend = ${function:Invoke-ScienceBackend}
$invokeManualWorkbook = ${function:Invoke-ScienceManualWorkbook}
$getManualFile = ${function:Get-ScienceManualFile}
$getScienceTaxonId = ${function:Get-ScienceTaxonId}
$showScienceError = ${function:Show-ScienceError}
$showScienceInfo = ${function:Show-ScienceInfo}
$selectScienceFolder = ${function:Select-ScienceFolder}
$getScienceScanInventory = ${function:Get-ScienceScanInventory}
$findScienceScanFile = ${function:Find-ScienceScanFile}
$formatScienceScanSummary = ${function:Format-ScienceScanSummary}
$script:SuiteRoot = try { [string](Get-Variable -Name BacterialRNAAnalysisSuiteRoot -Scope Global -ValueOnly -ErrorAction Stop) } catch { '' }
if (-not $script:SuiteRoot) { $script:SuiteRoot = Find-ScienceSuiteRoot $PSScriptRoot }
$suiteRoot = $script:SuiteRoot
$stringState = [pscustomobject]@{ RunLog = ''; ReportPath = '' }

$hostView = New-ScienceModuleHost 'Functional analysis - STRING PPI' 'Retrieve physical or functional STRING evidence, optionally combine it with expression-network edges, and retain the exact species and score provenance.' '< Back to functional analysis'
$body = $hostView.Body
$body.AutoScroll = $false
$hostView.Back.Size = New-Object System.Drawing.Size(205, 34)
$hostView.Library.Visible = $false

$header = $hostView.Back.Parent
$instructions = New-ScienceButton 'Instructions'
$instructions.Size = New-Object System.Drawing.Size(120, 34)
$header.Controls.Add($instructions)
$instructions.Add_Click({
    try {
        $guide = Join-Path $suiteRoot 'Modules\Co-expression and Networks\Documentation\STRING Protein Associations Instructions.html'
        if (-not (Test-Path -LiteralPath $guide -PathType Leaf)) { throw "Instruction file not found: $guide" }
        [void](Start-Process -FilePath $guide)
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure())

$page = New-Object System.Windows.Forms.TableLayoutPanel
$page.Dock = [System.Windows.Forms.DockStyle]::Fill
$page.ColumnCount = 1
$page.RowCount = 2
$page.Padding = New-Object System.Windows.Forms.Padding(8, 5, 8, 8)
$page.BackColor = $script:ScienceBackground
[void]$page.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$page.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 354)))
[void]$page.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$body.Controls.Add($page)

$inputSection = New-ScienceSection '1. STRING inputs, options, and output' 348
$inputSection.Dock = [System.Windows.Forms.DockStyle]::Fill
$inputSection.Padding = New-Object System.Windows.Forms.Padding(14, 21, 14, 8)
$inputPanel = New-Object System.Windows.Forms.Panel
$inputPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$inputSection.Controls.Add($inputPanel)
$page.Controls.Add($inputSection, 0, 0)

$genes = New-ScienceInputRow 'Gene / protein list' '' 'One identifier per line, or a TSV/CSV/XLSX table. A gene/protein header is detected automatically.' 'file' 'Gene tables (*.txt;*.tsv;*.csv;*.xlsx)|*.txt;*.tsv;*.csv;*.xlsx|All files (*.*)|*.*'
$expr = New-ScienceInputRow 'Expression-network edges' '' 'Optional WGCNA/CEMiTool/GENIE3 edge table with source and target columns.' 'file' 'Edge tables (*.tsv;*.csv;*.txt;*.xlsx)|*.tsv;*.csv;*.txt;*.xlsx|All files (*.*)|*.*'
$out = New-ScienceInputRow 'Results folder' '' 'Writable output folder for the interactive HTML report, workbook, GraphML, raw responses, and run log.' 'folder'
$aliases = New-ScienceInputRow 'Identifier aliases (optional)' '' 'A matching GFF or gene_id-to-protein_id / UniProt table can resolve locus tags that STRING does not recognize. Only verified annotation links are used.' 'file' 'Annotation / alias tables (*.gff;*.gff3;*.gtf;*.tsv;*.csv;*.xlsx)|*.gff;*.gff3;*.gtf;*.tsv;*.csv;*.xlsx|All files (*.*)|*.*'
$inputRows = @($genes, $expr, $aliases, $out)
for ($index = 0; $index -lt $inputRows.Count; $index++) {
    $inputRows[$index].Panel.Dock = [System.Windows.Forms.DockStyle]::None
    $inputRows[$index].Panel.Location = New-Object System.Drawing.Point(10, (3 + ($index * 36)))
    $inputPanel.Controls.Add($inputRows[$index].Panel)
}

$scanInputs = New-ScienceButton 'Scan DE / functional results folder'
$scanInputs.Location = New-Object System.Drawing.Point(10, 150)
$scanInputs.Size = New-Object System.Drawing.Size(275, 31)
$manualInput = New-ScienceButton 'Manual Excel input'
$manualInput.Location = New-Object System.Drawing.Point(295, 150)
$manualInput.Size = New-Object System.Drawing.Size(175, 31)
$latestInputs = New-ScienceButton 'Use latest results'
$latestInputs.Location = New-Object System.Drawing.Point(480,150)
$latestInputs.Size = New-Object System.Drawing.Size(180,31)
$inputPanel.Controls.AddRange(@($scanInputs, $manualInput,$latestInputs))

$organismLabel = New-Object System.Windows.Forms.Label
$organismLabel.Text = 'STRING organism'
$organismLabel.Location = New-Object System.Drawing.Point(10, 194)
$organismLabel.Size = New-Object System.Drawing.Size(205, 24)
$organismLabel.Font = $script:ScienceFontInputLabel
$organism = New-ScienceOrganismComboBox
$organism.Location = New-Object System.Drawing.Point(220, 190)
$organism.Size = New-Object System.Drawing.Size(500, 28)
$validateOrganism = New-ScienceButton 'Validate organism'
$validateOrganism.Location = New-Object System.Drawing.Point(730, 188)
$validateOrganism.Size = New-Object System.Drawing.Size(160, 31)
$findOrganism = New-ScienceButton 'Find more STRING organisms'
$findOrganism.Location = New-Object System.Drawing.Point(900, 188)
$findOrganism.Size = New-Object System.Drawing.Size(215, 31)
$script:ScienceToolTip.SetToolTip($organism, 'Choose a common supported STRING organism, or type a numeric NCBI/STRING taxonomy ID. Validation uses the official STRING v12 organism catalog.')
$script:ScienceToolTip.SetToolTip($findOrganism, 'Open STRING and its official supported-organism catalog. Use an exact taxonomy ID supported by the configured STRING version.')
$inputPanel.Controls.AddRange(@($organismLabel, $organism, $validateOrganism, $findOrganism))

$typeLabel = New-Object System.Windows.Forms.Label
$typeLabel.Text = 'Network type'
$typeLabel.Location = New-Object System.Drawing.Point(10, 234)
$typeLabel.Size = New-Object System.Drawing.Size(205, 24)
$typeLabel.Font = $script:ScienceFontInputLabel
$type = New-Object System.Windows.Forms.ComboBox
$type.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$type.Items.Add('physical')
[void]$type.Items.Add('functional')
$type.SelectedIndex = 0
$type.Location = New-Object System.Drawing.Point(150, 230)
$type.Size = New-Object System.Drawing.Size(155, 28)
$typeLabel.Width=130
$inputPanel.Controls.AddRange(@($typeLabel, $type))

$score = New-ScienceInputRow 'Minimum STRING score' '700' 'STRING required_score uses 0-1000. Higher values retain fewer, stronger-evidence associations.' 'text'
$score.Panel.Dock = [System.Windows.Forms.DockStyle]::None
$score.Panel.Location = New-Object System.Drawing.Point(335, 228)
$score.Label.Width = 190
$scoreHelp = New-ScienceHelpButton 'Minimum STRING score (0-1000)' 'Higher scores are more conservative: fewer, better-supported edges, but the network can become sparse, fragmented, or empty. Lower scores increase coverage and density but admit weaker associations. 700 is a high-confidence starting point.' -HoverOnly
$scoreHelp.Location = New-Object System.Drawing.Point(286, 5)
$score.Panel.Controls.Add($scoreHelp)
$inputPanel.Controls.Add($score.Panel)

$nodes = New-ScienceInputRow 'Add external interactors' '0' '0 preserves the submitted set. A positive number asks STRING to add neighboring proteins.' 'text'
$nodes.Panel.Dock = [System.Windows.Forms.DockStyle]::None
$nodes.Panel.Location = New-Object System.Drawing.Point(10, 266)
$inputPanel.Controls.Add($nodes.Panel)

$notice = New-Object System.Windows.Forms.Label
$notice.Text = 'Use the organism that matches your reference. If locus tags have no matches, supply verified identifier aliases above. Confidence describes association evidence, not binding strength.'
$notice.Location = New-Object System.Drawing.Point(360, 266)
$notice.Size = New-Object System.Drawing.Size(650, 50)
$notice.ForeColor = $script:ScienceMuted
$inputPanel.Controls.Add($notice)

$workspace = New-ScienceConsoleWorkspace '2. Status, actions, and live console' 320 'Ready.'
$workspace.Section.Dock = [System.Windows.Forms.DockStyle]::Fill
$page.Controls.Add($workspace.Section, 0, 1)
$console = $workspace.Console
$status = $workspace.Status
$run = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Retrieve STRING network' -Primary)
$checkEnvironment = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Check environment / packages')
$installEnvironment = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Install or repair core')
$openLog = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Open run log')
$openLog.Enabled = $false
$openResults = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Open results folder')
$openReport = Add-ScienceConsoleAction $workspace (New-ScienceButton 'Open interactive report')
$openReport.Enabled = $false

$layoutInput = {
    $available = [Math]::Max(760, $inputPanel.ClientSize.Width - 20)
    foreach ($row in $inputRows) {
        $row.Panel.Width = $available
        if ($row.Browse) {
            $row.Browse.Left = $row.Panel.ClientSize.Width - $row.Browse.Width - 14
            $row.Box.Width = [Math]::Max(240, $row.Browse.Left - $row.Box.Left - 12)
        } else {
            $row.Box.Width = [Math]::Max(240, $row.Panel.ClientSize.Width - $row.Box.Left - 14)
        }
    }
    $findOrganism.Left = [Math]::Max(770, $inputPanel.ClientSize.Width - $findOrganism.Width - 14)
    $validateOrganism.Left = $findOrganism.Left - $validateOrganism.Width - 8
    $organism.Width = [Math]::Max(260, $validateOrganism.Left - $organism.Left - 10)
    $score.Panel.SetBounds(325,228,[Math]::Max(410,$inputPanel.ClientSize.Width-339),35)
    $score.Box.SetBounds(196,5,82,26);$scoreHelp.SetBounds(286,5,22,22)
    $nodes.Panel.SetBounds(10,266,335,35);$nodes.Label.Width=205;$nodes.Box.SetBounds(210,5,90,26)
    $notice.SetBounds(360,264,[Math]::Max(360,$inputPanel.ClientSize.Width-378),54)
}.GetNewClosure()
$inputPanel.Add_SizeChanged($layoutInput)
& $layoutInput

$findOrganism.Add_Click({
    try { [void](Start-Process -FilePath 'https://string-db.org/') }
    catch { & $showScienceError ('Could not open STRING. Open this address manually: https://string-db.org/') }
}.GetNewClosure())

$manualInput.Add_Click({
    try {
        $result = & $invokeManualWorkbook -SuiteRoot $suiteRoot -Profile 'ppi' -Console $console
        if ($null -eq $result) { return }
        $genePath = & $getManualFile $result 'gene_list.tsv'
        $edgePath = & $getManualFile $result 'expression_edges.tsv'
        $aliases.Box.Text = & $getManualFile $result 'identifier_aliases.tsv'
        if ($genePath) { $genes.Box.Text = $genePath }
        $expr.Box.Text = $edgePath
        if (-not $out.Box.Text.Trim()) { $out.Box.Text = Join-Path ([System.IO.Path]::GetDirectoryName($result.Workbook)) 'STRING Protein Associations Results' }
        $status.Text = 'Manual input loaded. Review the assigned inputs and organism, then retrieve the network.'
        $status.ForeColor = $script:ScienceGreen
        & $showScienceInfo 'The input data was validated and assigned to STRING PPI.'
    } catch {
        $status.Text = 'Manual workbook could not be loaded. See the console.'
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        $console.AppendText($_.Exception.Message + "`r`n")
        & $showScienceError $_.Exception.Message
    }
}.GetNewClosure())

$scanInputs.Add_Click({
    try {
        $root = & $selectScienceFolder 'Select the Differential Expression or Functional Enrichment results folder to scan recursively for PPI inputs'
        if (-not $root) { return }
        $files = @(& $getScienceScanInventory -Root $root)
        $genePath = & $findScienceScanFile -Files $files -Patterns @(
            '(?i)significant.*gene', '(?i)selected.*gene', '(?i)gene[_ -]?list',
            '(?i)differential.*expression', '(?i)deseq2.*result', '(?i)edger.*result'
        ) -Extensions @('.xlsx','.tsv','.csv','.txt') -ExcludePatterns @('(?i)network[_ -]?edges|mapping|universe|background|taxonomy|taxid')
        $edgePath = & $findScienceScanFile -Files $files -Patterns @(
            '(?i)network[_ -]?edges', '(?i)coexpression.*edges', '(?i)co-expression.*edges',
            '(?i)genie3.*edges', '(?i)regulatory.*edges'
        ) -Extensions @('.xlsx','.tsv','.csv','.txt') -ExcludePatterns @('(?i)string')
        $taxPath = & $findScienceScanFile -Files $files -Patterns @('(?i)taxonomy[_ -]?id','(?i)taxon[_ -]?id','(?i)taxid') -Extensions @('.txt','.tsv','.csv')
        if ($genePath) { $genes.Box.Text = $genePath }
        $expr.Box.Text = $edgePath
        $aliasPath = & $findScienceScanFile -Files $files -Patterns @('(?i)identifier[_ -]?aliases','(?i)gene[_ -]?(to[_ -]?)?(protein|uniprot)','(?i)annotation.*mapping','(?i)gene[_ -]?annotation','(?i)gene[_ -]?aliases','(?i)reference.*gff','(?i)genomic.*gff','(?i)\.gff3?$') -Extensions @('.tsv','.csv','.xlsx','.gff','.gff3','.gtf')
        if (-not $aliasPath) {
            $parent = Split-Path -Parent $root
            if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) {
                $projectFiles = @(& $getScienceScanInventory -Root $parent)
                $aliasPath = & $findScienceScanFile -Files $projectFiles -Patterns @('(?i)identifier[_ -]?aliases','(?i)gene[_ -]?(to[_ -]?)?(protein|uniprot)','(?i)annotation.*mapping','(?i)reference.*gff','(?i)genomic.*gff','(?i)\.gff3?$') -Extensions @('.tsv','.csv','.xlsx','.gff','.gff3','.gtf')
            }
        }
        $aliases.Box.Text = $aliasPath
        if ($taxPath -and -not $organism.Text.Trim()) {
            $taxText = Get-Content -LiteralPath $taxPath -Raw -ErrorAction SilentlyContinue
            $taxMatch = [regex]::Match([string]$taxText, '(?<!\d)(\d{2,9})(?!\d)')
            if ($taxMatch.Success) { $organism.Text = $taxMatch.Groups[1].Value }
        }
        if (-not $out.Box.Text.Trim()) { $out.Box.Text = Join-Path $root 'STRING Protein Associations Results' }
        $summary = & $formatScienceScanSummary -Assignments ([ordered]@{
            'Scanned folder' = $root
            'Gene or protein list' = $genePath
            'Expression-network edges' = $edgePath
            'Identifier aliases' = $aliasPath
            'Taxonomy file' = $taxPath
            'Results folder' = $out.Box.Text
        })
        $status.Text = 'DE / functional folder scan completed. Confirm and validate the organism.'
        & $showScienceInfo ("DE / functional results-folder scan completed.`r`n`r`n$summary`r`n`r`nConfirm and validate the organism before retrieval.")
    } catch { & $showScienceError ("Automatic input assignment failed.`r`n`r`n" + $_.Exception.Message) }
}.GetNewClosure())

$latestInputs.Add_Click({
    try {
        $stateFolder=Join-Path $suiteRoot 'Modules\Shared Analysis State'
        $dePointer=Join-Path $stateFolder 'last_de_output.txt'
        if(-not (Test-Path -LiteralPath $dePointer)){throw 'No completed DE result has been recorded. Use Scan DE / functional results folder or Manual input.'}
        $deRoot=(Get-Content -LiteralPath $dePointer -Raw).Trim()
        if(-not (Test-Path -LiteralPath $deRoot -PathType Container)){throw 'The latest DE results folder is no longer available. Use Scan DE / functional results folder.'}
        $files=@(& $getScienceScanInventory -Root $deRoot)
        $genePath=& $findScienceScanFile -Files $files -Patterns @('(?i)significant.*gene','(?i)selected.*gene') -Extensions @('.tsv','.txt','.csv','.xlsx') -ExcludePatterns @('(?i)mapping|universe|background')
        if(-not $genePath){throw 'The latest DE result has no significant/selected gene list. Select a gene list manually; the entire tested-gene table is not substituted.'}
        $genes.Box.Text=$genePath
        $aliases.Box.Text=& $findScienceScanFile -Files $files -Patterns @('(?i)identifier[_ -]?aliases','(?i)gene[_ -]?(to[_ -]?)?(protein|uniprot)','(?i)annotation.*mapping','(?i)gene[_ -]?annotation','(?i)gene[_ -]?aliases','(?i)\.gff3?$') -Extensions @('.tsv','.csv','.xlsx','.gff','.gff3','.gtf')
        if(-not $aliases.Box.Text.Trim()){
            $rnaPointer=Join-Path $stateFolder 'last_rnaseq_output.txt'
            if(Test-Path -LiteralPath $rnaPointer){
                $rnaRoot=(Get-Content -LiteralPath $rnaPointer -Raw).Trim()
                if(Test-Path -LiteralPath $rnaRoot -PathType Container){
                    $rnaFiles=@(& $getScienceScanInventory -Root $rnaRoot)
                    $aliases.Box.Text=& $findScienceScanFile -Files $rnaFiles -Patterns @('(?i)reference.*gff','(?i)genomic.*gff','(?i)annotation.*\.gff','(?i)identifier[_ -]?aliases','(?i)gene[_ -]?(to[_ -]?)?(protein|uniprot)','(?i)annotation.*mapping','(?i)\.gff3?$') -Extensions @('.gff','.gff3','.gtf','.tsv','.csv','.xlsx')
                }
            }
        }
        $expr.Box.Text=''
        $networkPointer=Join-Path $stateFolder 'last_network_output.txt'
        if(Test-Path -LiteralPath $networkPointer){
            $networkRoot=(Get-Content -LiteralPath $networkPointer -Raw).Trim()
            # Auto-pair expression edges only when both outputs share a project folder.
            if((Test-Path -LiteralPath $networkRoot -PathType Container) -and ([System.IO.Path]::GetDirectoryName($networkRoot.TrimEnd('\')) -eq [System.IO.Path]::GetDirectoryName($deRoot.TrimEnd('\')))){
                $networkFiles=@(& $getScienceScanInventory -Root $networkRoot)
                $expr.Box.Text=& $findScienceScanFile -Files $networkFiles -Patterns @('(?i)network[_ -]?edges','(?i)coexpression.*edges') -Extensions @('.tsv','.csv','.xlsx') -ExcludePatterns @('(?i)string')
            }
        }
        if(-not $out.Box.Text.Trim()){$out.Box.Text=Join-Path (Split-Path -Parent $deRoot) 'STRING Protein Associations Results'}
        $status.Text='Latest DE gene list loaded. A matching RNA-processing annotation was assigned when available; confirm the organism before retrieval.'
        $console.AppendText("Latest DE results: $deRoot`r`nSelected genes: $genePath`r`nIdentifier aliases: $($aliases.Box.Text)`r`nMatching project edges: $($expr.Box.Text)`r`n")
    }catch{& $showScienceError $_.Exception.Message}
}.GetNewClosure())

$validateOrganism.Add_Click({
    try {
        $taxid = & $getScienceTaxonId $organism.Text
        $console.Clear()
        $status.Text = "Validating taxonomy ID $taxid against STRING v12..."
        $null = & $invokeScienceBackend -SuiteRoot $suiteRoot -Arguments @('string-species','--taxid',$taxid) -Console $console
        $status.Text = "STRING organism $taxid is supported."
        $status.ForeColor = $script:ScienceGreen
    } catch {
        $status.Text = 'Organism is not supported or could not be validated. See the console.'
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        $console.AppendText($_.Exception.Message + "`r`n")
        & $showScienceError $_.Exception.Message
    }
}.GetNewClosure())

$checkEnvironment.Add_Click({
    try {
        $console.Clear()
        $status.Text = 'Checking the shared scientific environment and packages...'
        $status.ForeColor = $script:ScienceMuted
        $null = & $invokeScienceBackend -SuiteRoot $suiteRoot -Arguments @('check') -Console $console
        $status.Text = 'Scientific backend is ready. Cached STRING requests will be reused.'
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
        $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $installer + '" -AnalysisType both'
        [void](Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine)
        $status.Text = 'Core/scientific installer opened. Its progress appears in the installer console.'
        $console.AppendText("Opened the core/scientific environment installer. Run Check environment / packages after it finishes.`r`n")
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure())

$openLog.Add_Click({
    try {
        if ($stringState.RunLog -and (Test-Path -LiteralPath $stringState.RunLog -PathType Leaf)) { [void](Start-Process -FilePath $stringState.RunLog) }
        else { & $showScienceInfo 'No STRING run log has been created yet.' }
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure())
$openResults.Add_Click({
    try {
        if ($out.Box.Text.Trim() -and (Test-Path -LiteralPath $out.Box.Text.Trim() -PathType Container)) { [void](Start-Process explorer.exe $out.Box.Text.Trim()) }
        else { & $showScienceInfo 'Choose or create a STRING results folder first.' }
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure())
$openReport.Add_Click({
    try {
        $candidate = if ($stringState.ReportPath) { $stringState.ReportPath } else { Join-Path $out.Box.Text.Trim() 'STRING PPI interactive.html' }
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { [void](Start-Process -FilePath $candidate) }
        else { & $showScienceInfo 'No STRING interactive report has been created yet. Run the retrieval first.' }
    } catch { & $showScienceError $_.Exception.Message }
}.GetNewClosure())

$run.Add_Click({
    try {
        if (-not $genes.Box.Text.Trim()) { throw 'Choose a gene/protein list.' }
        if (-not $organism.Text.Trim()) { throw 'Choose or enter the STRING organism taxonomy ID.' }
        if (-not $out.Box.Text.Trim()) { throw 'Choose a results folder.' }
        $taxid = & $getScienceTaxonId $organism.Text
        $requiredScore = 0
        if (-not [int]::TryParse($score.Box.Text.Trim(), [ref]$requiredScore) -or $requiredScore -lt 0 -or $requiredScore -gt 1000) { throw 'Minimum STRING score must be an integer from 0 through 1000.' }
        $addNodes = 0
        if (-not [int]::TryParse($nodes.Box.Text.Trim(), [ref]$addNodes) -or $addNodes -lt 0) { throw 'Add external interactors must be a non-negative integer.' }
        if (-not $aliases.Box.Text.Trim()) {
            $stateFolder=Join-Path $suiteRoot 'Modules\Shared Analysis State'
            $candidateRoots=New-Object System.Collections.Generic.List[string]
            $rnaPointer=Join-Path $stateFolder 'last_rnaseq_output.txt'
            if(Test-Path -LiteralPath $rnaPointer){$candidateRoots.Add((Get-Content -LiteralPath $rnaPointer -Raw).Trim())}
            $geneParent=Split-Path -Parent $genes.Box.Text.Trim()
            if($geneParent){$candidateRoots.Add($geneParent);$candidateRoots.Add((Split-Path -Parent $geneParent))}
            foreach($candidateRoot in @($candidateRoots|Select-Object -Unique)){
                if(-not $candidateRoot -or -not (Test-Path -LiteralPath $candidateRoot -PathType Container)){continue}
                $candidateFiles=@(& $getScienceScanInventory -Root $candidateRoot)
                $autoAlias=& $findScienceScanFile -Files $candidateFiles -Patterns @('(?i)reference.*gff','(?i)genomic.*gff','(?i)annotation.*\.gff','(?i)identifier[_ -]?aliases','(?i)gene[_ -]?(to[_ -]?)?(protein|uniprot)','(?i)annotation.*mapping','(?i)\.gff3?$') -Extensions @('.gff','.gff3','.gtf','.tsv','.csv','.xlsx')
                if($autoAlias){$aliases.Box.Text=$autoAlias;break}
            }
        }
        $arguments = @('string','--gene-list',$genes.Box.Text.Trim(),'--taxid',$taxid,'--network-type',[string]$type.SelectedItem,'--required-score',[string]$requiredScore,'--add-nodes',[string]$addNodes,'--output-dir',$out.Box.Text.Trim())
        if ($expr.Box.Text.Trim()) { $arguments += @('--expression-edges',$expr.Box.Text.Trim()) }
        if ($aliases.Box.Text.Trim()) { $arguments += @('--identifier-aliases',$aliases.Box.Text.Trim()) }
        $console.Clear()
        $console.AppendText("Starting STRING retrieval after official organism validation...`r`n")
        if($aliases.Box.Text.Trim()){$console.AppendText("Identifier bridge assigned automatically or manually: $($aliases.Box.Text.Trim())`r`n")}
        $status.Text = 'Retrieving STRING mapping and network evidence...'
        $status.ForeColor = $script:ScienceMuted
        $null = & $invokeScienceBackend -SuiteRoot $suiteRoot -Arguments $arguments -Console $console
        $logDir = Join-Path $out.Box.Text.Trim() 'Intermediate files'
        [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
        $stringState.RunLog = Join-Path $logDir 'STRING run.log'
        Set-Content -LiteralPath $stringState.RunLog -Value $console.Text -Encoding UTF8
        $openLog.Enabled = $true
        $stringState.ReportPath = Join-Path $out.Box.Text.Trim() 'STRING PPI interactive.html'
        $openReport.Enabled = Test-Path -LiteralPath $stringState.ReportPath -PathType Leaf
        $status.Text = 'STRING retrieval completed. Open the interactive report or review the workbook and provenance.'
        $status.ForeColor = $script:ScienceGreen
        & $showScienceInfo 'STRING network retrieval completed. Use Open interactive report for the linked graph and spreadsheet; GraphML and the Excel workbook remain available for other tools.'
    } catch {
        $console.AppendText($_.Exception.Message + "`r`n")
        $status.Text = 'STRING retrieval stopped. The full scientific error is shown in the console.'
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        try {
            if ($out.Box.Text.Trim()) {
                $logDir = Join-Path $out.Box.Text.Trim() 'Intermediate files'
                [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
                $stringState.RunLog = Join-Path $logDir 'STRING run.log'
                Set-Content -LiteralPath $stringState.RunLog -Value $console.Text -Encoding UTF8
                $openLog.Enabled = $true
            }
        } catch { }
        & $showScienceError $_.Exception.Message
    }
}.GetNewClosure())

Show-ScienceModuleHost $hostView
