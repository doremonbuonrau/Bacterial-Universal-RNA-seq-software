Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ScienceGreen = [System.Drawing.Color]::FromArgb(65, 122, 75)
$script:ScienceGreenDark = [System.Drawing.Color]::FromArgb(42, 85, 52)
$script:ScienceGreenSoft = [System.Drawing.Color]::FromArgb(230, 242, 232)
$script:ScienceBlue = [System.Drawing.Color]::FromArgb(55, 116, 151)
$script:ScienceSurface = [System.Drawing.Color]::White
$script:ScienceBackground = [System.Drawing.Color]::FromArgb(245, 248, 246)
$script:ScienceBorder = [System.Drawing.Color]::FromArgb(205, 218, 208)
$script:ScienceInk = [System.Drawing.Color]::FromArgb(30, 42, 34)
$script:ScienceMuted = [System.Drawing.Color]::FromArgb(88, 101, 93)

# Shared GUI resources. Creating a new Font and ToolTip for every field was
# noticeably expensive when opening the newer scientific modules. Reuse the
# same immutable fonts and one ToolTip instance within each loaded GUI scope.
$script:ScienceFontButton = New-Object System.Drawing.Font('Segoe UI', [single]9.5, [System.Drawing.FontStyle]::Bold)
$script:ScienceFontInputLabel = New-Object System.Drawing.Font('Segoe UI', [single]9.5, [System.Drawing.FontStyle]::Bold)
$script:ScienceFontSection = New-Object System.Drawing.Font('Segoe UI', [single]10, [System.Drawing.FontStyle]::Bold)
$script:ScienceToolTip = New-Object System.Windows.Forms.ToolTip


function Enable-ScienceNeutralComboBox {
    param([System.Windows.Forms.ComboBox]$Combo)
    if (-not $Combo) { return }
    if ($Combo.DrawMode -ne [System.Windows.Forms.DrawMode]::OwnerDrawFixed) {
        $Combo.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
        $Combo.ItemHeight = 22
        $Combo.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
        $Combo.BackColor = $script:ScienceSurface
        $Combo.ForeColor = $script:ScienceInk
        $Combo.Add_DrawItem({
            param($sender, $e)
            $isEdit = (($e.State -band [System.Windows.Forms.DrawItemState]::ComboBoxEdit) -ne 0)
            $selected = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0) -and (-not $isEdit)
            $back = if ($selected) { $script:ScienceGreenSoft } else { $script:ScienceSurface }
            $brush = New-Object System.Drawing.SolidBrush($back)
            try { $e.Graphics.FillRectangle($brush, $e.Bounds) } finally { $brush.Dispose() }
            $text = ''
            if ($e.Index -ge 0 -and $e.Index -lt $sender.Items.Count) { $text = [string]$sender.Items[$e.Index] }
            elseif ($sender.SelectedIndex -ge 0 -and $sender.SelectedIndex -lt $sender.Items.Count) { $text = [string]$sender.Items[$sender.SelectedIndex] }
            elseif ($sender.Text) { $text = [string]$sender.Text }
            $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $text, $sender.Font, $e.Bounds, $script:ScienceInk, $back, $flags)
        })
    }
}

function Set-ScienceNeutralGridSelection {
    param([System.Windows.Forms.DataGridView]$Grid)
    if (-not $Grid) { return }
    foreach ($style in @($Grid.DefaultCellStyle, $Grid.RowsDefaultCellStyle, $Grid.AlternatingRowsDefaultCellStyle)) {
        $style.SelectionBackColor = $script:ScienceGreenSoft
        $style.SelectionForeColor = $script:ScienceInk
    }
    $Grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $Grid.ColumnHeadersDefaultCellStyle.BackColor
    $Grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $Grid.ColumnHeadersDefaultCellStyle.ForeColor
    $Grid.RowHeadersDefaultCellStyle.SelectionBackColor = $script:ScienceGreenSoft
    $Grid.RowHeadersDefaultCellStyle.SelectionForeColor = $script:ScienceInk
    $Grid.Add_EditingControlShowing({
        param($sender, $e)
        if ($e.Control -is [System.Windows.Forms.ComboBox]) { Enable-ScienceNeutralComboBox ([System.Windows.Forms.ComboBox]$e.Control) }
    })
}

function Apply-ScienceNeutralSelectionTheme {
    param([System.Windows.Forms.Control]$RootControl)
    if (-not $RootControl) { return }
    if ($RootControl -is [System.Windows.Forms.ComboBox]) { Enable-ScienceNeutralComboBox ([System.Windows.Forms.ComboBox]$RootControl) }
    if ($RootControl -is [System.Windows.Forms.DataGridView]) { Set-ScienceNeutralGridSelection ([System.Windows.Forms.DataGridView]$RootControl) }
    foreach ($child in $RootControl.Controls) { Apply-ScienceNeutralSelectionTheme $child }
}

function Find-ScienceSuiteRoot([string]$StartPath) {
    $current = Get-Item -LiteralPath $StartPath
    if (-not $current.PSIsContainer) { $current = $current.Directory }
    for ($i = 0; $i -lt 10 -and $current; $i++) {
        $candidate = Join-Path $current.FullName 'Modules\Scientific Expansion\Backend\scientific_expansion.py'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $current.FullName }
        $current = $current.Parent
    }
    throw 'Cannot locate the Bacterial RNA Analysis suite root or scientific expansion backend.'
}

