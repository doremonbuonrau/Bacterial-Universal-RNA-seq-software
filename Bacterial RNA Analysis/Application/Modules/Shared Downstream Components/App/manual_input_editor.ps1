# Native, in-memory workbook editor. Excel is only written on explicit export.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
if (-not ('BacterialRNAAnalysis.ManualWorkbookGrid' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'manual_input_grid.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing
}

function Show-BraInputWorkbook {
    param([string]$Profile, [string]$ResourceDir, [scriptblock]$RunHelper, [System.Windows.Forms.IWin32Window]$Owner = $null)
    $resource = Join-Path $ResourceDir ($Profile + '.json')
    if (-not (Test-Path -LiteralPath $resource)) { throw "Input workbook reference not found: $resource" }
    if (-not (Get-Variable -Name BraInputDrafts -Scope Global -ErrorAction SilentlyContinue)) { $global:BraInputDrafts = @{} }
    $schema = Get-Content -LiteralPath $resource -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($global:BraInputDrafts.ContainsKey($Profile)) {
        # Keep current examples/descriptions even when reopening an older draft.
        $draft = $global:BraInputDrafts[$Profile] | ConvertFrom-Json
        foreach ($sheet in $schema.sheets) {
            $saved = @($draft.sheets | Where-Object { $_.name -eq $sheet.name })
            if ($saved.Count) { $sheet.headers = $saved[0].headers; $sheet.rows = $saved[0].rows }
        }
    }
    $state = [pscustomobject]@{ Result = $null; Schema = $schema; Grids = @{}; Busy = $false }
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $schema.title + ' (named columns)'
    $dialog.StartPosition = 'CenterParent'
    $dialog.Size = New-Object System.Drawing.Size(1120, 740)
    $dialog.MinimumSize = New-Object System.Drawing.Size(860, 560)
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $dialog.BackColor = [System.Drawing.Color]::White
    $dialog.AutoScaleMode = 'Dpi'
    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'; $root.ColumnCount = 1; $root.RowCount = 4
    [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',100)))
    foreach ($row in @(@('Absolute',58),@('Percent',100),@('Absolute',34),@('Absolute',50))) { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($row[0],[single]$row[1]))) }
    $root.Padding = New-Object System.Windows.Forms.Padding(12)
    $dialog.Controls.Add($root)
    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = 'Ctrl+V pastes data; Ctrl+Shift+V pastes with column names. Double-click a column name to rename it. For DE, Add treatment group creates replicate columns and matching metadata rows. Pale italic examples are display-only.'
    $intro.Dock = 'Fill'; $intro.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#2A5534')
    $root.Controls.Add($intro,0,0)
    $dataTabs = New-Object System.Windows.Forms.TabControl; $dataTabs.Dock = 'Fill'; $dataTabs.Multiline = $true
    $root.Controls.Add($dataTabs,0,1)
    $feedback = New-Object System.Windows.Forms.Label
    $feedback.Dock = 'Fill'; $feedback.Text = 'Draft stays in this application session. Required sheets are marked *.'
    $root.Controls.Add($feedback,0,2)
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Fill'; $buttons.WrapContents = $false; $buttons.AutoScroll = $true
    $root.Controls.Add($buttons,0,3)
    $makeButton = { param($text) $b = New-Object System.Windows.Forms.Button; $b.Text=$text; $b.AutoSize=$true; $b.Height=34; $b.MinimumSize=New-Object System.Drawing.Size(110,34); $b.FlatStyle='Flat'; $b.Margin=New-Object System.Windows.Forms.Padding(0,3,8,0); [void]$buttons.Controls.Add($b); return $b }.GetNewClosure()
    $use = & $makeButton 'Use data'; $use.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#2A5534'); $use.ForeColor=[System.Drawing.Color]::White
    $export = & $makeButton 'Export workbook'
    $import = & $makeButton 'Import workbook'
    $addColumn = & $makeButton 'Add column'
    $addTreatment = & $makeButton 'Add treatment group'
    $addTreatment.Visible = ([string]$Profile -eq 'de')
    $showExamplePlaceholders = New-Object System.Windows.Forms.CheckBox
    $showExamplePlaceholders.Text = 'Show pale examples in empty cells'
    $showExamplePlaceholders.Checked = $true
    $showExamplePlaceholders.AutoSize = $true
    $showExamplePlaceholders.Margin = New-Object System.Windows.Forms.Padding(8,10,12,0)
    [void]$buttons.Controls.Add($showExamplePlaceholders)
    $close = & $makeButton 'Close'
    $loadGrid = {
        param($grid, $headers, $rows, $definition)
        $grid.SuspendLayout()
        try {
            $grid.ResetSheet([string[]]@($headers), [Math]::Max(@($rows).Count, @($definition.example_rows).Count))
            $index = 0
            foreach ($row in @($definition.example_rows)) { $grid.SetExampleRow($index, [string[]]@($row)); $index++ }
            $index = 0
            foreach ($row in @($rows)) { $grid.SetDataRow($index, [string[]]@($row)); $index++ }
            $grid.ShowExamples = $showExamplePlaceholders.Checked
            $grid.FinishLoading()
        } finally { $grid.ResumeLayout($true) }
    }.GetNewClosure()
    $paste = {
        param($grid, [bool]$includesHeaders = $false)
        if($grid.ReadOnly) { return }
        $text=[System.Windows.Forms.Clipboard]::GetText()
        if(-not $text) { return }
        [void]$grid.EndEdit()
        $reader=New-Object System.IO.StringReader($text)
        $parser=New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($reader)
        $parser.TextFieldType='Delimited';$parser.SetDelimiters("`t");$parser.HasFieldsEnclosedInQuotes=$true;$parser.TrimWhiteSpace=$false
        $rows=New-Object System.Collections.ArrayList
        try { while(-not $parser.EndOfData) { [void]$rows.Add([object[]]$parser.ReadFields()) } } finally { $parser.Close();$reader.Dispose() }
        if(-not $rows.Count) { return }
        $rowIndex=if($grid.CurrentCell){$grid.CurrentCell.RowIndex}else{0}
        $colIndex=if($grid.CurrentCell){$grid.CurrentCell.ColumnIndex}else{0}
        # Recognise ordinary complete worksheet headers for Ctrl+V as well.
        # Ctrl+Shift+V explicitly handles renamed/custom headers.
        if(-not $includesHeaders -and $rowIndex -eq 0 -and $colIndex -eq 0) {
            $first=[string]$rows[0][0]
            $definition=@($state.Schema.sheets | Where-Object { $_.name -eq [string]$grid.Tag })[0]
            $includesHeaders=($first -eq [string]$grid.Columns[0].HeaderText -or $first -eq [string]$definition.headers[0])
        }
        $width=$colIndex
        foreach($row in $rows) { $width=[Math]::Max($width,$colIndex+$row.Count) }
        if($includesHeaders -and $rowIndex -eq 0 -and $colIndex -eq 0 -and $grid.GetInputRows().Length -eq 0) {
            # A complete paste into an untouched template defines its columns;
            # don't retain unused template samples. Never remove real data.
            while($grid.Columns.Count -gt $width) { $grid.Columns.RemoveAt($grid.Columns.Count-1) }
        }
        while($grid.Columns.Count -lt $width) { $grid.AddInputColumn('column_'+($grid.Columns.Count+1)) }
        $grid.SuspendLayout()
        try {
            if($includesHeaders) {
                for($col=0;$col -lt $rows[0].Count;$col++) { $grid.Columns[$colIndex+$col].HeaderText=[string]$rows[0][$col] }
                $rows.RemoveAt(0)
            }
            foreach($row in $rows) {
                $grid.EnsureDataRows($rowIndex+1)
                for($col=0;$col -lt $row.Count;$col++) {
                    $cell=$grid.Rows[$rowIndex].Cells[$colIndex+$col]
                    $cell.Value=[string]$row[$col]
                }
                $rowIndex++
            }
        } finally { $grid.ResumeLayout() }
        $feedback.Text="Pasted $($rows.Count) data rows. Double-click a column name to rename it."
    }.GetNewClosure()
    foreach($sheet in $schema.sheets) {
        $page = New-Object System.Windows.Forms.TabPage
        $page.Text=$sheet.name+$(if($sheet.required){' *'}else{''})
        $page.Tag=$sheet.name
        $hint=New-Object System.Windows.Forms.Label;$hint.Dock='Top';$hint.Height=48;$hint.Text=$sheet.description
        $grid=New-Object BacterialRNAAnalysis.ManualWorkbookGrid
        $grid.Tag=$sheet.name
        $grid.Dock='Fill';$grid.ReadOnly=$false
        $grid.Add_KeyDown({param($sender,$eventArgs) if($eventArgs.Control -and $eventArgs.KeyCode -eq 'V'){ try { & $paste $sender ([bool]$eventArgs.Shift) } catch { $feedback.Text=$_.Exception.Message };$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true } }.GetNewClosure())
        $grid.Add_ColumnHeaderMouseDoubleClick({
            param($sender,$eventArgs)
            if($eventArgs.ColumnIndex -lt 0) { return }
            $column=$sender.Columns[$eventArgs.ColumnIndex]
            $name=[Microsoft.VisualBasic.Interaction]::InputBox('Enter the field or sample name.','Rename column',[string]$column.HeaderText)
            if(-not [string]::IsNullOrWhiteSpace($name)) { $column.HeaderText=$name.Trim() }
        }.GetNewClosure())
        $page.Controls.Add($grid);$page.Controls.Add($hint)
        [void]$dataTabs.TabPages.Add($page);$state.Grids[$sheet.name]=$grid
        & $loadGrid $grid $sheet.headers $sheet.rows $sheet
    }
    $showExamplePlaceholders.Add_CheckedChanged({foreach($grid in $state.Grids.Values){$grid.ShowExamples=$showExamplePlaceholders.Checked}}.GetNewClosure())
    $snapshot = {
        foreach($sheet in $state.Schema.sheets) {
            $grid=$state.Grids[$sheet.name];[void]$grid.EndEdit()
            $sheet.headers=$grid.GetInputHeaders();$sheet.rows=$grid.GetInputRows()
        }
        return ($state.Schema | ConvertTo-Json -Depth 12 -Compress)
    }.GetNewClosure()
    $invokeAction = {
        param([string]$action,[string]$destination,[string]$source='')
        $state.Busy=$true;$buttons.Enabled=$false;$dataTabs.Enabled=$false;$dialog.UseWaitCursor=$true
        $temp=Join-Path ([System.IO.Path]::GetTempPath()) ('bra-input-'+[Guid]::NewGuid().ToString('N')+'.json')
        try {
            [System.IO.File]::WriteAllText($temp,(& $snapshot),(New-Object System.Text.UTF8Encoding($false)))
            if(-not $source){$source=$temp}
            & $RunHelper $action $source $destination | Out-Null
        } finally {Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue;$state.Busy=$false;$buttons.Enabled=$true;$dataTabs.Enabled=$true;$dialog.UseWaitCursor=$false}
    }.GetNewClosure()
    $use.Add_Click({
        try {
            $inputRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'BacterialRNAAnalysis\Manual inputs'
            $output=Join-Path $inputRoot ($Profile+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
            & $invokeAction 'editor-use' $output
            $state.Result=[pscustomobject]@{Profile=$Profile;OutputDir=$output;Workbook=(Join-Path $output 'manual_input_manifest.json')}
            $dialog.Close()
        } catch { $feedback.Text='Input validation failed.';[void][System.Windows.Forms.MessageBox]::Show($dialog,$_.Exception.Message,'Check your input','OK','Warning') }
    }.GetNewClosure())
    $export.Add_Click({
        $save=New-Object System.Windows.Forms.SaveFileDialog;$save.Filter='Excel workbook (*.xlsx)|*.xlsx';$save.FileName='Manual '+$Profile+' input.xlsx'
        if($save.ShowDialog($dialog) -ne 'OK'){return}
        try { & $invokeAction 'editor-export' $save.FileName;$feedback.Text='Exported the editable input sheets to '+$save.FileName } catch {[void][System.Windows.Forms.MessageBox]::Show($dialog,$_.Exception.Message,'Export failed')}
    }.GetNewClosure())
    $import.Add_Click({
        $pick=New-Object System.Windows.Forms.OpenFileDialog;$pick.Filter='Excel workbook (*.xlsx;*.xlsm)|*.xlsx;*.xlsm'
        if($pick.ShowDialog($dialog) -ne 'OK'){return}
        $temp=Join-Path ([System.IO.Path]::GetTempPath()) ('bra-import-'+[Guid]::NewGuid().ToString('N')+'.json')
        try { & $invokeAction 'editor-import' $temp $pick.FileName;$data=Get-Content -LiteralPath $temp -Raw -Encoding UTF8 | ConvertFrom-Json;foreach($sheet in $data.sheets){$definition=@($state.Schema.sheets|Where-Object{[string]$_.name -eq [string]$sheet.name})[0];$grid=$state.Grids[$sheet.name];& $loadGrid $grid $sheet.headers $sheet.rows $definition};$feedback.Text='Imported '+$pick.FileName } catch {[void][System.Windows.Forms.MessageBox]::Show($dialog,$_.Exception.Message,'Import failed')} finally {Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
    }.GetNewClosure())
    $addColumn.Add_Click({
        $grid=$state.Grids[[string]$dataTabs.SelectedTab.Tag]
        $name=[Microsoft.VisualBasic.Interaction]::InputBox('Enter the field or sample name.','Add column',('column_'+($grid.Columns.Count+1)))
        if([string]::IsNullOrWhiteSpace($name)) { return }
        $grid.AddInputColumn($name.Trim());$grid.EnsureDataRows(1)
        $grid.CurrentCell=$grid.Rows[0].Cells[$grid.Columns.Count-1]
    }.GetNewClosure())
    $addTreatment.Add_Click({
        $counts=$state.Grids['Raw counts'];$metadata=$state.Grids['Sample metadata']
        if(-not $counts -or -not $metadata) {$feedback.Text='This input profile does not contain the DE count and sample-metadata sheets.';return}
        $metadataHeaders=[string[]]@($metadata.GetInputHeaders());$sampleIndex=-1;$conditionIndex=-1
        for($columnIndex=0;$columnIndex -lt $metadataHeaders.Length;$columnIndex++) {if($metadataHeaders[$columnIndex] -ieq 'sample_id'){$sampleIndex=$columnIndex};if($metadataHeaders[$columnIndex] -ieq 'condition'){$conditionIndex=$columnIndex}}
        if($sampleIndex -lt 0 -or $conditionIndex -lt 0) {[void][System.Windows.Forms.MessageBox]::Show($dialog,'The Sample metadata sheet must contain columns named sample_id and condition before a treatment group can be added.','Required metadata columns','OK','Warning');return}
        $existingGroups=@()
        foreach($header in $counts.GetInputHeaders()) {if([string]$header -match '^(.+?)[_-][0-9]+$'){$existingGroups+=([string]$Matches[1]).Trim()}}
        foreach($row in $metadata.GetInputRows()) {if($row.Length -gt $conditionIndex -and -not [string]::IsNullOrWhiteSpace([string]$row[$conditionIndex])){$existingGroups+=([string]$row[$conditionIndex]).Trim()}}
        $number=2;while($existingGroups -contains ('Treatment'+$number)){$number++}
        $condition=[Microsoft.VisualBasic.Interaction]::InputBox('Enter the new treatment / condition name. Replicate sample columns will be named from this value.','Add treatment group',('Treatment'+$number))
        if([string]::IsNullOrWhiteSpace($condition)){return};$condition=$condition.Trim()
        if($condition -match "[`t`r`n]") {[void][System.Windows.Forms.MessageBox]::Show($dialog,'Treatment names cannot contain tabs or line breaks.','Check treatment name','OK','Warning');return}
        if($existingGroups -contains $condition) {[void][System.Windows.Forms.MessageBox]::Show($dialog,"A treatment / condition named '$condition' already exists. Use Add column for another replicate, or enter a different treatment name.",'Treatment already exists','OK','Warning');return}
        $replicateText=[Microsoft.VisualBasic.Interaction]::InputBox('How many replicate sample columns should be created?','Add treatment group','3')
        if([string]::IsNullOrWhiteSpace($replicateText)){return};$replicateCount=0
        if(-not [int]::TryParse($replicateText,[ref]$replicateCount) -or $replicateCount -lt 1 -or $replicateCount -gt 96) {[void][System.Windows.Forms.MessageBox]::Show($dialog,'Enter a whole-number replicate count from 1 to 96.','Check replicate count','OK','Warning');return}
        $existingSamples=[string[]]@($counts.GetInputHeaders())
        $sampleNames=@()
        for($replicate=1;$replicate -le $replicateCount;$replicate++) {$candidate=$condition+'_'+$replicate;if($existingSamples -contains $candidate){[void][System.Windows.Forms.MessageBox]::Show($dialog,"The sample column '$candidate' already exists. Rename the treatment or the existing sample before trying again.",'Sample name already exists','OK','Warning');return};$sampleNames+=$candidate}
        $counts.SuspendLayout();$metadata.SuspendLayout()
        try {
            foreach($sampleName in $sampleNames) {
                $counts.AddInputColumn($sampleName)
                $values=New-Object string[] $metadataHeaders.Length;$values[$sampleIndex]=$sampleName;$values[$conditionIndex]=$condition
                [void]$metadata.AppendInputRow($values)
            }
            $counts.EnsureDataRows(1);$metadata.EnsureDataRows(1)
        } finally {$counts.ResumeLayout($true);$metadata.ResumeLayout($true)}
        $dataTabs.SelectedTab = @($dataTabs.TabPages|Where-Object{[string]$_.Tag -eq 'Raw counts'})[0]
        $counts.CurrentCell=$counts.Rows[0].Cells[$counts.Columns.Count-1]
        $feedback.Text="Added treatment '$condition' with $replicateCount replicate sample column$(if($replicateCount -eq 1){''}else{'s'}) and matching metadata row$(if($replicateCount -eq 1){''}else{'s'})."
    }.GetNewClosure())
    $close.Add_Click({$dialog.Close()}.GetNewClosure())
    $dialog.Add_FormClosing({param($sender,$eventArgs) if($state.Busy){$eventArgs.Cancel=$true;return};$global:BraInputDrafts[$Profile]=& $snapshot}.GetNewClosure())
    if($Owner){[void]$dialog.ShowDialog($Owner)}else{[void]$dialog.ShowDialog()}
    $dialog.Dispose()
    return $state.Result
}
