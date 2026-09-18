# Run with Windows PowerShell, no WSL or analysis environment required:
# powershell.exe -NoProfile -STA -File .\Test-ManualInputEditor.ps1
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run this test with powershell.exe -STA.' }
$shared = Split-Path $PSScriptRoot -Parent
$editorPath = Join-Path $shared 'App\manual_input_editor.ps1'
$parseTokens = $null; $parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($editorPath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
. $editorPath
[Windows.Forms.Application]::EnableVisualStyles()
function Assert-Grid($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$sheetsTested = 0
foreach ($path in Get-ChildItem -LiteralPath (Join-Path $shared 'Examples\Manual input workbooks') -Filter '*.json') {
    $schema = Get-Content -LiteralPath $path.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($sheet in $schema.sheets) {
        $window = New-Object Windows.Forms.Form
        $window.Text = 'First-open grid check - no mouse input'
        $window.ClientSize = New-Object Drawing.Size(950,520)
        $window.StartPosition = 'CenterScreen'
        $grid = New-Object BacterialRNAAnalysis.ManualWorkbookGrid
        $grid.Font = New-Object Drawing.Font('Segoe UI',10)
        $grid.Dock = 'Fill'
        $window.Controls.Add($grid)
        $withExamples = $null; $withoutExamples = $null
        try {
            $grid.ResetSheet([string[]]$sheet.headers, @($sheet.example_rows).Count)
            $i = 0
            foreach ($row in $sheet.example_rows) { $grid.SetExampleRow($i,[string[]]$row); $i++ }
            $grid.FinishLoading()
            # No CellPainting/RowPostPaint script callbacks and no simulated
            # mouse, focus change, tab change or delayed refresh workaround.
            $window.Show()
            [Windows.Forms.Application]::DoEvents()
            Assert-Grid ($grid.DataRowCount -ge [Math]::Max(12,@($sheet.example_rows).Count)) 'Example rows were not allocated on opening.'
            Assert-Grid ($grid.Columns[0].HeaderText -ceq [string]$sheet.headers[0]) 'Column header is not the field name.'
            Assert-Grid ($grid.GetInputRows().Length -eq 0) 'Untouched examples became input data.'
            Assert-Grid ([string]$grid.Rows[0].HeaderCell.Value -eq '1') 'First data row is not row 1.'
            Assert-Grid ([string]$grid.Rows[0].Cells[0].FormattedValue -ceq [string]$sheet.example_rows[0][0]) 'First example is missing.'
            $withExamples = New-Object Drawing.Bitmap($grid.Width,$grid.Height)
            $grid.DrawToBitmap($withExamples,$grid.ClientRectangle)
            $grid.ShowExamples = $false
            Assert-Grid ([string]::IsNullOrEmpty([string]$grid.Rows[0].Cells[0].FormattedValue)) 'Example toggle did not hide display text.'
            $withoutExamples = New-Object Drawing.Bitmap($grid.Width,$grid.Height)
            $grid.DrawToBitmap($withoutExamples,$grid.ClientRectangle)
            $bounds = $grid.GetCellDisplayRectangle(0,0,$false)
            $different = 0
            for($y=$bounds.Top+3;$y -lt $bounds.Bottom-3;$y++) {
                for($x=$bounds.Left+3;$x -lt $bounds.Right-3;$x++) {
                    if($withExamples.GetPixel($x,$y).ToArgb() -ne $withoutExamples.GetPixel($x,$y).ToArgb()) { $different++ }
                }
            }
            Assert-Grid ($different -gt 10) 'Example text did not paint in the first cell.'
            $grid.ShowExamples = $true
            $grid.SelectAll()
            $clip = $grid.GetClipboardContent()
            $copied = [string]$clip.GetData([Windows.Forms.DataFormats]::UnicodeText)
            Assert-Grid (-not $copied.Contains([string]$sheet.example_rows[0][0])) 'Clipboard included an untouched example.'
            $grid.CurrentCell = $grid.Rows[0].Cells[0]
            [void]$grid.BeginEdit($false)
            Assert-Grid ([string]::IsNullOrEmpty($grid.EditingControl.Text)) 'Editing starts with example data.'
            [void]$grid.EndEdit()
            Assert-Grid ($grid.GetInputRows().Length -eq 0) 'Starting and ending an empty edit submitted an example.'
            # Intentionally entering text identical to the hint must be real data.
            $value = [string]$sheet.example_rows[0][0]
            $grid.Rows[0].Cells[0].Value = $value
            Assert-Grid ($grid.GetInputRows()[0][0] -ceq $value) 'Deliberately entered data was discarded.'
            $grid.Columns[0].HeaderText = 'renamed_field'
            Assert-Grid ($grid.GetInputHeaders()[0] -eq 'renamed_field') 'Renamed column was not included in the snapshot.'
            $grid.AddInputColumn('new_sample')
            Assert-Grid ($grid.GetInputHeaders()[-1] -eq 'new_sample') 'Added column has no real name.'
            $grid.Rows[0].Cells[0].Value = $null
            $grid.ClearSelection(); $grid.Rows[0].Cells[0].Selected = $true
            $grid.CurrentCell = $grid.Rows[0].Cells[0]
            [void]$grid.BeginEdit($false)
            $grid.EditingControl.Text = 'typed_gene'
            [void]$grid.EndEdit()
            Assert-Grid ($grid.GetInputRows()[0][0] -eq 'typed_gene') 'Typed text was not committed.'
            $grid.Rows.RemoveAt(0)
            Assert-Grid ($grid.GetInputRows().Length -eq 0) 'Deleting the first data row failed.'
            $grid.ResetSheet([string[]]$sheet.headers,12)
            $grid.SetDataRow(0,[string[]]@('imported_gene'))
            Assert-Grid ($grid.GetInputRows()[0][0] -eq 'imported_gene') 'Import lost the first row.'
            $appended = $grid.AppendInputRow([string[]]@('appended_gene'))
            Assert-Grid ($appended -eq 1) 'AppendInputRow did not choose the first empty data row.'
            Assert-Grid ($grid.GetInputRows()[1][0] -eq 'appended_gene') 'AppendInputRow did not preserve the appended row.'
            $sheetsTested++
            Write-Host ('PASS ' + $schema.profile + ' / ' + $sheet.name)
        } finally {
            if($withExamples) { $withExamples.Dispose() }
            if($withoutExamples) { $withoutExamples.Dispose() }
            $window.Close(); $window.Dispose()
        }
    }
}
Write-Host "PASS: $sheetsTested sheets; first paint, named headers, examples, edit/copy/snapshot and first-row handling."