function Select-ScienceFile([string]$Filter = 'All files (*.*)|*.*') {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = $Filter
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
    return ''
}

function Select-ScienceFolder([string]$Description = 'Select a folder') {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
    return ''
}

function Get-ScienceScanInventory {
    param([Parameter(Mandatory = $true)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue)
}

function Find-ScienceScanFile {
    param(
        [object[]]$Files,
        [string[]]$Patterns,
        [string[]]$Extensions = @(),
        [string[]]$ExcludePatterns = @()
    )
    if (-not $Files -or -not $Patterns) { return '' }
    $allowed = @{}
    foreach ($extension in @($Extensions)) {
        if ([string]::IsNullOrWhiteSpace($extension)) { continue }
        $normalized = if ($extension.StartsWith('.')) { $extension.ToLowerInvariant() } else { ('.' + $extension.ToLowerInvariant()) }
        $allowed[$normalized] = $true
    }
    $ranked = New-Object System.Collections.Generic.List[object]
    foreach ($file in @($Files)) {
        if ($null -eq $file -or -not $file.FullName) { continue }
        $extension = [string]$file.Extension
        if ($allowed.Count -gt 0 -and -not $allowed.ContainsKey($extension.ToLowerInvariant())) { continue }
        $name = [string]$file.Name
        $path = [string]$file.FullName
        $excluded = $false
        foreach ($pattern in @($ExcludePatterns)) {
            if ($pattern -and ($name -match $pattern -or $path -match $pattern)) { $excluded = $true; break }
        }
        if ($excluded) { continue }
        $score = -1
        for ($index = 0; $index -lt $Patterns.Count; $index++) {
            $pattern = [string]$Patterns[$index]
            if (-not $pattern) { continue }
            if ($name -match $pattern) { $score = [Math]::Max($score, 2000 - ($index * 60)) }
            elseif ($path -match $pattern) { $score = [Math]::Max($score, 1000 - ($index * 40)) }
        }
        if ($score -lt 0) { continue }
        $depth = @($path -split '[\\/]').Count
        $ranked.Add([pscustomobject]@{ Path = $path; Score = $score; Depth = $depth; Length = [long]$file.Length })
    }
    $best = $ranked | Sort-Object -Property @{Expression={$_.Score};Descending=$true}, @{Expression={$_.Depth};Descending=$false}, @{Expression={$_.Length};Descending=$true}, @{Expression={$_.Path};Descending=$false} | Select-Object -First 1
    if ($null -eq $best) { return '' }
    return [string]$best.Path
}

function Find-ScienceScanFolder {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$Patterns
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return '' }
    $directories = @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -ErrorAction SilentlyContinue)
    foreach ($pattern in @($Patterns)) {
        $match = $directories | Where-Object { $_.Name -match $pattern -or $_.FullName -match $pattern } | Sort-Object { @($_.FullName -split '[\\/]').Count } | Select-Object -First 1
        if ($null -ne $match) { return [string]$match.FullName }
    }
    return ''
}

function Format-ScienceScanSummary {
    param([System.Collections.IDictionary]$Assignments)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($Assignments.Keys | Sort-Object)) {
        $value = [string]$Assignments[$key]
        if ([string]::IsNullOrWhiteSpace($value)) { $value = 'not found; select manually if required' }
        [void]$lines.Add("$key`: $value")
    }
    return ($lines -join "`r`n")
}

function Show-ScienceError([string]$Message) {
    [void][System.Windows.Forms.MessageBox]::Show($Message, 'Bacterial RNA Analysis', 'OK', 'Error')
}
function Show-ScienceInfo([string]$Message) {
    [void][System.Windows.Forms.MessageBox]::Show($Message, 'Bacterial RNA Analysis', 'OK', 'Information')
}

function New-ScienceButton([string]$Text, [switch]$Primary) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Height = 34
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.Font = $script:ScienceFontButton
    if ($Primary) {
        $button.BackColor = $script:ScienceGreen
        $button.ForeColor = [System.Drawing.Color]::White
        $button.FlatAppearance.BorderColor = $script:ScienceGreen
    } else {
        $button.BackColor = $script:ScienceSurface
        $button.ForeColor = $script:ScienceInk
        $button.FlatAppearance.BorderColor = $script:ScienceBorder
    }
    return $button
}

function New-ScienceHelpButton {
    param(
        [string]$Title,
        [string]$Message,
        [int]$Size = 24,
        [switch]$HoverOnly
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = '?'
    $button.Size = New-Object System.Drawing.Size($Size, $Size)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = $script:ScienceGreen
    $button.BackColor = $script:ScienceGreenSoft
    $button.ForeColor = $script:ScienceGreenDark
    $button.Font = New-Object System.Drawing.Font('Segoe UI', [single]9, [System.Drawing.FontStyle]::Bold)
    $button.TabStop = $true
    $button.AccessibleName = $Title
    $button.Cursor = [System.Windows.Forms.Cursors]::Help
    $roundHelpButton = {
        try {
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $path.AddEllipse(0, 0, ($button.Width - 1), ($button.Height - 1))
            $previousRegion = $button.Region
            $button.Region = New-Object System.Drawing.Region($path)
            if ($previousRegion) { $previousRegion.Dispose() }
            $path.Dispose()
        } catch { }
    }.GetNewClosure()
    $button.Add_SizeChanged($roundHelpButton)
    & $roundHelpButton
    if (-not $HoverOnly) {
        $showScienceInfo = ${function:Show-ScienceInfo}
        $button.Add_Click({ & $showScienceInfo ("$Title`r`n`r`n$Message") }.GetNewClosure())
    }
    $helpTip = New-Object System.Windows.Forms.ToolTip
    $helpTip.InitialDelay = 250; $helpTip.ReshowDelay = 100; $helpTip.AutoPopDelay = 30000; $helpTip.ShowAlways = $true
    $wrapped = [regex]::Replace($Message, '(.{1,75})(?:\s+|$)', '$1' + "`r`n")
    $helpTip.SetToolTip($button, $Title + "`r`n`r`n" + $wrapped)
    $button.Tag = $helpTip
    return $button
}

function New-ScienceOrganismComboBox {
    param([string]$InitialText = '')
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $combo.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::SuggestAppend
    $combo.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::ListItems
    $combo.IntegralHeight = $false
    $combo.DropDownHeight = 260
    $combo.DropDownWidth = 560
    $combo.MaxDropDownItems = 12
    $combo.Items.AddRange(@(
        'Escherichia coli K-12 MG1655 [taxid: 511145]',
        'Bacillus subtilis 168 [taxid: 224308]',
        'Pseudomonas aeruginosa PAO1 [taxid: 208964]',
        'Staphylococcus aureus NCTC 8325 [taxid: 93061]',
        'Mycobacterium tuberculosis H37Rv [taxid: 83332]',
        'Streptomyces coelicolor A3(2) [taxid: 100226]',
        'Amycolatopsis orientalis [taxid: 31958]',
        'Amycolatopsis mediterranei S699 [taxid: 713604]'
    ))
    $combo.Text = $InitialText
    Enable-ScienceNeutralComboBox $combo
    return $combo
}

function Get-ScienceTaxonId {
    param([string]$Value)
    $text = [string]$Value
    if ($text -match '(?i)^\s*other\s*/\s*more') {
        throw 'Use the Find more STRING organisms button, then type the exact supported numeric taxonomy ID here.'
    }
    if ($text -match '(?i)taxid\s*:\s*(\d+)') { return [string]$Matches[1] }
    if ($text.Trim() -match '^\d+$') { return $text.Trim() }
    throw 'Choose an organism from the list or enter a numeric NCBI/STRING taxonomy ID.'
}

function New-ScienceKeggOrganismComboBox {
    param([string]$InitialText = '')
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $combo.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::SuggestAppend
    $combo.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::ListItems
    $combo.IntegralHeight = $false
    $combo.DropDownHeight = 280
    $combo.DropDownWidth = 650
    $combo.MaxDropDownItems = 14
    $combo.Items.AddRange(@(
        'amys · Amycolatopsis sp. TNS106',
        'aori · Amycolatopsis orientalis',
        'eco · Escherichia coli K-12 MG1655',
        'bsu · Bacillus subtilis 168',
        'pae · Pseudomonas aeruginosa PAO1',
        'sau · Staphylococcus aureus N315',
        'mtu · Mycobacterium tuberculosis H37Rv',
        'sco · Streptomyces coelicolor A3(2)',
        'vch · Vibrio cholerae O1 El Tor N16961',
        'lmo · Listeria monocytogenes EGD-e',
        'cac · Clostridium acetobutylicum ATCC 824'
    ))
    $combo.Text = $InitialText
    Enable-ScienceNeutralComboBox $combo
    return $combo
}

function Get-ScienceKeggOrganismQuery {
    param([string]$Value)
    $text = [string]$Value
    if ($text -match '(?i)^\s*other\s*/\s*more') {
        throw 'Use the Find more KEGG organisms button, then type the exact KEGG organism code, scientific name, T number, or NCBI taxonomy ID here.'
    }
    if ($text -match '^\s*([A-Za-z][A-Za-z0-9]{2,5})\s*[·|]') { return [string]$Matches[1] }
    if ($text.Trim()) { return $text.Trim() }
    throw 'Choose a KEGG organism from the list, or enter a KEGG code, scientific name, T number, or NCBI taxonomy ID.'
}

function New-ScienceConsoleWorkspace {
    param([string]$Title='Status, actions, and live console',[int]$Height=330,[string]$InitialStatus='Ready.')
    $section=New-ScienceSection $Title $Height
    $section.Padding=New-Object System.Windows.Forms.Padding(12,24,12,8)
    $container=New-Object System.Windows.Forms.TableLayoutPanel
    $container.Dock='Fill';$container.ColumnCount=2;$container.RowCount=1
    [void]$container.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute',420)))
    [void]$container.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',100)))
    [void]$container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100)))
    $section.Controls.Add($container)
    $actions=New-Object System.Windows.Forms.Panel;$actions.Dock='Fill';$actions.AutoScroll=$false
    $container.Controls.Add($actions,0,0)
    $status=New-Object System.Windows.Forms.Label
    $status.Text=$InitialStatus;$status.AutoEllipsis=$false;$status.Font=$script:ScienceFontInputLabel
    $status.ForeColor=$script:ScienceGreenDark
    $progress=New-Object System.Windows.Forms.ProgressBar
    $detail=New-Object System.Windows.Forms.Label;$detail.Text='';$detail.Font=New-Object System.Drawing.Font('Segoe UI',9);$detail.ForeColor=$script:ScienceMuted
    $detailProgress=New-Object System.Windows.Forms.ProgressBar
    $stop=New-ScienceButton 'Stop current job';$stop.Tag='BRA_SCIENCE_STOP';$stop.Enabled=$false
    $library=New-ScienceButton 'Database library'
    $suite=try { Find-ScienceSuiteRoot $PSScriptRoot } catch { '' }
    $openLibrary=${function:Open-ScienceDatabaseLibrary}
    $library.Add_Click({if($suite){& $openLibrary $suite}}.GetNewClosure())
    $actions.Controls.AddRange(@($status,$progress,$detail,$detailProgress,$stop,$library))
    $console=New-Object System.Windows.Forms.RichTextBox
    $console.Dock='Fill';$console.ReadOnly=$true;$console.WordWrap=$false;$console.ScrollBars='Both'
    $console.Font=New-Object System.Drawing.Font('Consolas',9)
    $console.BackColor=[System.Drawing.Color]::White;$console.ForeColor=$script:ScienceInk
    $console.BorderStyle='FixedSingle';$container.Controls.Add($console,1,0)
    $workspace=[pscustomobject]@{Section=$section;Container=$container;ActionsPanel=$actions;Actions=$actions;Status=$status;Console=$console;Progress=$progress;Detail=$detail;DetailProgress=$detailProgress;Stop=$stop;Library=$library;Check=$null;Install=$null;Log=$null;Results=$null;Report=$null;Primary=$null;CancelPath='';Layout=$null}
    $console.Tag=$workspace
    $stop.Add_Click({if($workspace.CancelPath){[System.IO.File]::WriteAllText($workspace.CancelPath,'cancel');$stop.Enabled=$false;$detail.Text='Stopping this job safely...'}}.GetNewClosure())
    $layout={
        $w=[Math]::Max(340,$actions.ClientSize.Width-12);$gap=8;$half=[int](($w-$gap)/2);$third=[int](($w-2*$gap)/3)
        $status.SetBounds(0,0,$w,39);$progress.SetBounds(0,42,$w,9)
        $detail.SetBounds(0,54,$w,18);$detailProgress.SetBounds(0,74,$w,8)
        if($workspace.Check){$workspace.Check.SetBounds(0,88,$half,28)}
        if($workspace.Install){$workspace.Install.SetBounds($half+$gap,88,$w-$half-$gap,28)}
        $stop.SetBounds(0,122,$w,28)
        # Keep the scientific Run/Retrieve action above secondary file/library
        # actions so it remains visible even when a short high-DPI window clips
        # the bottom of the workspace.
        if($workspace.Primary){$workspace.Primary.SetBounds(0,156,$w,30)}
        if($workspace.Report){
            $library.SetBounds(0,192,$half,28)
            if($workspace.Log){$workspace.Log.SetBounds($half+$gap,192,$w-$half-$gap,28)}
            if($workspace.Results){$workspace.Results.SetBounds(0,226,$half,28)}
            $workspace.Report.SetBounds($half+$gap,226,$w-$half-$gap,28)
        } else {
            $library.SetBounds(0,192,$third,28)
            if($workspace.Log){$workspace.Log.SetBounds($third+$gap,192,$third,28)}
            if($workspace.Results){$workspace.Results.SetBounds(2*($third+$gap),192,$w-2*($third+$gap),28)}
        }
    }.GetNewClosure()
    $workspace.Layout=$layout;$actions.Add_SizeChanged($layout);& $layout
    return $workspace
}

function Add-ScienceConsoleAction {
    param($Workspace,[System.Windows.Forms.Button]$Button)
    $Button.Font=New-Object System.Drawing.Font('Segoe UI',9)
    if($Button.Text -match '^Check'){ $Workspace.Check=$Button;$Button.Text='Check environment' }
    elseif($Button.Text -match '^Install'){ $Workspace.Install=$Button;$Button.Text='Install or update' }
    elseif($Button.Text -match '^Open.*log'){ $Workspace.Log=$Button;$Button.Text='Open log file' }
    elseif($Button.Text -match '^Open.*report'){ $Workspace.Report=$Button;$Button.Text='Open interactive report' }
    elseif($Button.Text -match '^Open.*result'){ $Workspace.Results=$Button;$Button.Text='Open result folder' }
    else { $Workspace.Primary=$Button }
    [void]$Workspace.Actions.Controls.Add($Button)
    & $Workspace.Layout
    return $Button
}

function Invoke-ScienceManualWorkbook {
    param([string]$SuiteRoot,[string]$Profile,[System.Windows.Forms.TextBoxBase]$Console = $null)
    . (Join-Path $SuiteRoot 'Modules\Shared Downstream Components\App\manual_input_editor.ps1')
    $invokeBackend = ${function:Invoke-ScienceBackend}
    $runHelper = {
        param($action,$source,$destination)
        $null = & $invokeBackend -SuiteRoot $SuiteRoot -Arguments @('manual-workbook','--profile',$Profile,'--action',$action,'--workbook',$source,'--output-dir',$destination) -Console $Console
    }.GetNewClosure()
    return Show-BraInputWorkbook -Profile $Profile -ResourceDir (Join-Path $SuiteRoot 'Modules\Shared Downstream Components\Examples\Manual input workbooks') -RunHelper $runHelper -Owner $(if($Console){$Console.FindForm()}else{$null})
}

function Get-ScienceManualFile {
    param($Result, [string]$FileName)
    if ($null -eq $Result -or -not $Result.OutputDir) { return '' }
    $path = Join-Path ([string]$Result.OutputDir) $FileName
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return ''
}

function New-ScienceInputRow {
    param(
        [string]$Label,
        [string]$Value = '',
        [string]$Help = '',
        [ValidateSet('file','folder','text')][string]$Kind = 'text',
        [string]$Filter = 'All files (*.*)|*.*'
    )
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Height = 35
    $panel.Dock = [System.Windows.Forms.DockStyle]::Top
    $labelControl = New-Object System.Windows.Forms.Label
    $labelControl.Text = $Label
    $labelControl.Location = New-Object System.Drawing.Point(0, 7)
    $labelControl.Size = New-Object System.Drawing.Size(205, 23)
    $labelControl.Font = $script:ScienceFontInputLabel
    $box = New-Object System.Windows.Forms.TextBox
    $box.Text = $Value
    $box.Location = New-Object System.Drawing.Point(210, 5)
    $box.Size = New-Object System.Drawing.Size(620, 26)
    $box.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $panel.Controls.AddRange(@($labelControl, $box))
    $browse = $null
    if ($Kind -ne 'text') {
        $browse = New-ScienceButton 'Browse'
        $browse.Location = New-Object System.Drawing.Point(840, 3)
        $browse.Size = New-Object System.Drawing.Size(90, 30)
        $browse.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
        # GetNewClosure() executes in a dynamic module. Capture the picker
        # functions as scriptblocks so Browse remains callable from every
        # Scientific Expansion page (STRING, Pathway, Transcript and TU).
        $selectScienceFile = ${function:Select-ScienceFile}
        $selectScienceFolder = ${function:Select-ScienceFolder}
        if ($Kind -eq 'file') {
            $handler = { $value = & $selectScienceFile $Filter; if ($value) { $box.Text = $value } }.GetNewClosure()
            $browse.Add_Click($handler)
        } else {
            $handler = { $value = & $selectScienceFolder $Help; if ($value) { $box.Text = $value } }.GetNewClosure()
            $browse.Add_Click($handler)
        }
        $panel.Controls.Add($browse)
    }
    $tip = $script:ScienceToolTip
    if ($Help) {
        foreach ($control in @($labelControl, $box, $browse)) { if ($control) { $tip.SetToolTip($control, $Help) } }
    }
    return [pscustomobject]@{ Panel = $panel; Label = $labelControl; Box = $box; Browse = $browse; ToolTip = $tip }
}

function New-ScienceSection([string]$Title, [int]$Height = 160) {
    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = $Title
    $group.Dock = [System.Windows.Forms.DockStyle]::Top
    $group.Height = $Height
    $group.Padding = New-Object System.Windows.Forms.Padding(14, 24, 14, 10)
    $group.Font = $script:ScienceFontSection
    $group.ForeColor = $script:ScienceGreenDark
    $group.BackColor = $script:ScienceSurface
    return $group
}

function Invoke-ScienceBackend {
    param(
        [string]$SuiteRoot,
        [string[]]$Arguments,
        [System.Windows.Forms.TextBoxBase]$Console = $null
    )
    $backend = Join-Path $SuiteRoot 'Modules\Scientific Expansion\Backend\scientific_expansion.py'
    $runner = Join-Path $SuiteRoot 'Modules\Scientific Expansion\Backend\scientific_expansion_runner.ps1'
    if (-not (Test-Path -LiteralPath $backend -PathType Leaf)) { throw "Backend not found: $backend" }
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Runner not found: $runner" }
    # When opened from the proven 1.9.3 main suite, trust the exact distro it
    # already resolved. Only perform independent discovery for standalone use.
    $distro = if ($env:BACTERIAL_RNA_WSL_DISTRO) { [string]$env:BACTERIAL_RNA_WSL_DISTRO } else { '' }
    $runtime = Join-Path $SuiteRoot 'Modules\Shared Runtime\wsl_runtime.ps1'
    if (Test-Path -LiteralPath $runtime -PathType Leaf) {
        try {
            . $runtime
            if ($distro -and -not (Test-BraWslDistroRunnable $distro)) { $distro = '' }
            if (-not $distro) { $distro = Resolve-BraWslDistro -SuiteRoot $SuiteRoot -Purpose Core }
            if ($distro) { $env:BACTERIAL_RNA_WSL_DISTRO = [string]$distro; Save-BraWslDistroSelection -SuiteRoot $SuiteRoot -Distro $distro }
        } catch { }
    }
    if (-not $distro) {
        throw 'No WSL2 Linux distribution could be resolved. Ubuntu may still be installed; reopen the main suite so the shared WSL handoff can refresh the exact registered distribution name.'
    }
    $request = Join-Path $env:TEMP ('bra_science_' + [Guid]::NewGuid().ToString('N') + '.json')
    $cancelPath = $request + ".cancel"
    $payload = [ordered]@{ backend = $backend; arguments = @($Arguments); distro = $distro; cancel_path = $cancelPath }
    $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $request -Encoding UTF8
    try {
        if ($Console) {
            $displayArguments = @($Arguments | ForEach-Object {
                $value = [string]$_
                if ($value -match '\s|["'']') { '"' + $value.Replace('"','\"') + '"' } else { $value }
            })
            $Console.AppendText("Running:`r`n" + ($displayArguments -join ' ') + "`r`n`r`n")
        }
        # Read stdout and stderr concurrently without PowerShell event runspaces.
        # Poll completed .NET tasks on the UI thread so the console remains live
        # and native stderr is never shortened to an ErrorRecord summary.
        $command = "`$ProgressPreference = 'SilentlyContinue'; try { & '" + $runner.Replace("'", "''") + "' -RequestPath '" + $request.Replace("'", "''") + "'; exit `$LASTEXITCODE } catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }"
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = '-NoProfile -NonInteractive -OutputFormat Text -InputFormat Text -ExecutionPolicy Bypass -EncodedCommand ' + $encodedCommand
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        $transcript = New-Object System.Text.StringBuilder
        $disabled = New-Object System.Collections.ArrayList
        $workspace = if ($Console -and $Console.Tag -and $Console.Tag.PSObject.Properties['CancelPath']) { $Console.Tag } else { $null }
        if ($workspace) { $workspace.CancelPath=$cancelPath;$workspace.Stop.Enabled=$true;$workspace.Progress.Style='Marquee';$workspace.DetailProgress.Style='Marquee';$workspace.Detail.Text='Working — detailed output is shown in the console.' }
        $owner = if ($Console) { $Console.FindForm() } else { $null }
        $preventClose = [System.Windows.Forms.FormClosingEventHandler]{ param($sender, $eventArgs) $eventArgs.Cancel = $true }
        try {
            # DoEvents keeps the UI responsive; disable inputs/navigation to
            # prevent re-entrant runs or changing a run's fields mid-analysis.
            if ($owner) {
                $owner.Add_FormClosing($preventClose)
                $pending = New-Object System.Collections.Queue
                $pending.Enqueue($owner)
                while ($pending.Count) {
                    $control = $pending.Dequeue()
                    foreach ($child in $control.Controls) { $pending.Enqueue($child) }
                    if ($control -ne $Console -and $control.Tag -ne 'BRA_SCIENCE_STOP' -and ($control -is [System.Windows.Forms.ButtonBase] -or $control -is [System.Windows.Forms.ComboBox] -or $control -is [System.Windows.Forms.TextBoxBase] -or $control -is [System.Windows.Forms.NumericUpDown])) {
                        [void]$disabled.Add([pscustomobject]@{ Control = $control; Enabled = $control.Enabled })
                        $control.Enabled = $false
                    }
                }
            }
            [void]$process.Start()
            $stdoutTask = $process.StandardOutput.ReadLineAsync()
            $stderrTask = $process.StandardError.ReadLineAsync()
            while ($null -ne $stdoutTask -or $null -ne $stderrTask -or -not $process.HasExited) {
                foreach ($streamName in @('stdout', 'stderr')) {
                    $readTask = if ($streamName -eq 'stdout') { $stdoutTask } else { $stderrTask }
                    if ($null -ne $readTask -and $readTask.IsCompleted) {
                        $line = $readTask.GetAwaiter().GetResult()
                        $nextTask = $null
                        if ($null -ne $line) {
                            [void]$transcript.AppendLine([string]$line)
                            if ($Console -and -not $Console.IsDisposed) { $Console.AppendText([string]$line + "`r`n"); $Console.ScrollToCaret() }
                            $nextTask = if ($streamName -eq 'stdout') { $process.StandardOutput.ReadLineAsync() } else { $process.StandardError.ReadLineAsync() }
                        }
                        if ($streamName -eq 'stdout') { $stdoutTask = $nextTask } else { $stderrTask = $nextTask }
                    }
                }
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 15
            }
            $process.WaitForExit()
            $code = [int]$process.ExitCode
            $text = $transcript.ToString()
        } finally {
            if ($owner -and -not $owner.IsDisposed) { $owner.Remove_FormClosing($preventClose) }
            foreach ($item in $disabled) { if (-not $item.Control.IsDisposed) { $item.Control.Enabled = $item.Enabled } }
            if ($workspace) { $workspace.Stop.Enabled=$false;$workspace.CancelPath='';$workspace.Progress.Style='Blocks';$workspace.DetailProgress.Style='Blocks';$workspace.Progress.Value=0;$workspace.DetailProgress.Value=0;$workspace.Detail.Text='Job stopped.' }
            $process.Dispose()
        }
        if ($code -eq 130) { throw 'Job cancelled by user.' }
        if ($code -ne 0) {
            $scientificMessage = ''
            try {
                $matches = [regex]::Matches($text, '(?ms)^\{\s*"status"\s*:\s*"error".*?^\}')
                if ($matches.Count -gt 0) {
                    $payload = $matches[$matches.Count - 1].Value | ConvertFrom-Json -ErrorAction Stop
                    if ($payload.message) { $scientificMessage = [string]$payload.message }
                }
            } catch { }
            if ($scientificMessage) { throw $scientificMessage }
            throw "Scientific expansion backend exited with code $code.`r`n`r`n$text"
        }
        if ($workspace) { $workspace.Progress.Value=100;$workspace.DetailProgress.Value=100;$workspace.Detail.Text='Completed.' }
        return $text
    }
    finally {
        try { Remove-Item -LiteralPath $request,$cancelPath -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Open-ScienceDatabaseLibrary([string]$SuiteRoot) {
    $distro = if ($env:BACTERIAL_RNA_WSL_DISTRO) { [string]$env:BACTERIAL_RNA_WSL_DISTRO } else { '' }
    $runtime = Join-Path $SuiteRoot 'Modules\Shared Runtime\wsl_runtime.ps1'
    if (Test-Path -LiteralPath $runtime -PathType Leaf) {
        try {
            . $runtime
            if ($distro -and -not (Test-BraWslDistroRunnable $distro)) { $distro = '' }
            if (-not $distro) { $distro = Resolve-BraWslDistro -SuiteRoot $SuiteRoot -Purpose Core }
        } catch { }
    }
    if (-not $distro) { Show-ScienceError 'No runnable WSL2 Linux distribution was found, so the shared Database Library cannot be opened yet.'; return }
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

        $primary = "\\wsl.localhost\$distro\root\.local\share\prok-rnaseq\Database Library"
        $fallback = "\\wsl$\$distro\root\.local\share\prok-rnaseq\Database Library"
        $opened = $false
        foreach ($candidate in @($primary, $fallback)) {
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
        Show-ScienceError ("Could not open the shared Database Library.`r`nLinux path: {0}`r`nWSL distribution: {1}`r`n`r`n{2}" -f $linuxPath, $distro, $_.Exception.Message)
    }
}

function New-ScienceModuleHost([string]$Title, [string]$Subtitle, [string]$BackText = '< Back') {
    $embedded = $false
    $rootHost = $null
    $form = $null
    try {
        $candidate = Get-Variable -Name BacterialRNAAnalysisEmbeddedHost -Scope Global -ValueOnly -ErrorAction Stop
        if ($candidate -is [System.Windows.Forms.Control]) { $rootHost = $candidate; $embedded = $true }
    } catch { }
    if (-not $embedded) {
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Bacterial RNA Analysis - ' + $Title
        $form.StartPosition = 'CenterScreen'
        $form.Size = New-Object System.Drawing.Size(1220, 860)
        $form.MinimumSize = New-Object System.Drawing.Size(1050, 760)
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
        $form.BackColor = $script:ScienceBackground
        $rootHost = $form
    }
    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = [System.Windows.Forms.DockStyle]::Fill
    $root.ColumnCount = 1
    $root.RowCount = 2
    [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $root.BackColor = $script:ScienceBackground
    $root.Padding = New-Object System.Windows.Forms.Padding(20)
    $rootHost.Controls.Add($root)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Fill
    $header.Margin = New-Object System.Windows.Forms.Padding(0)
    $header.Height = 82
    $header.BackColor = $script:ScienceSurface
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Location = New-Object System.Drawing.Point(18, 10)
    $titleLabel.AutoSize = $false
    $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]17, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = $script:ScienceGreenDark
    $subtitleLabel = New-Object System.Windows.Forms.Label
    $subtitleLabel.Text = $Subtitle
    $subtitleLabel.Location = New-Object System.Drawing.Point(20, 46)
    $subtitleLabel.AutoSize = $false
    $subtitleLabel.Size = New-Object System.Drawing.Size(980, 36)
    $subtitleLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $subtitleLabel.ForeColor = $script:ScienceMuted
    $subtitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]9.5)
    $back = New-ScienceButton $BackText
    $back.Size = New-Object System.Drawing.Size(190, 34)
    $back.Location = New-Object System.Drawing.Point(955, 20)
    $back.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $library = New-ScienceButton 'Database library'
    $library.Size = New-Object System.Drawing.Size(150, 34)
    $library.Location = New-Object System.Drawing.Point(795, 20)
    $library.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $suiteForLibrary = try { Find-ScienceSuiteRoot $PSScriptRoot } catch { '' }
    $openScienceDatabaseLibrary = ${function:Open-ScienceDatabaseLibrary}
    $showScienceErrorForLibrary = ${function:Show-ScienceError}
    $library.Add_Click({ if ($suiteForLibrary) { & $openScienceDatabaseLibrary $suiteForLibrary } else { & $showScienceErrorForLibrary 'Suite root could not be resolved.' } }.GetNewClosure())
    $header.Controls.AddRange(@($titleLabel, $subtitleLabel, $library, $back))
    $headerLayoutState = [pscustomobject]@{ Busy = $false }
    $layoutHeader = {
        if ($headerLayoutState.Busy) { return }
        $headerLayoutState.Busy = $true
        try {
            $available = [Math]::Max(300, $header.ClientSize.Width - 40)
            $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
            $titleLabel.Width = $available
            $titleMeasure = [System.Windows.Forms.TextRenderer]::MeasureText($titleLabel.Text,$titleLabel.Font,(New-Object System.Drawing.Size($available,500)),$flags)
            $titleLabel.Height = $titleMeasure.Height + 4
            $subtitleLabel.Width = $available
            $subtitleLabel.Top = $titleLabel.Bottom + 3
            $measured = [System.Windows.Forms.TextRenderer]::MeasureText($subtitleLabel.Text,$subtitleLabel.Font,(New-Object System.Drawing.Size($available,500)),$flags)
            $subtitleLabel.Height = [Math]::Max(24,$measured.Height + 4)
            $buttonY = $subtitleLabel.Bottom + 6
            $buttonX = 18
            $buttons = @($header.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Visible } | Sort-Object @{ Expression = { if ($_.Text -eq 'Instructions') { 0 } elseif ($_ -eq $library) { 1 } elseif ($_ -eq $back) { 3 } else { 2 } } })
            $totalWidth=0;foreach($button in $buttons){$totalWidth += $button.Width+8}
            $buttonX=[Math]::Max(18,$header.ClientSize.Width-$totalWidth-10)
            foreach ($button in $buttons) {
                $button.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
                if ($buttonX + $button.Width -gt $header.ClientSize.Width - 18 -and $buttonX -gt 18) { $buttonX = 18; $buttonY += 40 }
                $button.Location = New-Object System.Drawing.Point($buttonX, $buttonY)
                $buttonX += $button.Width + 8
            }
            $root.RowStyles[0].Height = $buttonY + 42
        } finally { $headerLayoutState.Busy = $false }
    }.GetNewClosure()
    $header.Add_SizeChanged($layoutHeader)
    $header.Add_ControlAdded($layoutHeader)
    $root.Controls.Add($header, 0, 0)

    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = [System.Windows.Forms.DockStyle]::Fill
    $body.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $body.Margin = New-Object System.Windows.Forms.Padding(0)
    $body.AutoScroll = $true
    $root.Controls.Add($body, 0, 1)
    & $layoutHeader

    # Child modules add dozens of WinForms controls after this function returns.
    # Suspend layout while those controls are constructed, then resume once just
    # before first paint. This avoids repeated full-page layout passes.
    # Paint the module shell immediately, then suspend only the body while its
    # controls are populated. This removes the blank pause perceived on open.
    if ($embedded) { try { $root.BringToFront(); [System.Windows.Forms.Application]::DoEvents() } catch { } }
    $body.SuspendLayout()

    $state = [pscustomobject]@{ Closed = $false }
    $backHandler = { $state.Closed = $true; if ($form) { $form.Close() } }.GetNewClosure()
    $back.Add_Click($backHandler)
    return [pscustomobject]@{ Embedded = $embedded; Form = $form; Root = $root; Body = $body; Back = $back; Library = $library; State = $state }
}

function Show-ScienceModuleHost($HostObject) {
    # Keep the live console usable on short windows. The complete form scrolls
    # only when its input rows and a 260px console cannot fit; otherwise the
    # console receives all remaining height. No fixed blank header spacer.
    $body = $HostObject.Body
    $page = $body.Controls | Where-Object { $_ -is [System.Windows.Forms.TableLayoutPanel] } | Select-Object -First 1
    if ($page) {
        $fixedHeight = 0
        foreach ($row in $page.RowStyles) { if ($row.SizeType -eq [System.Windows.Forms.SizeType]::Absolute) { $fixedHeight += $row.Height } }
        $pageMinimumHeight = [int]($fixedHeight + 275)
        $page.Dock = [System.Windows.Forms.DockStyle]::None
        $page.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
        $body.AutoScroll = $true
        $layoutPage = {
            $width = [Math]::Max(1000, $body.ClientSize.Width - 20)
            $height = [Math]::Max($pageMinimumHeight, $body.ClientSize.Height - 12)
            $page.Size = New-Object System.Drawing.Size($width, $height)
            $body.AutoScrollMinSize = New-Object System.Drawing.Size($width, ($height + 8))
        }.GetNewClosure()
        $body.Add_SizeChanged($layoutPage)
        & $layoutPage
    }
    try { $HostObject.Body.ResumeLayout($false); $HostObject.Body.PerformLayout() } catch { }
    # First paint should happen immediately. The neutral ComboBox/DataGridView
    # styling is cosmetic and can be applied after the host is already visible;
    # doing the recursive walk synchronously made the prediction modules feel
    # much slower to open than the original suite pages.
    $themeAction = [System.Windows.Forms.MethodInvoker]{
        try { Apply-ScienceNeutralSelectionTheme $HostObject.Root } catch { }
    }.GetNewClosure()
    if ($HostObject.Embedded) {
        $HostObject.Root.BringToFront()
        try { [void]$HostObject.Root.BeginInvoke($themeAction) } catch { }
        while (-not $HostObject.State.Closed -and -not $HostObject.Root.IsDisposed) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 25
        }
        try { $HostObject.Root.Parent.Controls.Remove($HostObject.Root) } catch { }
        try { $HostObject.Root.Dispose() } catch { }
    } else {
        $shownHandler = { try { [void]$HostObject.Form.BeginInvoke($themeAction) } catch { } }.GetNewClosure()
        $HostObject.Form.Add_Shown($shownHandler)
        [void]$HostObject.Form.ShowDialog()
        try { $HostObject.Form.Dispose() } catch { }
    }
}
