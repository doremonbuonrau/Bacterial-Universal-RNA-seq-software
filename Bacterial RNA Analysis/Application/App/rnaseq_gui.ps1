$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:AppRoot = $PSScriptRoot
$script:SuiteRoot = Split-Path -Parent $PSScriptRoot
$script:StartupLog = Join-Path $script:SuiteRoot 'Logs\gui-startup.log'
$script:VisibilityMarker = Join-Path $script:SuiteRoot 'Logs\gui-visible.ok'
try {
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $script:StartupLog))
    if (Test-Path -LiteralPath $script:VisibilityMarker) { Remove-Item -LiteralPath $script:VisibilityMarker -Force }
    @(
        "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] GUI startup"
        "PowerShell $($PSVersionTable.PSVersion)"
        "Script $PSCommandPath"
    ) | Set-Content -LiteralPath $script:StartupLog -Encoding UTF8
}
catch { }

try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Show a lightweight branded loading window immediately. The full interface is
# intentionally feature-rich and takes longer to construct than the original
# selector; this gives instant visual feedback instead of leaving the user
# wondering whether the EXE started. It closes as soon as the main form appears.
$script:StartupSplash = $null
try {
    $startupSplash = New-Object System.Windows.Forms.Form
    $startupSplash.Text = 'Bacterial RNA Analysis'
    $startupSplash.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $startupSplash.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $startupSplash.ControlBox = $false
    $startupSplash.ShowInTaskbar = $true
    $startupSplash.ClientSize = New-Object System.Drawing.Size(470, 150)
    $startupSplash.BackColor = [System.Drawing.Color]::White

    $launcherPath = Join-Path (Split-Path -Parent $script:SuiteRoot) 'Bacterial RNA Analysis.exe'
    if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
        try { $startupSplash.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($launcherPath) } catch { }
    }

    $startupTitle = New-Object System.Windows.Forms.Label
    $startupTitle.Text = 'Bacterial RNA Analysis'
    $startupTitle.Font = New-Object System.Drawing.Font('Segoe UI', [single]18, [System.Drawing.FontStyle]::Bold)
    $startupTitle.ForeColor = [System.Drawing.Color]::FromArgb(35, 91, 53)
    $startupTitle.AutoSize = $true
    $startupTitle.Location = New-Object System.Drawing.Point(34, 30)

    $startupMessage = New-Object System.Windows.Forms.Label
    $startupMessage.Text = 'Loading the analysis workspace...'
    $startupMessage.Font = New-Object System.Drawing.Font('Segoe UI', [single]10.5)
    $startupMessage.ForeColor = [System.Drawing.Color]::FromArgb(75, 82, 78)
    $startupMessage.AutoSize = $true
    $startupMessage.Location = New-Object System.Drawing.Point(37, 82)

    $startupSplash.Controls.AddRange(@($startupTitle, $startupMessage))
    $startupSplash.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $script:StartupSplash = $startupSplash
    try { [System.IO.File]::WriteAllText($script:VisibilityMarker, "Loading $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))") } catch { }
} catch { }

$script:CatalogPath = Join-Path $script:AppRoot 'method_catalog.json'
$script:Catalog = Get-Content -LiteralPath $script:CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:AnalysisType = ''
$script:PipelineProcess = $null
$script:PipelineJobToken = ''
$script:PipelineDistro = ''
$script:PipelineLinuxPidFile = ''
$script:RunOutput = ''
$script:LastLogLength = 0
$script:CurrentConfigPath = ''
$script:AllowForwardTabNavigation = $false
$script:MaxUnlockedStep = 0
$script:ActiveHelpPopup = $null
$script:SharedAnalysisStateDir = Join-Path $script:SuiteRoot 'Modules\Shared Analysis State'
try { [void][System.IO.Directory]::CreateDirectory($script:SharedAnalysisStateDir) } catch { }

function Save-LatestRnaSeqAnalysisReady([string]$AnalysisReadyPath) {
    if (-not $AnalysisReadyPath -or -not (Test-Path -LiteralPath $AnalysisReadyPath -PathType Container)) { return }
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $script:SharedAnalysisStateDir 'last_rnaseq_output.txt'), $AnalysisReadyPath, $encoding)
    } catch { }
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
$script:DescriptionBodyFont = New-Object System.Drawing.Font('Segoe UI', [single]10.25, [System.Drawing.FontStyle]::Regular)
$script:DescriptionHeaderFont = New-Object System.Drawing.Font('Segoe UI', [single]12.5, [System.Drawing.FontStyle]::Bold)
$script:HelpHeaderFont = New-Object System.Drawing.Font('Segoe UI', [single]11.5, [System.Drawing.FontStyle]::Bold)
$script:OperonBodyNarrowFont = $script:DescriptionBodyFont
$script:OperonBodyMediumFont = $script:DescriptionBodyFont
$script:OperonBodyWideFont = $script:DescriptionBodyFont
$script:HelpOptionFont = New-Object System.Drawing.Font('Consolas', [single]10, [System.Drawing.FontStyle]::Bold)


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

        # Editable ComboBoxes can select their entire text in Windows when they
        # receive focus or when autocomplete commits a value. That is the bright
        # blue rectangle users were seeing around values such as "auto". Keep
        # custom typing available, but disable automatic text selection.
        if ($Combo.DropDownStyle -eq [System.Windows.Forms.ComboBoxStyle]::DropDown) {
            $Combo.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::None
            $Combo.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::None
            $clearComboSelection = {
                param($sender, $eventArgs)
                try {
                    # Collapse any edit-text selection immediately. Windows can
                    # re-select editable ComboBox text after the focus event, so
                    # repeat the collapse on the message queue as well.
                    $sender.SelectionStart = $sender.Text.Length
                    $sender.SelectionLength = 0
                    if ($sender.IsHandleCreated -and -not $sender.IsDisposed) {
                        $collapse = [System.Windows.Forms.MethodInvoker]{
                            try {
                                $sender.SelectionStart = $sender.Text.Length
                                $sender.SelectionLength = 0
                            } catch { }
                        }
                        [void]$sender.BeginInvoke($collapse)
                    }
                } catch { }
            }
            $Combo.Add_Enter($clearComboSelection)
            $Combo.Add_GotFocus($clearComboSelection)
            $Combo.Add_DropDownClosed($clearComboSelection)
            $Combo.Add_SelectedIndexChanged($clearComboSelection)
            # The initial SelectedIndex is assigned before this theme helper is
            # attached. Clear that pre-existing selection immediately too.
            try {
                $Combo.SelectionStart = $Combo.Text.Length
                $Combo.SelectionLength = 0
            } catch { }
        }
    }
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

function Apply-NeutralSelectionTheme {
    param([System.Windows.Forms.Control]$RootControl)
    if (-not $RootControl) { return }
    if ($RootControl -is [System.Windows.Forms.ComboBox]) { Enable-NeutralComboBox ([System.Windows.Forms.ComboBox]$RootControl) }
    if ($RootControl -is [System.Windows.Forms.ListBox]) { Enable-NeutralListBox ([System.Windows.Forms.ListBox]$RootControl) }
    if ($RootControl -is [System.Windows.Forms.DataGridView]) { Set-NeutralGridSelection ([System.Windows.Forms.DataGridView]$RootControl) }
    foreach ($child in $RootControl.Controls) { Apply-NeutralSelectionTheme $child }
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 170, [int]$Height = 24, [switch]$Bold)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.ForeColor = $ink
    if ($Bold) { $label.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold) }
    return $label
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 120, [int]$Height = 32, [switch]$Primary)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, $Height)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderColor = $border
    if ($Primary) {
        $button.BackColor = $green
        $button.ForeColor = $surface
        $button.FlatAppearance.BorderColor = $green
    }
    else {
        $button.BackColor = $surface
        $button.ForeColor = $ink
    }
    return $button
}

function New-TextBox {
    param([int]$X, [int]$Y, [int]$Width = 300, [int]$Height = 25)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point($X, $Y)
    $box.Size = New-Object System.Drawing.Size($Width, $Height)
    return $box
}

function New-TableLabel([string]$Text) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Dock = [System.Windows.Forms.DockStyle]::Fill
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $label.ForeColor = $ink
    $label.Margin = New-Object System.Windows.Forms.Padding(3)
    return $label
}

function Set-DescriptionPanelText {
    param(
        [System.Windows.Forms.RichTextBox]$Box,
        [string]$Text
    )

    $headingPattern = '^(?:Definition|When to use|Uses AI or machine learning|Advantages|Limitations|Required commands|rSeqTU|OpDetect|[A-Z][A-Z0-9 /+&-]{2,})$'
    $normalizedText = $Text -replace "(?<!`r)`n", "`r`n"
    $sourceLines = $normalizedText -split "`r`n"
    $renderLines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $sourceLines.Count; $i++) {
        $currentLine = [string]$sourceLines[$i]
        $renderLines.Add($currentLine)
        if ($currentLine -match $headingPattern) {
            $nextLine = if (($i + 1) -lt $sourceLines.Count) { [string]$sourceLines[$i + 1] } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($nextLine)) {
                $renderLines.Add('')
            }
        }
    }

    $Box.Text = ($renderLines -join "`r`n")
    $formattedText = $Box.Text
    $Box.SelectAll()
    $Box.SelectionFont = $script:DescriptionBodyFont
    $Box.SelectionColor = $ink
    $Box.SelectionBackColor = $surface

    $formattedHeadingPattern = '(?m)^(?:Definition|When to use|Uses AI or machine learning|Advantages|Limitations|Required commands|rSeqTU|OpDetect|[A-Z][A-Z0-9 /+&-]{2,})\r?$'
    foreach ($headingMatch in [System.Text.RegularExpressions.Regex]::Matches($formattedText, $formattedHeadingPattern)) {
        $headingLength = $headingMatch.Length
        if ($headingLength -gt 0 -and $headingMatch.Value.EndsWith("`r")) {
            $headingLength--
        }
        $Box.Select($headingMatch.Index, $headingLength)
        $Box.SelectionFont = $script:DescriptionHeaderFont
        $Box.SelectionColor = $greenDark
        $Box.SelectionBackColor = $surface
    }

    # Uppercase parameter-help section headings need a compact but unmistakably
    # bold style. Apply this as a final pass so WHAT THIS SETTING CONTROLS,
    # RECOMMENDED SELECTION, and AVAILABLE SELECTIONS cannot inherit body text.
    $uppercaseHeadingPattern = '(?m)^[A-Z][A-Z0-9 /+&-]{2,}\r?$'
    foreach ($headingMatch in [System.Text.RegularExpressions.Regex]::Matches($formattedText, $uppercaseHeadingPattern)) {
        $headingLength = $headingMatch.Length
        if ($headingLength -gt 0 -and $headingMatch.Value.EndsWith("`r")) { $headingLength-- }
        $Box.Select($headingMatch.Index, $headingLength)
        $Box.SelectionFont = $script:HelpHeaderFont
        $Box.SelectionColor = $greenDark
        $Box.SelectionBackColor = $surface
    }

    $Box.SelectionStart = 0
    $Box.SelectionLength = 0
    $Box.ScrollToCaret()
}

function Hide-HelpPopup {
    if ($script:ActiveHelpPopup) {
        try { $script:ActiveHelpPopup.Close() } catch { }
        try { $script:ActiveHelpPopup.Dispose() } catch { }
        $script:ActiveHelpPopup = $null
    }
}

function Format-RnaParameterHelpText {
    param([System.Windows.Forms.RichTextBox]$Box, [string]$Title = '')
    if (-not $Box) { return }

    # Use the same visual hierarchy as Differential Expression / GO / Networks.
    $regularFont = New-Object System.Drawing.Font('Segoe UI', [single]9.5, [System.Drawing.FontStyle]::Regular)
    $boldFont = New-Object System.Drawing.Font('Segoe UI', [single]9.5, [System.Drawing.FontStyle]::Bold)
    $headingFont = New-Object System.Drawing.Font('Segoe UI', [single]10.5, [System.Drawing.FontStyle]::Bold)
    $titleFont = New-Object System.Drawing.Font('Segoe UI', [single]11.5, [System.Drawing.FontStyle]::Bold)

    $Box.SelectAll()
    $Box.SelectionFont = $regularFont
    $Box.SelectionColor = $ink
    $Box.SelectionBackColor = $surface

    if ($Title) {
        $titleIndex = $Box.Text.IndexOf($Title, [System.StringComparison]::Ordinal)
        if ($titleIndex -ge 0) {
            $Box.Select($titleIndex, $Title.Length)
            $Box.SelectionFont = $titleFont
            $Box.SelectionColor = $greenDark
            $Box.SelectionBackColor = $surface
        }
    }

    # Bold category names such as "Allowed range:" and "Recommended selection:".
    $prefixPattern = '(?m)^([A-Za-z][A-Za-z0-9 /+&().,_\-]{1,72}:)'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Box.Text, $prefixPattern)) {
        $Box.Select($match.Index, $match.Length)
        $Box.SelectionFont = $boldFont
        $Box.SelectionColor = $greenDark
        $Box.SelectionBackColor = $surface
    }

    # Standalone subsection names are rendered as real headings.
    $sectionPattern = '(?m)^([^\r\n:]{2,90})(?=\r?\n(?:What this setting controls:|Allowed range:|Allowed and practical range:|Recommended value:|Recommended starting value:|Recommended selection:|Available selections:|When to change it:|When to use a different value:))'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Box.Text, $sectionPattern)) {
        $Box.Select($match.Index, $match.Length)
        $Box.SelectionFont = $headingFont
        $Box.SelectionColor = $greenDark
        $Box.SelectionBackColor = $surface
    }

    # Literal dropdown choices remain easy to distinguish.
    foreach ($optionMatch in [System.Text.RegularExpressions.Regex]::Matches($Box.Text, '\[[A-Za-z0-9_]+\]')) {
        $Box.Select($optionMatch.Index, $optionMatch.Length)
        $Box.SelectionFont = $script:HelpOptionFont
        $Box.SelectionColor = $blue
        $Box.SelectionBackColor = $blueSoft
    }

    $Box.Select(0, 0)
}

function Show-HelpPopup {
    param(
        [System.Windows.Forms.Control]$Anchor,
        [string]$Title,
        [string]$HelpText
    )
    Hide-HelpPopup

    $screen = [System.Windows.Forms.Screen]::FromControl($Anchor)
    $workingArea = $screen.WorkingArea
    $popupWidth = [Math]::Min(520, [Math]::Max(350, ($workingArea.Width - 24)))
    $fullText = if ([string]::IsNullOrWhiteSpace($Title)) { $HelpText } else { "$Title`r`n`r`n$HelpText" }
    $measureFont = New-Object System.Drawing.Font('Segoe UI', [single]9.5, [System.Drawing.FontStyle]::Regular)
    $measureFlags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
    $measured = [System.Windows.Forms.TextRenderer]::MeasureText(
        $fullText,
        $measureFont,
        (New-Object System.Drawing.Size(($popupWidth - 30), 2600)),
        $measureFlags
    )
    $maximumHeight = [Math]::Max(190, [Math]::Min(580, ($workingArea.Height - 24)))
    $popupHeight = [Math]::Min($maximumHeight, [Math]::Max(190, ($measured.Height + 34)))

    $helpBox = New-Object System.Windows.Forms.RichTextBox
    $helpBox.Size = New-Object System.Drawing.Size(($popupWidth - 4), ($popupHeight - 4))
    $helpBox.ReadOnly = $true
    $helpBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $helpBox.BackColor = $surface
    $helpBox.ForeColor = $ink
    $helpBox.Font = $measureFont
    $helpBox.WordWrap = $true
    $helpBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
    $helpBox.DetectUrls = $false
    $helpBox.TabStop = $false
    $helpBox.Text = $fullText
    Format-RnaParameterHelpText -Box $helpBox -Title $Title

    $popupControlHost = New-Object System.Windows.Forms.ToolStripControlHost -ArgumentList $helpBox
    $popupControlHost.AutoSize = $false
    $popupControlHost.Size = $helpBox.Size
    $popupControlHost.Margin = New-Object System.Windows.Forms.Padding(0)
    $popupControlHost.Padding = New-Object System.Windows.Forms.Padding(0)

    $popup = New-Object System.Windows.Forms.ToolStripDropDown
    $popup.AutoSize = $false
    $popup.Padding = New-Object System.Windows.Forms.Padding(1)
    $popup.Size = New-Object System.Drawing.Size($popupWidth, $popupHeight)
    $popup.BackColor = $border
    $popup.DropShadowEnabled = $true
    [void]$popup.Items.Add($popupControlHost)

    $anchorTopLeft = $Anchor.PointToScreen((New-Object System.Drawing.Point(0, 0)))
    $rightPoint = $Anchor.PointToScreen((New-Object System.Drawing.Point(($Anchor.Width + 6), 0)))
    $leftPoint = $Anchor.PointToScreen((New-Object System.Drawing.Point((-1 * ($popupWidth + 6)), 0)))
    $popupX = $rightPoint.X
    if (($popupX + $popupWidth) -gt $workingArea.Right) { $popupX = $leftPoint.X }
    $popupX = [Math]::Max($workingArea.Left + 4, [Math]::Min($popupX, ($workingArea.Right - $popupWidth - 4)))
    $popupY = $anchorTopLeft.Y
    if (($popupY + $popupHeight) -gt $workingArea.Bottom) { $popupY = $workingArea.Bottom - $popupHeight - 4 }
    $popupY = [Math]::Max($workingArea.Top + 4, $popupY)

    $script:ActiveHelpPopup = $popup
    $popup.Show((New-Object System.Drawing.Point($popupX, $popupY)))
}

function New-HelpIcon([string]$HelpText, [string]$Title = 'Parameter help') {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = '?'
    $button.Size = New-Object System.Drawing.Size(24, 24)
    $button.Margin = New-Object System.Windows.Forms.Padding(0, 5, 8, 0)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = $blueSoft
    $button.ForeColor = $blue
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $button.Cursor = [System.Windows.Forms.Cursors]::Help
    $button.TabStop = $false
    $button.UseVisualStyleBackColor = $false
    $button.Tag = [pscustomobject]@{ Text = $HelpText; Title = $Title }
    $circle = New-Object System.Drawing.Drawing2D.GraphicsPath
    $circle.AddEllipse(0, 0, ($button.Width - 1), ($button.Height - 1))
    $button.Region = New-Object System.Drawing.Region($circle)
    $circle.Dispose()
    $button.Add_Resize({
        param($sender, $eventArgs)
        $resizedCircle = New-Object System.Drawing.Drawing2D.GraphicsPath
        $resizedCircle.AddEllipse(0, 0, ($sender.Width - 1), ($sender.Height - 1))
        $oldRegion = $sender.Region
        $sender.Region = New-Object System.Drawing.Region($resizedCircle)
        $resizedCircle.Dispose()
        if ($oldRegion) { $oldRegion.Dispose() }
    })
    $button.Add_Paint({
        param($sender, $eventArgs)
        $eventArgs.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $outline = New-Object System.Drawing.Pen($blue, 1)
        try { $eventArgs.Graphics.DrawEllipse($outline, 0, 0, ($sender.Width - 1), ($sender.Height - 1)) }
        finally { $outline.Dispose() }
    })
    $button.Add_MouseEnter({
        param($sender, $eventArgs)
        Show-HelpPopup -Anchor $sender -Title ([string]$sender.Tag.Title) -HelpText ([string]$sender.Tag.Text)
    })
    $button.Add_MouseLeave({ param($sender, $eventArgs) Hide-HelpPopup })
    # Help is intentionally hover-only so users can inspect guidance without
    # opening a modal dialog or interrupting data entry.
    return $button
}

function Get-CpuTopology {
    $logical = [int][Environment]::ProcessorCount
    $physical = $null
    try {
        $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        if ($processors.Count -gt 0) {
            $logicalSum = ($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
            $physicalSum = ($processors | Measure-Object -Property NumberOfCores -Sum).Sum
            if ($logicalSum) { $logical = [int]$logicalSum }
            if ($physicalSum) { $physical = [int]$physicalSum }
        }
    }
    catch { }
    if ($logical -lt 1) { $logical = 1 }
    return [pscustomobject]@{
        Logical = $logical
        Physical = $physical
        Recommended = [Math]::Max(1, [int][Math]::Floor($logical * 0.75))
    }
}

function Show-Error([string]$Message) {
    [void][System.Windows.Forms.MessageBox]::Show($Message, 'Bacterial RNA Analysis', 'OK', 'Error')
}

function Show-Info([string]$Message) {
    [void][System.Windows.Forms.MessageBox]::Show($Message, 'Bacterial RNA Analysis', 'OK', 'Information')
}

function Select-File([string]$Filter = 'All files (*.*)|*.*', [string]$Title = '') {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = $Filter
    if (-not [string]::IsNullOrWhiteSpace($Title)) { $dialog.Title = $Title }
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
    return ''
}

function Select-Files([string]$Title, [string]$Filter = 'All files (*.*)|*.*') {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $true
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return @($dialog.FileNames) }
    return @()
}

function Select-Folder([string]$Description = 'Select a folder') {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
    return ''
}

function ConvertTo-WindowsCommandLineArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    return '"' + ([string]$Value).Replace('"', '\"') + '"'
}

function Normalize-NativeOutputText([string]$Text) {
    if ($null -eq $Text) { return '' }
    $clean = [string]$Text
    # Some Windows PowerShell 5.1 and wsl.exe combinations expose UTF-16 output
    # as characters separated by NUL bytes. A WinForms RichTextBox then appears
    # to contain only the first letter (for example, "T" from "The...").
    $clean = $clean.Replace(([string][char]0), [string]::Empty)
    $clean = [System.Text.RegularExpressions.Regex]::Replace(
        $clean,
        '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]',
        ''
    )
    $clean = $clean -replace "(?<!`r)`n", "`r`n"
    return $clean.TrimEnd()
}

function Invoke-WslCapture([string[]]$Arguments, [int]$TimeoutMilliseconds = 60000) {
    # Use PowerShell native-argument splatting rather than rebuilding one quoted
    # command line. This matches the invocation path already proven by OpDetect
    # and prevents wsl.exe from receiving a contaminated shell/distribution arg.
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
            }
            else { $line = [string]$record }
            $line = Normalize-NativeOutputText $line
            if (-not $line) { continue }
            if ($isStandardError) { [void]$stderrLines.Add($line) }
            else { [void]$stdoutLines.Add($line) }
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            StandardOutput = Normalize-NativeOutputText ($stdoutLines -join "`r`n")
            StandardError = Normalize-NativeOutputText ($stderrLines -join "`r`n")
        }
    }
    catch {
        return [pscustomobject]@{ ExitCode = -1; StandardOutput = ''; StandardError = $_.Exception.Message }
    }
    finally { $ErrorActionPreference = $previousPreference }
}

function Normalize-WslName([string]$Value) {
    if ($null -eq $Value) { return '' }
    $clean = [string]$Value
    $clean = [System.Text.RegularExpressions.Regex]::Replace($clean, '[\p{Cc}\p{Cf}]', '')
    try { $clean = $clean.Normalize([System.Text.NormalizationForm]::FormKC) } catch { }
    $clean = $clean.Trim()
    if ($clean.StartsWith('*')) { $clean = $clean.Substring(1).Trim() }
    return $clean
}

function Get-WslNameFromProbeOutput([string]$Text) {
    # WSL can write a localhost-proxy warning to stderr while successfully
    # printing WSL_DISTRO_NAME to stdout. Older Windows PowerShell hosts may
    # surface both records together, so select only a clean non-warning line.
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in ((Normalize-NativeOutputText $Text) -split '[\r\n]+')) {
        $name = Normalize-WslName $line
        if (-not $name) { continue }
        if ($name -match '(?i)^wsl(?:\.exe)?\s*:') { continue }
        if ($name -match '(?i)localhost prox|not mirrored into WSL|does not support localhost proxies|there is no distribution|error code|windows subsystem') { continue }
        [void]$names.Add($name)
    }
    if ($names.Count -eq 0) { return '' }
    return [string]$names[$names.Count - 1]
}

function Test-WslDistroRunnable([string]$Distro) {
    $name = Normalize-WslName $Distro
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    $probe = Invoke-WslCapture @('-d', $name, '-u', 'root', '--', '/bin/echo', 'BACTERIAL_RNA_WSL_READY') 60000
    return ($probe.ExitCode -eq 0 -and $probe.StandardOutput -match 'BACTERIAL_RNA_WSL_READY')
}

function Test-WslDistroCompatible([string]$Distro) {
    if (-not (Test-WslDistroRunnable $Distro)) { return $false }
    $probe = Invoke-WslCapture @('-d', $Distro, '-u', 'root', '--', '/bin/cat', '/etc/os-release')
    if ($probe.ExitCode -ne 0) { return $false }
    return ([string]$probe.StandardOutput) -match '(?im)^ID=(ubuntu|debian)$|^ID=\"?(ubuntu|debian)\"?$'
}

function Test-WslDistroHasCoreRnaEnvironment([string]$Distro) {
    $name = Normalize-WslName $Distro
    if (-not $name -or -not (Test-WslDistroRunnable $name)) { return $false }
    $probe = Invoke-WslCapture @('-d', $name, '-u', 'root', '--', 'bash', '-lc', 'if [ -x /root/.local/share/prok-rnaseq/miniforge3/envs/prok-rnaseq/bin/python ]; then printf BACTERIAL_RNA_CORE_READY; fi') 60000
    return ($probe.ExitCode -eq 0 -and $probe.StandardOutput -match 'BACTERIAL_RNA_CORE_READY')
}

function Get-WslRegistryDistroNames {
    $names = New-Object System.Collections.Generic.List[string]
    try {
        $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        if (-not (Test-Path -LiteralPath $root)) { return @() }
        $rootProperties = Get-ItemProperty -LiteralPath $root -ErrorAction SilentlyContinue
        $defaultId = [string]$rootProperties.DefaultDistribution
        if ($defaultId) {
            $defaultPath = Join-Path $root $defaultId
            if (Test-Path -LiteralPath $defaultPath) {
                $defaultName = Normalize-WslName ([string](Get-ItemProperty -LiteralPath $defaultPath -ErrorAction SilentlyContinue).DistributionName)
                if ($defaultName) { [void]$names.Add($defaultName) }
            }
        }
        foreach ($item in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $name = Normalize-WslName ([string](Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue).DistributionName)
            if ($name) { [void]$names.Add($name) }
        }
    }
    catch { }
    return @($names)
}

function Get-WslListedDistroNames {
    # `wsl.exe --list --quiet` commonly writes UTF-16LE when redirected. Reading
    # it through a default UTF-8 StreamReader can produce empty/garbled names.
    # Capture raw bytes and choose the encoding from the byte pattern.
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
            if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
                $output = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
            }
            else { $output = [System.Text.Encoding]::Unicode.GetString($bytes) }
        }
        else {
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $output = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
            }
            else { $output = [System.Text.Encoding]::UTF8.GetString($bytes) }
        }

        $names = New-Object System.Collections.Generic.List[string]
        foreach ($line in ([string]$output -split '[\r\n]+')) {
            $name = Normalize-WslName $line
            if (-not $name) { continue }
            if ($name -match '(?i)there is no distribution|error code|windows subsystem') { continue }
            [void]$names.Add($name)
        }
        return @($names)
    }
    catch { return @() }
    finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-WslDistro {
    $marker = Join-Path $script:AppRoot 'environment\.wsl_distro'
    $preferred = New-Object System.Collections.Generic.List[string]

    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        try {
            $saved = Normalize-WslName (Get-Content -LiteralPath $marker -Raw -ErrorAction Stop)
            if ($saved) { [void]$preferred.Add($saved) }
        } catch { }
    }

    $defaultName = ''
    $defaultProbe = Invoke-WslCapture @('-u', 'root', '--', '/usr/bin/printenv', 'WSL_DISTRO_NAME') 60000
    if ($defaultProbe.ExitCode -eq 0) { $defaultName = Get-WslNameFromProbeOutput $defaultProbe.StandardOutput }

    $listed = @(Get-WslListedDistroNames)
    $registry = @(Get-WslRegistryDistroNames)
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($value in $preferred) { [void]$candidates.Add([string]$value) }
    if ($defaultName) { [void]$candidates.Add($defaultName) }
    foreach ($value in $registry) { [void]$candidates.Add([string]$value) }
    foreach ($value in $listed) { [void]$candidates.Add([string]$value) }
    foreach ($known in @('Ubuntu-24.04', 'Ubuntu', 'Ubuntu-22.04', 'Debian', 'OpDetect-Ubuntu')) { [void]$candidates.Add($known) }

    $seen = @{}
    $normalized = New-Object System.Collections.Generic.List[string]
    foreach ($candidateValue in $candidates) {
        $candidate = Normalize-WslName ([string]$candidateValue)
        if (-not $candidate) { continue }
        if ($candidate -match '(?i)^docker-desktop(?:-data)?$|^rancher-desktop$|^podman-machine') { continue }
        $key = $candidate.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$normalized.Add($candidate)
    }

    # Prefer the distro containing the managed RNA Processing environment.
    # This repairs old core markers that were accidentally overwritten by OpDetect.
    foreach ($candidate in $normalized) {
        if (Test-WslDistroHasCoreRnaEnvironment $candidate) {
            try { [System.IO.File]::WriteAllText($marker, $candidate, (New-Object System.Text.UTF8Encoding($false))) } catch { }
            return $candidate
        }
    }

    # First-time setup fallback: ordinary Ubuntu/Debian only.
    foreach ($candidate in $normalized) {
        if ($candidate -match '(?i)^OpDetect-Ubuntu$') { continue }
        if (Test-WslDistroCompatible $candidate) {
            try { [System.IO.File]::WriteAllText($marker, $candidate, (New-Object System.Text.UTF8Encoding($false))) } catch { }
            return $candidate
        }
    }

    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        try { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue } catch { }
    }
    return ''
}

function Convert-ToWslPath([string]$WindowsPath, [string]$Distro) {
    if ([string]::IsNullOrWhiteSpace($WindowsPath)) { throw 'The Windows path is empty.' }
    $fullPath = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -match '^([A-Za-z]):[\\/](.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $tail = $Matches[2].Replace('\', '/')
        return "/mnt/$drive/$tail"
    }
    if ($fullPath -match '^\\\\wsl(?:\.localhost)?\\([^\\]+)\\(.*)$') {
        $pathDistro = $Matches[1]
        if ($Distro -and $pathDistro -ine $Distro) {
            throw "The path belongs to WSL distribution '$pathDistro', but '$Distro' is selected."
        }
        return '/' + $Matches[2].Replace('\', '/')
    }
    throw "The application must be stored on a local Windows drive such as C:, D:, or E:. Unsupported path: $WindowsPath"
}

$form = New-Object System.Windows.Forms.Form
# Suspend layout while the large interface is assembled. This avoids hundreds
# of intermediate DPI/layout passes and restores the fast startup behaviour of
# earlier builds.
$form.SuspendLayout()
$form.Text = 'Bacterial RNA Analysis'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.ClientSize = New-Object System.Drawing.Size(1500, 900)
$form.MinimumSize = New-Object System.Drawing.Size(1180, 760)
$form.BackColor = $background
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.ShowInTaskbar = $true
$form.Tag = [pscustomobject]@{
    EmbeddedModuleActive = $false
    MainSuiteClosing = $false
    ModuleOverlay = $null
}
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 14000
$toolTip.InitialDelay = 350
$toolTip.ReshowDelay = 100
$iconPath = Join-Path $script:AppRoot 'assets\rnaseq_suite.ico'
if (Test-Path -LiteralPath $iconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { }
}

$rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
$rootLayout.SuspendLayout()
$rootLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$rootLayout.ColumnCount = 1
$rootLayout.RowCount = 3
[void]$rootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 88)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 58)))
$rootLayout.Margin = New-Object System.Windows.Forms.Padding(0)
$rootLayout.Padding = New-Object System.Windows.Forms.Padding(0)
$form.Controls.Add($rootLayout)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = [System.Windows.Forms.DockStyle]::Fill
$header.BackColor = $surface
$rootLayout.Controls.Add($header, 0, 0)

$logo = New-Object System.Windows.Forms.PictureBox
$logo.Location = New-Object System.Drawing.Point(18, 10)
$logo.Size = New-Object System.Drawing.Size(68, 68)
$logo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$logoPath = Join-Path $script:AppRoot 'assets\rnaseq_suite.png'
if (Test-Path -LiteralPath $logoPath) { try { $logo.Image = [System.Drawing.Image]::FromFile($logoPath) } catch { } }
$header.Controls.Add($logo)

$title = New-Label 'Bacterial RNA Analysis' 98 15 520 30 -Bold
$title.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = $greenDark
$header.Controls.Add($title)
$subtitle = New-Label 'Choose the bacterial RNA-seq workflow that matches your project.' 101 51 700 24
$subtitle.ForeColor = $muted
$header.Controls.Add($subtitle)


$scope = New-Object System.Windows.Forms.Label
$scope.Text = 'Six bacterial RNA-seq modules available'
$scope.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$scope.BackColor = $blueSoft
$scope.ForeColor = $blue
$scope.Location = New-Object System.Drawing.Point(1205, 25)
$scope.Size = New-Object System.Drawing.Size(275, 34)
$scope.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$header.Controls.Add($scope)
$header.Add_Resize({
    $scope.Left = [Math]::Max(885, ($header.ClientSize.Width - $scope.Width - 20))
})

$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = [System.Windows.Forms.DockStyle]::Fill
$footer.BackColor = $surface
$rootLayout.Controls.Add($footer, 0, 2)

$footerNavigation = New-Object System.Windows.Forms.FlowLayoutPanel
$footerNavigation.Dock = [System.Windows.Forms.DockStyle]::Right
$footerNavigation.Width = 278
$footerNavigation.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$footerNavigation.WrapContents = $false
$footerNavigation.Padding = New-Object System.Windows.Forms.Padding(4, 8, 8, 5)
$footer.Controls.Add($footerNavigation)
$backButton = New-Button 'Back' 0 0 122 39
$nextButton = New-Button 'Next' 0 0 122 39 -Primary
foreach ($button in @($backButton, $nextButton)) {
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
    $button.Margin = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
}
$footerNavigation.Controls.AddRange(@($backButton, $nextButton))

$footerReturn = New-Object System.Windows.Forms.FlowLayoutPanel
$footerReturn.Dock = [System.Windows.Forms.DockStyle]::Left
$footerReturn.Width = 250
$footerReturn.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$footerReturn.WrapContents = $false
$footerReturn.Padding = New-Object System.Windows.Forms.Padding(8, 8, 4, 5)
$footer.Controls.Add($footerReturn)
$modulesButton = New-Button '< Back to analysis modules' 0 0 226 39
$modulesButton.Font = New-Object System.Drawing.Font('Segoe UI', [single]10, [System.Drawing.FontStyle]::Bold)
$modulesButton.Margin = New-Object System.Windows.Forms.Padding(0)
$footerReturn.Controls.Add($modulesButton)

$workspaceHost = New-Object System.Windows.Forms.Panel
$workspaceHost.Dock = [System.Windows.Forms.DockStyle]::Fill
$workspaceHost.Margin = New-Object System.Windows.Forms.Padding(0)
$workspaceHost.BackColor = $background
$rootLayout.Controls.Add($workspaceHost, 0, 1)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.SuspendLayout()
$tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
$tabs.Multiline = $false
$tabs.Padding = New-Object System.Drawing.Point(12, 6)
$tabs.SizeMode = [System.Windows.Forms.TabSizeMode]::Fixed
$tabs.ItemSize = New-Object System.Drawing.Size(136, 32)
$tabs.DrawMode = [System.Windows.Forms.TabDrawMode]::OwnerDrawFixed
$tabs.Visible = $false
$workspaceHost.Controls.Add($tabs)

$topProjectActions = New-Object System.Windows.Forms.FlowLayoutPanel
$topProjectActions.Size = New-Object System.Drawing.Size(340, 34)
$topProjectActions.Location = New-Object System.Drawing.Point(1150, 1)
$topProjectActions.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$topProjectActions.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$topProjectActions.WrapContents = $false
$topProjectActions.BackColor = $background
$topProjectActions.Padding = New-Object System.Windows.Forms.Padding(2, 1, 2, 1)
$topProjectActions.Visible = $false
$saveButton = New-Button 'Save project' 0 0 100 30
$loadButton = New-Button 'Load project' 0 0 100 30
$helpButton = New-Button 'Open guide' 0 0 100 30
foreach ($button in @($saveButton, $loadButton, $helpButton)) { $button.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0) }
$topProjectActions.Controls.AddRange(@($saveButton, $loadButton, $helpButton))
$workspaceHost.Controls.Add($topProjectActions)

$homeSurface = New-Object System.Windows.Forms.Panel
$homeSurface.Dock = [System.Windows.Forms.DockStyle]::Fill
$homeSurface.BackColor = $background
$workspaceHost.Controls.Add($homeSurface)
$homeSurface.BringToFront()

$pageType = New-Object System.Windows.Forms.TabPage
$pageType.Text = '1  Read type'
$pageType.BackColor = $background
$pageEnvironment = New-Object System.Windows.Forms.TabPage
$pageEnvironment.Text = '2  Environment'
$pageEnvironment.BackColor = $background
$pageInputs = New-Object System.Windows.Forms.TabPage
$pageInputs.Text = '3  Inputs and replicates'
$pageInputs.BackColor = $background
$pageMethods = New-Object System.Windows.Forms.TabPage
$pageMethods.Text = '4  Methods'
$pageMethods.BackColor = $background
$pageRun = New-Object System.Windows.Forms.TabPage
$pageRun.Text = '5  Review and run'
$pageRun.BackColor = $background
$tabs.TabPages.AddRange(@($pageType, $pageEnvironment, $pageInputs, $pageMethods, $pageRun))
$tabs.Add_DrawItem({
    param($sender, $eventArgs)
    $index = $eventArgs.Index
    $bounds = $sender.GetTabRect($index)
    $selected = $index -eq $sender.SelectedIndex
    $unlocked = $index -le $script:MaxUnlockedStep
    if ($selected) {
        $fillColor = $surface
        $textColor = $greenDark
    }
    elseif ($unlocked) {
        $fillColor = $background
        $textColor = $ink
    }
    else {
        $fillColor = [System.Drawing.Color]::FromArgb(238, 241, 239)
        $textColor = [System.Drawing.Color]::FromArgb(150, 158, 153)
    }
    $brush = New-Object System.Drawing.SolidBrush($fillColor)
    $pen = New-Object System.Drawing.Pen($border)
    try {
        $eventArgs.Graphics.FillRectangle($brush, $bounds)
        $eventArgs.Graphics.DrawRectangle($pen, $bounds.X, $bounds.Y, ($bounds.Width - 1), ($bounds.Height - 1))
        $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
        [System.Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics, $sender.TabPages[$index].Text, $sender.Font, $bounds, $textColor, $flags)
    }
    finally {
        $brush.Dispose()
        $pen.Dispose()
    }
})

# Full-page home dashboard with six integrated bacterial RNA-seq modules.
$homeLayout = New-Object System.Windows.Forms.TableLayoutPanel
$homeLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$homeLayout.ColumnCount = 2
$homeLayout.RowCount = 1
$homeLayout.Padding = New-Object System.Windows.Forms.Padding(20, 18, 20, 18)
[void]$homeLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 36)))
[void]$homeLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 64)))
[void]$homeLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$homeSurface.Controls.Add($homeLayout)

$moduleChooser = New-Object System.Windows.Forms.TableLayoutPanel
$moduleChooser.Dock = [System.Windows.Forms.DockStyle]::Fill
$moduleChooser.ColumnCount = 1
$moduleChooser.RowCount = 2
$moduleChooser.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)
[void]$moduleChooser.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$moduleChooser.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 56)))
[void]$moduleChooser.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$homeLayout.Controls.Add($moduleChooser, 0, 0)

$moduleHeader = New-Object System.Windows.Forms.Panel
$moduleHeader.Dock = [System.Windows.Forms.DockStyle]::Fill
$moduleChooser.Controls.Add($moduleHeader, 0, 0)
$moduleHeading = New-Label 'CHOOSE AN ANALYSIS MODULE' 4 3 390 27 -Bold
$moduleHeading.ForeColor = $greenDark
$moduleHeading.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$moduleDescription = New-Label 'Select a module to read its purpose, inputs, outputs, and requirements.' 4 27 390 24
$moduleDescription.ForeColor = $muted
$moduleDescription.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$moduleHeader.Controls.AddRange(@($moduleHeading, $moduleDescription))

$moduleList = New-Object System.Windows.Forms.TableLayoutPanel
$moduleList.Dock = [System.Windows.Forms.DockStyle]::Fill
$moduleList.ColumnCount = 1
$moduleList.RowCount = 5
$moduleList.AutoScroll = $false
$moduleList.Padding = New-Object System.Windows.Forms.Padding(0, 0, 2, 0)
[void]$moduleList.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
for ($rowIndex = 0; $rowIndex -lt 5; $rowIndex++) {
    [void]$moduleList.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 20.0)))
}
$moduleChooser.Controls.Add($moduleList, 0, 1)

function New-ModuleCard([string]$Heading, [string]$Body, [bool]$Available) {
    $card = New-Object System.Windows.Forms.Panel
    $card.Dock = [System.Windows.Forms.DockStyle]::Fill
    $card.MinimumSize = New-Object System.Drawing.Size(300, 70)
    $card.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
    $card.BackColor = $surface
    $card.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    $accent = New-Object System.Windows.Forms.Panel
    $accent.Dock = [System.Windows.Forms.DockStyle]::Left
    $accent.Width = 7
    $accent.BackColor = $(if ($Available) { $green } else { $blue })
    $card.Controls.Add($accent)

    $headingLabel = New-Label $Heading 22 6 350 23 -Bold
    $headingLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]10.25, [System.Drawing.FontStyle]::Bold)
    $headingLabel.ForeColor = $greenDark
    $headingLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $bodyLabel = New-Label $Body 22 31 350 38
    $bodyLabel.ForeColor = $ink
    $bodyLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]8.7, [System.Drawing.FontStyle]::Regular)
    $bodyLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $bodyLabel.AutoEllipsis = $false
    $bodyLabel.AutoSize = $false

    $card.Controls.AddRange(@($headingLabel, $bodyLabel))
    $card.Tag = [pscustomobject]@{ available = $Available; heading = $headingLabel; body = $bodyLabel; accent = $accent }
    $card.Add_Resize({
        param($sender, $eventArgs)
        $contentWidth = [Math]::Max(220, ($sender.ClientSize.Width - 44))
        $sender.Tag.heading.SetBounds(22, 6, $contentWidth, 23)
        $sender.Tag.body.SetBounds(22, 30, $contentWidth, [Math]::Max(30, ($sender.ClientSize.Height - 34)))
    })
    return $card
}

$processingCard = New-ModuleCard 'RNA-seq processing' 'Process short or long bacterial RNA-seq through QC, alignment, counts, coverage, and reusable downstream outputs.' $true
$deCard = New-ModuleCard 'Differential expression' 'Compare replicated conditions to identify significant expression changes, effect sizes, and user-defined contrasts.' $true
$goCard = New-ModuleCard 'Functional enrichment and biological networks' 'GO and pathway enrichment, CEMiTool/WGCNA/GENIE3, plus STRING protein associations in one functional-analysis workspace.' $true
$networkCard = New-ModuleCard 'STRING protein associations' 'Retrieve physical or functional protein-association evidence for a bacterial gene/protein list.' $true
$transcriptCard = New-ModuleCard 'Transcript Discovery' 'Discover novel and antisense transcripts and rank bacterial sRNA candidates from stranded RNA-seq evidence.' $true
$operonCard = New-ModuleCard 'Operons and transcription units' 'rSeqTU, OpDetect, and evidence-based TU architecture/manual curation.' $true
$moduleList.Controls.Add($processingCard, 0, 0)
$moduleList.Controls.Add($deCard, 0, 1)
$moduleList.Controls.Add($goCard, 0, 2)
$moduleList.Controls.Add($transcriptCard, 0, 3)
$moduleList.Controls.Add($operonCard, 0, 4)

$homeDetailPanel = New-Object System.Windows.Forms.Panel
$homeDetailPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$homeDetailPanel.Margin = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
$homeDetailPanel.BackColor = $surface
$homeDetailPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$homeLayout.Controls.Add($homeDetailPanel, 1, 0)

$homeDetailLayout = New-Object System.Windows.Forms.TableLayoutPanel
$homeDetailLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$homeDetailLayout.ColumnCount = 1
$homeDetailLayout.RowCount = 6
$homeDetailLayout.Padding = New-Object System.Windows.Forms.Padding(32, 14, 32, 14)
[void]$homeDetailLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$homeDetailLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 12)))
[void]$homeDetailLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 72)))
[void]$homeDetailLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 0)))
[void]$homeDetailLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$homeDetailLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 60)))
[void]$homeDetailLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 12)))
$homeDetailPanel.Controls.Add($homeDetailLayout)

$homeDetailIcon = New-Object System.Windows.Forms.Label
$homeDetailIcon.Dock = [System.Windows.Forms.DockStyle]::Fill
$homeDetailIcon.Text = 'Select an analysis module'
$homeDetailIcon.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$homeDetailIcon.BackColor = $greenSoft
$homeDetailIcon.ForeColor = $green
$homeDetailIcon.Font = New-Object System.Drawing.Font('Segoe UI', [single]16, [System.Drawing.FontStyle]::Bold)
$homeDetailIcon.Margin = New-Object System.Windows.Forms.Padding(45, 0, 45, 0)
$homeDetailLayout.Controls.Add($homeDetailIcon, 0, 1)
$homeDetailTitle = New-TableLabel 'Select RNA-seq processing'
$homeDetailTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$homeDetailTitle.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$homeDetailTitle.ForeColor = $greenDark
$homeDetailTitle.Visible = $false
$homeDetailLayout.Controls.Add($homeDetailTitle, 0, 2)
$homeDetailBodyHost = New-Object System.Windows.Forms.Panel
$homeDetailBodyHost.Dock = [System.Windows.Forms.DockStyle]::Fill
$homeDetailBodyHost.Margin = New-Object System.Windows.Forms.Padding(18, 4, 18, 4)
$homeDetailLayout.Controls.Add($homeDetailBodyHost, 0, 3)
$homeDetailSectionHeading = New-Label 'SELECT AN ANALYSIS MODULE' 12 5 800 34 -Bold
$homeDetailSectionHeading.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$homeDetailSectionHeading.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$homeDetailSectionHeading.Font = New-Object System.Drawing.Font('Segoe UI', [single]13.5, [System.Drawing.FontStyle]::Bold)
$homeDetailSectionHeading.ForeColor = $greenDark
$homeDetailSectionHeading.Padding = New-Object System.Windows.Forms.Padding(12, 2, 12, 0)
$homeDetailBodyHost.Controls.Add($homeDetailSectionHeading)
$homeDetailBody = New-Label 'Information about the selected analysis module will appear here before you continue.' 12 48 800 74
$homeDetailBody.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$homeDetailBody.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
$homeDetailBody.Font = New-Object System.Drawing.Font('Segoe UI', [single]10.25)
$homeDetailBody.ForeColor = $ink
$homeDetailBody.Padding = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
$homeDetailBodyHost.Controls.Add($homeDetailBody)
$homeWorkflowTitle = New-Label '' 24 120 760 26 -Bold
$homeWorkflowTitle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$homeWorkflowTitle.Font = New-Object System.Drawing.Font('Segoe UI', [single]11.5, [System.Drawing.FontStyle]::Bold)
$homeWorkflowTitle.ForeColor = $greenDark
$homeWorkflowTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$homeDetailBodyHost.Controls.Add($homeWorkflowTitle)
$homeWorkflowStrip = New-Object System.Windows.Forms.Panel
$homeWorkflowStrip.Location = New-Object System.Drawing.Point(12, 150)
$homeWorkflowStrip.Size = New-Object System.Drawing.Size(800, 145)
$homeWorkflowStrip.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$homeWorkflowStrip.Padding = New-Object System.Windows.Forms.Padding(4, 5, 4, 4)
$homeWorkflowStrip.BackColor = $background
$homeDetailBodyHost.Controls.Add($homeWorkflowStrip)
# Introductory body text uses the same high-contrast ink colour as the
# rSeqTU and OpDetect descriptions. The footer is sized to the available
# panel, so a permanently visible scrollbar is unnecessary.
$homeDetailFooter = New-Object System.Windows.Forms.RichTextBox
$homeDetailFooter.Location = New-Object System.Drawing.Point(24, 303)
$homeDetailFooter.Size = New-Object System.Drawing.Size(760, 98)
$homeDetailFooter.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$homeDetailFooter.ReadOnly = $true
$homeDetailFooter.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$homeDetailFooter.BackColor = $surface
$homeDetailFooter.ForeColor = $ink
$homeDetailFooter.Font = $script:DescriptionBodyFont
$homeDetailFooter.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::None
$homeDetailFooter.DetectUrls = $false
$homeDetailFooter.TabStop = $false
$homeDetailBodyHost.Controls.Add($homeDetailFooter)


# The operon overview uses two full-width paragraphs. The typography now
# matches the introductory text above it, while the vertical layout uses the
# available space without a scrollbar or card borders.
$homeOperonOverview = New-Object System.Windows.Forms.Panel
$homeOperonOverview.Location = New-Object System.Drawing.Point(24, 120)
$homeOperonOverview.Size = New-Object System.Drawing.Size(760, 300)
$homeOperonOverview.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$homeOperonOverview.BackColor = $surface
$homeOperonOverview.Visible = $false
$homeDetailBodyHost.Controls.Add($homeOperonOverview)

$homeOperonSummary = New-Label 'THIS MODULE CONTAINS TWO TRANSCRIPTION-UNIT PREDICTION TOOLS' 0 0 760 30 -Bold
$homeOperonSummary.Font = $script:DescriptionHeaderFont
$homeRSeqHeadingFont = $script:DescriptionHeaderFont
$homeOperonSummary.ForeColor = $greenDark
$homeOperonSummary.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$homeOperonSummary.AutoEllipsis = $false
$homeOperonOverview.Controls.Add($homeOperonSummary)

$homeRSeqHeading = New-Label '1. rSeqTU' 0 34 760 27 -Bold
$homeRSeqHeading.Font = $homeRSeqHeadingFont
$homeRSeqHeading.ForeColor = $greenDark
$homeOperonOverview.Controls.Add($homeRSeqHeading)
$homeRSeqBody = New-Label 'Starts from one coordinate-sorted, stranded RNA-seq BAM plus matching bacterial FASTA and GFF3 or GTF annotation. It evaluates coverage continuity and genomic features, then applies feature selection and an SVM to predict transcription-unit boundaries. Use it when a trusted BAM already exists and a transparent single-sample workflow is preferred. It was validated mainly with short-read RNA-seq, so long-read-derived BAM results are exploratory. Requires R, matching sequence IDs, correct strand orientation, writable output, and adequate disk space.' 0 64 760 86
$homeRSeqBody.Font = $script:DescriptionBodyFont
$homeRSeqBody.ForeColor = $ink
$homeRSeqBody.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
$homeRSeqBody.AutoEllipsis = $false
$homeRSeqBody.UseCompatibleTextRendering = $false
$homeOperonOverview.Controls.Add($homeRSeqBody)

$homeOpDetectHeading = New-Label '2. OpDetect' 0 153 760 27 -Bold
$homeOpDetectHeading.Font = $homeRSeqHeadingFont
$homeOpDetectHeading.ForeColor = $greenDark
$homeOperonOverview.Controls.Add($homeOpDetectHeading)
$homeOpDetectBody = New-Label 'Starts from one to six biological short-read FASTQ libraries from one condition; each library may be single-end or explicitly paired-end. It performs quality control, HISAT2 alignment, per-base coverage extraction, ten CNN-LSTM model folds, and replicate-consensus operon prediction. Use it when raw reads are available and a species-independent deep-learning workflow is preferred. Long-read FASTQ, long-read BAM, and POD5 are not accepted. Requires Windows 10 or 11, WSL2 with Ubuntu, matching FASTA and annotation files, at least 16 GB RAM, and about 20 GB free disk space.' 0 183 760 94
$homeOpDetectBody.Font = $script:DescriptionBodyFont
$homeOpDetectBody.ForeColor = $ink
$homeOpDetectBody.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
$homeOpDetectBody.AutoEllipsis = $false
$homeOpDetectBody.UseCompatibleTextRendering = $false
$homeOperonOverview.Controls.Add($homeOpDetectBody)

function Layout-HomeOperonOverview {
    if (-not $homeOperonOverview -or $homeOperonOverview.IsDisposed) { return }
    $availableWidth = [Math]::Max(300, $homeOperonOverview.ClientSize.Width)
    foreach ($control in @($homeOperonSummary, $homeRSeqHeading, $homeRSeqBody, $homeOpDetectHeading, $homeOpDetectBody)) {
        $control.Width = $availableWidth
    }

    # Keep both descriptions visible. Their preferred wrapped heights are
    # measured, then fitted into the available panel without a large blank gap.
    $availableHeight = [Math]::Max(220, $homeOperonOverview.ClientSize.Height)
    $measureWidth = [Math]::Max(260, ($availableWidth - 4))
    $measureSize = [System.Drawing.Size]::new([int]$measureWidth, 1000)
    $measureFlags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    $wantedRSeq = [System.Windows.Forms.TextRenderer]::MeasureText($homeRSeqBody.Text, $homeRSeqBody.Font, $measureSize, $measureFlags).Height + 4
    $wantedOpDetect = [System.Windows.Forms.TextRenderer]::MeasureText($homeOpDetectBody.Text, $homeOpDetectBody.Font, $measureSize, $measureFlags).Height + 4

    $rSeqBodyTop = 64
    $betweenMethods = 8
    $methodHeadingHeight = 27
    $headingToBody = 3
    $bodySpace = [Math]::Max(110, ($availableHeight - $rSeqBodyTop - $betweenMethods - $methodHeadingHeight - $headingToBody))
    $wantedTotal = [Math]::Max(1, ($wantedRSeq + $wantedOpDetect))
    if ($wantedTotal -le $bodySpace) {
        $rSeqHeight = $wantedRSeq
        $opDetectHeight = $wantedOpDetect
    }
    else {
        $rSeqHeight = [Math]::Max(55, [int][Math]::Floor($bodySpace * ($wantedRSeq / $wantedTotal)))
        $opDetectHeight = [Math]::Max(55, ($bodySpace - $rSeqHeight))
        if (($rSeqHeight + $opDetectHeight) -gt $bodySpace) {
            $opDetectHeight = [Math]::Max(45, ($bodySpace - $rSeqHeight))
        }
    }

    $homeRSeqBody.Top = $rSeqBodyTop
    $homeRSeqBody.Height = $rSeqHeight
    $homeOpDetectHeading.Top = $homeRSeqBody.Bottom + $betweenMethods
    $homeOpDetectBody.Top = $homeOpDetectHeading.Bottom + $headingToBody
    $homeOpDetectBody.Height = [Math]::Max(45, ($availableHeight - $homeOpDetectBody.Top))
}
$homeOperonOverview.Add_Resize({ Layout-HomeOperonOverview })

function Layout-HomeIntroductionContent {
    if (-not $homeDetailBodyHost -or $homeDetailBodyHost.IsDisposed) { return }
    $contentWidth = [Math]::Max(340, ($homeDetailBodyHost.ClientSize.Width - 24))
    $innerWidth = [Math]::Max(300, ($homeDetailBodyHost.ClientSize.Width - 48))
    $homeDetailSectionHeading.Width = $contentWidth
    $homeDetailBody.Width = $contentWidth
    $homeWorkflowTitle.Width = $innerWidth
    $homeWorkflowStrip.Width = $contentWidth
    $homeDetailFooter.Width = $innerWidth
    $homeOperonOverview.Width = $innerWidth

    if ($script:HomeDetailWorkflowVisible) {
        $homeDetailBody.SetBounds(12, 48, $contentWidth, 74)
        $homeDetailFooter.SetBounds(24, 303, $innerWidth, [Math]::Max(70, ($homeDetailBodyHost.ClientSize.Height - 311)))
        if (Get-Command Layout-HomeWorkflowDiagram -ErrorAction SilentlyContinue) { Layout-HomeWorkflowDiagram }
        return
    }

    # Measure the introductory paragraph instead of reserving a fixed 74-pixel
    # block. This removes the large blank gap before the first section heading.
    $measureFlags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    $measureSize = New-Object System.Drawing.Size([Math]::Max(260, ($contentWidth - 24)), 1000)
    $measuredBody = [System.Windows.Forms.TextRenderer]::MeasureText($homeDetailBody.Text, $homeDetailBody.Font, $measureSize, $measureFlags)
    $bodyHeight = [Math]::Max(38, [Math]::Min(92, ($measuredBody.Height + 8)))
    $homeDetailBody.SetBounds(12, 48, $contentWidth, $bodyHeight)
    # Keep a clear visual break between the introductory WHY paragraph and
    # the next section heading on every module introduction page.
    $contentTop = $homeDetailBody.Bottom + 14
    $contentHeight = [Math]::Max(150, ($homeDetailBodyHost.ClientSize.Height - $contentTop - 2))
    $homeDetailFooter.SetBounds(24, $contentTop, $innerWidth, $contentHeight)
    $homeOperonOverview.SetBounds(24, $contentTop, $innerWidth, $contentHeight)
    if ($homeOperonOverview.Visible) { Layout-HomeOperonOverview }
}

function Set-HomeDetailFooterContent([string]$Text) {
    Set-DescriptionPanelText -Box $homeDetailFooter -Text $Text
    # Use exactly the same Segoe UI body font as the paragraph below the WHY
    # heading. Only section headings change weight and size.
    $homeDetailFooter.SelectAll()
    $homeDetailFooter.SelectionFont = $script:DescriptionBodyFont
    $homeDetailFooter.SelectionColor = $ink
    $headingRegex = '(?m)^[A-Z][A-Z0-9 /+&-]{2,}\r?$'
    foreach ($headingMatch in [System.Text.RegularExpressions.Regex]::Matches($homeDetailFooter.Text, $headingRegex)) {
        $headingLength = $headingMatch.Length
        if ($headingLength -gt 0 -and $headingMatch.Value.EndsWith("`r")) { $headingLength-- }
        $homeDetailFooter.Select($headingMatch.Index, $headingLength)
        $homeDetailFooter.SelectionFont = $script:HelpHeaderFont
        $homeDetailFooter.SelectionColor = $greenDark
    }
    $homeDetailFooter.Select(0, 0)
    Layout-HomeIntroductionContent
}
$script:HomeDetailWorkflowVisible = $true
$homeDetailBodyHost.Add_Resize({ Layout-HomeIntroductionContent })
$homeDetailBody.Add_TextChanged({ Layout-HomeIntroductionContent })
$homeDetailButton = New-Button 'Open RNA-seq processing' 0 0 470 50 -Primary
$homeDetailButton.Font = New-Object System.Drawing.Font('Segoe UI', [single]11.5, [System.Drawing.FontStyle]::Bold)
$homeDetailButton.Anchor = [System.Windows.Forms.AnchorStyles]::None
$homeDetailButton.AutoEllipsis = $false
$homeDetailButton.Visible = $false
$homeDetailLayout.Controls.Add($homeDetailButton, 0, 4)

$script:SelectedHomeModule = ''
$script:HomeWorkflowSteps = @()

function Layout-HomeWorkflowDiagram {
    if (-not $homeWorkflowStrip -or $homeWorkflowStrip.IsDisposed) { return }
    $visibleWidth = [Math]::Max(180, $homeWorkflowStrip.ClientSize.Width)
    $availableWidth = [Math]::Max(172, ($visibleWidth - 8))
    $connectorWidth = [Math]::Max(6, [Math]::Min(22, [int][Math]::Floor($availableWidth * 0.035)))
    $boxWidth = [Math]::Max(32, [int][Math]::Floor(($availableWidth - (3 * $connectorWidth)) / 4))
    $diagramWidth = (4 * $boxWidth) + (3 * $connectorWidth)
    $startX = 4 + [Math]::Max(0, [int][Math]::Floor(($availableWidth - $diagramWidth) / 2))
    $boxHeight = 60
    foreach ($control in $homeWorkflowStrip.Controls) {
        if (-not $control.Tag) { continue }
        if ([string]$control.Tag.Kind -eq 'Step') {
            $stepIndex = [int]$control.Tag.Index
            $column = if ($stepIndex -lt 4) { $stepIndex } else { 7 - $stepIndex }
            $top = if ($stepIndex -lt 4) { 2 } else { 82 }
            $left = $startX + ($column * ($boxWidth + $connectorWidth))
            $control.SetBounds($left, $top, $boxWidth, $boxHeight)
        }
        elseif ([string]$control.Tag.Kind -eq 'Arrow') {
            $fromIndex = [int]$control.Tag.From
            if ($fromIndex -lt 3) {
                $left = $startX + (($fromIndex + 1) * $boxWidth) + ($fromIndex * $connectorWidth)
                $control.SetBounds($left, 2, $connectorWidth, $boxHeight)
            }
            elseif ($fromIndex -eq 3) {
                $rightColumnLeft = $startX + (3 * ($boxWidth + $connectorWidth))
                $control.SetBounds(($rightColumnLeft + [int](($boxWidth - $connectorWidth) / 2)), 62, $connectorWidth, 20)
            }
            else {
                $rightColumn = 7 - $fromIndex
                $left = $startX + ($rightColumn * ($boxWidth + $connectorWidth)) - $connectorWidth
                $control.SetBounds($left, 82, $connectorWidth, $boxHeight)
            }
        }
    }
}

function Set-HomeWorkflowDiagram([string[]]$Steps) {
    $homeWorkflowStrip.SuspendLayout()
    try {
        $script:HomeWorkflowSteps = @($Steps)
        $homeWorkflowStrip.Controls.Clear()
        for ($stepIndex = 0; $stepIndex -lt $Steps.Count; $stepIndex++) {
            $stepBox = New-Object System.Windows.Forms.Label
            $stepBox.Text = "$(($stepIndex + 1)). $([string]$Steps[$stepIndex])"
            $stepBox.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
            $stepBox.Font = New-Object System.Drawing.Font('Segoe UI', [single]8, [System.Drawing.FontStyle]::Bold)
            $stepBox.Padding = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
            $stepBox.AutoEllipsis = $false
            if (($stepIndex % 2) -eq 0) {
                $stepBox.BackColor = $greenSoft
                $stepBox.ForeColor = $greenDark
            }
            else {
                $stepBox.BackColor = $blueSoft
                $stepBox.ForeColor = $blue
            }
            $stepBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            $stepBox.Tag = [pscustomobject]@{ Kind = 'Step'; Index = $stepIndex }
            $stepBox.Add_Click({ Show-HomeOverviewPoster })
            [void]$homeWorkflowStrip.Controls.Add($stepBox)
            if ($stepIndex -lt ($Steps.Count - 1)) {
                $arrow = New-Object System.Windows.Forms.Label
                if ($stepIndex -lt 3) { $arrow.Text = [char]0x2192 }
                elseif ($stepIndex -eq 3) { $arrow.Text = [char]0x2193 }
                else { $arrow.Text = [char]0x2190 }
                $arrow.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
                $arrow.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 14, [System.Drawing.FontStyle]::Bold)
                $arrow.ForeColor = $green
                $arrow.Tag = [pscustomobject]@{ Kind = 'Arrow'; From = $stepIndex }
                $arrow.Add_Click({ Show-HomeOverviewPoster })
                [void]$homeWorkflowStrip.Controls.Add($arrow)
            }
        }
        Layout-HomeWorkflowDiagram
    }
    finally { $homeWorkflowStrip.ResumeLayout() }
}

function Set-HomeDetailWorkflowVisibility([bool]$Visible) {
    $script:HomeDetailWorkflowVisible = $Visible
    $homeWorkflowTitle.Visible = $Visible
    $homeWorkflowStrip.Visible = $Visible
    Layout-HomeIntroductionContent
}

function Show-HomeOverviewPoster {
    $script:SelectedHomeModule = ''
    $homeOperonOverview.Visible = $false
    $homeDetailFooter.Visible = $true
    Set-HomeDetailWorkflowVisibility $true
    $homeDetailIcon.Text = 'GENERAL STEPS IN BACTERIAL RNA-SEQ ANALYSIS'
    $homeDetailSectionHeading.Text = 'WHY THE WORKFLOW MATTERS'
    $homeDetailBody.Text = 'Each stage affects the next. Strong biological replication, intact RNA, appropriate rRNA depletion, strand-aware libraries, careful read QC, and reference-compatible alignment are needed before expression or transcription-unit results can be trusted.'
    $homeWorkflowTitle.Text = 'FROM EXPERIMENTAL DESIGN TO ANALYSIS-READY EVIDENCE'
    Set-HomeWorkflowDiagram @(
        'Study design + biological replicates',
        'RNA extraction + integrity checks',
        'rRNA depletion + stranded library',
        'Short-read or long-read sequencing',
        'Raw-read QC + cleaning / basecalling',
        'Bacterial genome alignment',
        'BAM/BAI + counts + coverage',
        'DE, pathways, networks, transcripts + operons'
    )
    Set-HomeDetailFooterContent 'Select a module on the left to continue. RNA-seq processing prepares reusable evidence. Differential expression, functional/pathway enrichment, expression and STRING networks, transcript discovery, and operon/TU analysis open as integrated modules inside this same window.'
    $homeDetailButton.Text = 'Open overall software guide'
    $homeDetailButton.Visible = $true
    foreach ($card in @($processingCard, $deCard, $goCard, $networkCard, $transcriptCard, $operonCard)) { $card.BackColor = $surface }
}

Show-HomeOverviewPoster

$processingCard.Cursor = [System.Windows.Forms.Cursors]::Hand
$processingCard.Tag.heading.Cursor = [System.Windows.Forms.Cursors]::Hand
$processingCard.Tag.body.Cursor = [System.Windows.Forms.Cursors]::Hand
$selectProcessing = {
    $script:SelectedHomeModule = 'rna'
    $homeOperonOverview.Visible = $false
    $homeDetailFooter.Visible = $true
    Set-HomeDetailWorkflowVisibility $false
    $homeDetailIcon.Text = 'RNA-seq processing tools'
    $homeDetailIcon.Font = New-Object System.Drawing.Font('Segoe UI', [single]16, [System.Drawing.FontStyle]::Bold)
    $homeDetailSectionHeading.Text = 'WHY PROCESS RNA-SEQ DATA?'
    $homeDetailBody.Text = 'Raw reads can contain adapters, low-quality sequence, platform-specific errors, contamination, and strand or annotation mismatches. Detecting these issues before downstream analysis protects mapping, counts, and biological conclusions.'
    Set-HomeDetailFooterContent "SUPPORTED INPUTS`r`nShort-read input may be single-end or paired-end Illumina/DNBSEQ FASTQ. Long-read input may be Oxford Nanopore or PacBio FASTQ, unaligned BAM, or Oxford Nanopore POD5. Combined projects keep short- and long-read BAM families separate.`r`n`r`nREQUIRED INPUTS`r`nProvide a bacterial FASTA, matching GFF3/GTF, Sample ID, biological condition, replicate number, and read files. A project may contain Control, Treatment, time points, strains, mutants, or any number of other conditions. Batch is optional. POD5 also requires Dorado and a chemistry-matched model.`r`n`r`nWORKFLOW`r`nThe module validates references, assesses and cleans or basecalls reads, aligns samples, sorts and indexes BAMs, audits strand orientation, and prepares reusable downstream evidence.`r`n`r`nFINAL USER RESULTS`r`nAfter a successful run the selected Results folder is simplified to Counts & Annotation.xlsx, BAM-BAI-IGV, QC Analysis.html, and intermediate. The intermediate folder retains reference, coverage, metadata, raw QC details, provenance, and other technical handoff files required by downstream modules."
    $homeDetailButton.Text = 'Open RNA-seq processing'
    $homeDetailButton.Visible = $true
    foreach ($card in @($processingCard, $deCard, $goCard, $networkCard, $transcriptCard, $operonCard)) { $card.BackColor = $surface }
    $processingCard.BackColor = $greenSoft
}
$processingCard.Add_Click($selectProcessing)
$processingCard.Tag.heading.Add_Click($selectProcessing)
$processingCard.Tag.body.Add_Click($selectProcessing)


$deCard.Cursor = [System.Windows.Forms.Cursors]::Hand
$deCard.Tag.heading.Cursor = [System.Windows.Forms.Cursors]::Hand
$deCard.Tag.body.Cursor = [System.Windows.Forms.Cursors]::Hand
$selectDifferentialExpression = {
    $script:SelectedHomeModule = 'de'
    $homeOperonOverview.Visible = $false
    $homeDetailFooter.Visible = $true
    Set-HomeDetailWorkflowVisibility $false
    $homeDetailIcon.Text = 'Differential expression analysis'
    $homeDetailIcon.Font = New-Object System.Drawing.Font('Segoe UI', [single]16, [System.Drawing.FontStyle]::Bold)
    $homeDetailSectionHeading.Text = 'WHY COMPARE GENE EXPRESSION?'
    $homeDetailBody.Text = 'Differential-expression analysis identifies genes whose abundance changes reproducibly between biological conditions. It combines effect size with statistical uncertainty so that changes can be prioritized rather than judged from raw counts alone.'
    Set-HomeDetailFooterContent "WHEN TO USE`r`nUse raw integer gene counts with complete metadata. At least three biological replicates are required in every compared group. Batch must not be confounded with condition.`r`n`r`nREQUIRED INPUTS`r`nProvide raw counts and sample metadata. TPM, FPKM, percentages, and already normalized values are not valid count-based inputs. An optional 1-based gene-coordinate table enables IGV export.`r`n`r`nINCLUDED R ENGINES`r`nedgeR quasi-likelihood is the recommended fast default with strong error control. DESeq2 provides established dispersion and shrinkage workflows. limma-voom is strong for multifactor designs and many contrasts but needs a reliable mean-variance trend.`r`n`r`nOUTPUTS AND INTERPRETATION`r`nOutputs include filtered and normalized counts, complete statistics, diagnostics, a full code-and-command log, selected interactive plots, and an automatic signed log2FC bedGraph when coordinates are supplied. Associations do not by themselves prove regulation or causation."
    $homeDetailButton.Text = 'Open Differential Expression'
    $homeDetailButton.Visible = $true
    foreach ($card in @($processingCard, $deCard, $goCard, $networkCard, $transcriptCard, $operonCard)) { $card.BackColor = $surface }
    $deCard.BackColor = $greenSoft
}
$deCard.Add_Click($selectDifferentialExpression)
$deCard.Tag.heading.Add_Click($selectDifferentialExpression)
$deCard.Tag.body.Add_Click($selectDifferentialExpression)

$goCard.Cursor = [System.Windows.Forms.Cursors]::Hand
$goCard.Tag.heading.Cursor = [System.Windows.Forms.Cursors]::Hand
$goCard.Tag.body.Cursor = [System.Windows.Forms.Cursors]::Hand
$selectEnrichment = {
    $script:SelectedHomeModule = 'enrichment'
    $homeOperonOverview.Visible = $false
    $homeDetailFooter.Visible = $true
    Set-HomeDetailWorkflowVisibility $false
    $homeDetailIcon.Text = 'Functional enrichment and biological networks'
    $homeDetailIcon.Font = New-Object System.Drawing.Font('Segoe UI', [single]16, [System.Drawing.FontStyle]::Bold)
    $homeDetailSectionHeading.Text = 'WHY ANALYZE FUNCTIONS AND CO-EXPRESSION TOGETHER?'
    $homeDetailBody.Text = 'One workspace now connects GO and pathway interpretation with expression-derived modules, regulatory hypotheses, and STRING protein-association evidence.'
    Set-HomeDetailFooterContent "WHEN TO USE`r`nUse DE results or a signed ranking for enrichment. Use a broad normalized expression matrix with independent samples for co-expression; 20 or more samples are preferable. The same run can add KEGG pathway and STRING protein-association evidence.`r`n`r`nSHARED INPUTS`r`nConfigure GO/custom mappings or UniProt once. One selected-gene set and tested-gene universe are then reused by GO enrichment, co-expression, KEGG, and STRING without opening separate analysis pages.`r`n`r`nINCLUDED METHODS`r`nclusterProfiler, fgsea and topGO; CEMiTool, WGCNA and GENIE3; online KEGG pathway ORA; and STRING PPI.`r`n`r`nOUTPUTS`r`nOne verified Excel workbook and one linked interactive HTML report contain enriched terms, pathway results, contributing genes, modules, eigengenes, hubs, traits, and STRING/network tables with reproducible logs."
    $homeDetailButton.Text = 'Open Functional Analysis Workspace'
    $homeDetailButton.Visible = $true
    foreach ($card in @($processingCard, $deCard, $goCard, $networkCard, $transcriptCard, $operonCard)) { $card.BackColor = $surface }
    $goCard.BackColor = $greenSoft
}
$goCard.Add_Click($selectEnrichment)
$goCard.Tag.heading.Add_Click($selectEnrichment)
$goCard.Tag.body.Add_Click($selectEnrichment)

$networkCard.Cursor = [System.Windows.Forms.Cursors]::Hand
$networkCard.Tag.heading.Cursor = [System.Windows.Forms.Cursors]::Hand
$networkCard.Tag.body.Cursor = [System.Windows.Forms.Cursors]::Hand
$selectNetworks = {
    $script:SelectedHomeModule = 'string'
    $homeOperonOverview.Visible = $false
    $homeDetailFooter.Visible = $true
    Set-HomeDetailWorkflowVisibility $false
    $homeDetailIcon.Text = 'STRING protein associations'
    $homeDetailIcon.Font = New-Object System.Drawing.Font('Segoe UI', [single]16, [System.Drawing.FontStyle]::Bold)
    $homeDetailSectionHeading.Text = 'WHY ADD PROTEIN-ASSOCIATION EVIDENCE?'
    $homeDetailBody.Text = 'STRING provides curated and predicted physical or functional associations for bacterial proteins. It is a separate evidence layer from expression-derived co-expression modules.'
    Set-HomeDetailFooterContent "WHEN TO USE`r`nUse a bacterial gene/protein list when you want STRING physical or functional association evidence.`r`n`r`nDATA REQUIREMENTS`r`nProvide identifiers and, whenever possible, an organism taxonomy ID for accurate mapping.`r`n`r`nOUTPUTS`r`nMapped and unmapped identifiers, scored STRING edges, interactive networks, Excel tables, and GraphML exports. STRING confidence is evidence confidence, not binding strength."
    $homeDetailButton.Text = 'Open STRING Protein Associations'
    $homeDetailButton.Visible = $true
    foreach ($card in @($processingCard, $deCard, $goCard, $networkCard, $transcriptCard, $operonCard)) { $card.BackColor = $surface }
    $networkCard.BackColor = $greenSoft
}
$networkCard.Add_Click($selectNetworks)
$networkCard.Tag.heading.Add_Click($selectNetworks)
$networkCard.Tag.body.Add_Click($selectNetworks)

$transcriptCard.Cursor = [System.Windows.Forms.Cursors]::Hand
$transcriptCard.Tag.heading.Cursor = [System.Windows.Forms.Cursors]::Hand
$transcriptCard.Tag.body.Cursor = [System.Windows.Forms.Cursors]::Hand
$selectTranscriptDiscovery = {
    $script:SelectedHomeModule = 'transcript'
    $homeOperonOverview.Visible = $false
    $homeDetailFooter.Visible = $true
    Set-HomeDetailWorkflowVisibility $false
    $homeDetailIcon.Text = 'Transcript Discovery and RNA architecture evidence'
    $homeDetailIcon.Font = New-Object System.Drawing.Font('Segoe UI', [single]16, [System.Drawing.FontStyle]::Bold)
    $homeDetailSectionHeading.Text = 'WHY DISCOVER TRANSCRIPTS BEYOND ANNOTATED GENES?'
    $homeDetailBody.Text = 'Bacterial strand-specific RNA-seq can contain reproducible transcription outside known genes and on the opposite strand. This module reuses strand-aware RNA-seq coverage to generate candidate transcripts, classify antisense relationships, and rank small-RNA candidates without replacing the validated raw gene-count pipeline.'
    Set-HomeDetailFooterContent "RECOMMENDED INPUT`r`nSelect the completed RNA Processing Results folder. The module can locate the retained reference and strand-aware coverage under intermediate automatically. You may optionally add precomputed Rockhopper transcript evidence, RNAfold, and Infernal/Rfam.`r`n`r`nOUTPUTS`r`nThe module exports a formatted workbook, predicted transcript TSV, antisense table, candidate sRNA table, FASTA, GFF3 and BED. Rockhopper evidence is kept as an independent evidence source.`r`n`r`nINTERPRETATION`r`nThese are transcript candidates and architecture evidence. Ordinary RNA-seq boundaries are labelled coverage-inferred rather than experimentally validated TSS/TTS."
    $homeDetailButton.Text = 'Open Transcript Discovery'
    $homeDetailButton.Visible = $true
    foreach ($card in @($processingCard, $deCard, $goCard, $networkCard, $transcriptCard, $operonCard)) { $card.BackColor = $surface }
    $transcriptCard.BackColor = $greenSoft
}
$transcriptCard.Add_Click($selectTranscriptDiscovery)
$transcriptCard.Tag.heading.Add_Click($selectTranscriptDiscovery)
$transcriptCard.Tag.body.Add_Click($selectTranscriptDiscovery)

$operonCard.Cursor = [System.Windows.Forms.Cursors]::Hand
$operonCard.Tag.heading.Cursor = [System.Windows.Forms.Cursors]::Hand
$operonCard.Tag.body.Cursor = [System.Windows.Forms.Cursors]::Hand
$selectOperon = {
    $script:SelectedHomeModule = 'operon'
    Set-HomeDetailWorkflowVisibility $false
    $homeDetailFooter.Visible = $false
    $homeOperonOverview.Visible = $true
    $homeOperonOverview.BringToFront()
    Layout-HomeOperonOverview
    $homeDetailIcon.Text = 'Operons and transcription units prediction'
    $homeDetailIcon.Font = New-Object System.Drawing.Font('Segoe UI', [single]16, [System.Drawing.FontStyle]::Bold)
    $homeDetailSectionHeading.Text = 'WHY STUDY OPERONS AND TRANSCRIPTION UNITS?'
    $homeDetailBody.Text = 'Bacterial genes are often co-transcribed from one promoter. Reconstructing transcription units and operons helps explain coordinated expression, regulatory organization, internal promoters or terminators, and which genes are likely controlled together.'
    $homeDetailButton.Text = 'Open operon predictor'
    $homeDetailButton.Visible = $true
    foreach ($card in @($processingCard, $deCard, $goCard, $networkCard, $transcriptCard, $operonCard)) { $card.BackColor = $surface }
    $operonCard.BackColor = $greenSoft
}
$operonCard.Add_Click($selectOperon)
$operonCard.Tag.heading.Add_Click($selectOperon)
$operonCard.Tag.body.Add_Click($selectOperon)


# When a module description is open, clicking any non-module area of the first
# page returns to the original workflow introduction. Module cards and the
# primary launch button retain their own click actions because WinForms does
# not bubble child-control clicks to their parents.
$resetHomeIntroduction = {
    if ($homeSurface.Visible -and -not [string]::IsNullOrWhiteSpace($script:SelectedHomeModule)) {
        Show-HomeOverviewPoster
    }
}
foreach ($control in @(
    $homeSurface, $homeLayout, $moduleChooser, $moduleHeader, $moduleHeading,
    $moduleDescription, $moduleList, $homeDetailPanel, $homeDetailLayout,
    $homeDetailIcon, $homeDetailBodyHost, $homeDetailSectionHeading,
    $homeDetailBody, $homeWorkflowTitle, $homeWorkflowStrip, $homeDetailFooter,
    $homeOperonOverview, $homeOperonSummary, $homeRSeqHeading, $homeRSeqBody,
    $homeOpDetectHeading, $homeOpDetectBody
)) {
    if ($control) { $control.Add_Click($resetHomeIntroduction) }
}

function Show-HomeScreen {
    $header.Visible = $true
    $rootLayout.RowStyles[0].Height = 88
    $tabs.Visible = $false
    $topProjectActions.Visible = $false
    if ($operonSurface) { $operonSurface.Visible = $false }
    if ($moduleOverlay) { $moduleOverlay.Visible = $false }
    try { if ($enrichmentSelector) { $enrichmentSelector.Surface.Visible = $false }; if ($networkSelector) { $networkSelector.Surface.Visible = $false } } catch { }
    $homeSurface.Visible = $true
    $homeSurface.BringToFront()
    Show-HomeOverviewPoster
    $footer.Visible = $false
    $rootLayout.RowStyles[2].Height = 0
    $scope.Text = 'Choose an analysis module'
}

function Show-ProcessingWorkflow {
    $homeSurface.Visible = $false
    if ($operonSurface) { $operonSurface.Visible = $false }
    if ($moduleOverlay) { $moduleOverlay.Visible = $false }
    try { if ($enrichmentSelector) { $enrichmentSelector.Surface.Visible = $false }; if ($networkSelector) { $networkSelector.Surface.Visible = $false } } catch { }
    $tabs.Visible = $true
    $tabs.BringToFront()
    $topProjectActions.Visible = $true
    $topProjectActions.BringToFront()
    $footer.Visible = $true
    $rootLayout.RowStyles[2].Height = 58
    $scope.Text = 'RNA-seq processing'
    $tabs.SelectedTab = $pageType
    $backButton.Enabled = $true
}
$modulesButton.Add_Click({ Show-HomeScreen })
$homeDetailButton.Add_Click({
    if ([string]::IsNullOrWhiteSpace($script:SelectedHomeModule)) {
        $guide = Join-Path $script:SuiteRoot 'Documentation\User Guide.html'
        if (Test-Path -LiteralPath $guide) { Start-Process $guide } else { Show-Error 'The overall software guide is missing from the Documentation folder.' }
    }
    elseif ($script:SelectedHomeModule -eq 'operon') { Show-OperonSelector }
    elseif ($script:SelectedHomeModule -eq 'rna') { Show-ProcessingWorkflow }
    elseif ($script:SelectedHomeModule -eq 'de') { Open-EmbeddedDownstreamModule 'de' }
    elseif ($script:SelectedHomeModule -eq 'enrichment') { Open-EmbeddedDownstreamModule 'enrichment' }
    elseif ($script:SelectedHomeModule -in @('network','string')) { Open-EmbeddedDownstreamModule 'enrichment' }
    elseif ($script:SelectedHomeModule -eq 'transcript') { Open-EmbeddedScientificModule 'transcript' }
})

# Integrated Operon Prediction Suite selector. Both complete applications are
# hosted inside this top-level window instead of starting a second GUI process.
$operonSurface = New-Object System.Windows.Forms.Panel
$operonSurface.Dock = [System.Windows.Forms.DockStyle]::Fill
$operonSurface.BackColor = $background
$operonSurface.Visible = $false
$workspaceHost.Controls.Add($operonSurface)

$operonRoot = New-Object System.Windows.Forms.TableLayoutPanel
$operonRoot.Dock = [System.Windows.Forms.DockStyle]::Fill
$operonRoot.ColumnCount = 1
$operonRoot.RowCount = 2
$operonRoot.Padding = New-Object System.Windows.Forms.Padding(22, 12, 22, 18)
[void]$operonRoot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$operonRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 58)))
[void]$operonRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$operonSurface.Controls.Add($operonRoot)

$operonHeader = New-Object System.Windows.Forms.Panel
$operonHeader.Dock = [System.Windows.Forms.DockStyle]::Fill
$operonRoot.Controls.Add($operonHeader, 0, 0)
$operonTitle = New-Label 'Operon Prediction Suite' 2 2 520 30 -Bold
$operonTitle.Font = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
$operonTitle.ForeColor = $greenDark
$operonIntro = New-Label 'Choose an operon or transcription-unit analysis method.' 4 37 920 28
$operonIntro.ForeColor = $muted
$operonBackHome = New-Button '< Back to analysis modules' 0 5 205 36
$operonBackHome.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$operonBackHome.Location = New-Object System.Drawing.Point(1225, 5)
$operonHeader.Controls.AddRange(@($operonTitle, $operonIntro, $operonBackHome))
$operonHeader.Add_Resize({ $operonBackHome.Left = [Math]::Max(850, $operonHeader.ClientSize.Width - $operonBackHome.Width - 4) })

$operonColumns = New-Object System.Windows.Forms.TableLayoutPanel
$operonColumns.Dock = [System.Windows.Forms.DockStyle]::Fill
$operonColumns.ColumnCount = 2
$operonColumns.RowCount = 1
[void]$operonColumns.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 37)))
[void]$operonColumns.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 63)))
[void]$operonColumns.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$operonRoot.Controls.Add($operonColumns, 0, 1)

$operonChoicePanel = New-Object System.Windows.Forms.TableLayoutPanel
$operonChoicePanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$operonChoicePanel.ColumnCount = 1
$operonChoicePanel.RowCount = 5
$operonChoicePanel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)
[void]$operonChoicePanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$operonChoicePanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 74)))
[void]$operonChoicePanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 162)))
[void]$operonChoicePanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 162)))
[void]$operonChoicePanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 162)))
[void]$operonChoicePanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$operonColumns.Controls.Add($operonChoicePanel, 0, 0)

$operonChoiceHeader = New-Object System.Windows.Forms.Panel
$operonChoiceHeader.Dock = [System.Windows.Forms.DockStyle]::Fill
$chooseOperonHeading = New-Label 'CHOOSE A METHOD' 4 0 350 25 -Bold
$chooseOperonHeading.ForeColor = $greenDark
$chooseOperonHelp = New-Label 'Select a method to compare its inputs, workflow, strengths, limitations, and system requirements.' 4 27 430 40
$chooseOperonHelp.ForeColor = $muted
$chooseOperonHelp.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
$operonChoiceHeader.Controls.AddRange(@($chooseOperonHeading, $chooseOperonHelp))
$operonChoiceHeader.Add_Resize({
    $usable = [Math]::Max(240, ($operonChoiceHeader.ClientSize.Width - 8))
    $chooseOperonHeading.Width = $usable
    $chooseOperonHelp.Width = $usable
})
$operonChoicePanel.Controls.Add($operonChoiceHeader, 0, 0)

function New-OperonChoiceCard([string]$Name, [string]$Badge, [string]$Summary, [System.Drawing.Color]$AccentColor, [System.Drawing.Color]$BadgeColor) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $panel.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 5)
    $panel.BackColor = $surface
    $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $accent = New-Object System.Windows.Forms.Panel
    $accent.Dock = [System.Windows.Forms.DockStyle]::Left
    $accent.Width = 7
    $accent.BackColor = $AccentColor
    $nameLabel = New-Label $Name 24 6 350 28 -Bold
    $nameLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]13.25, [System.Drawing.FontStyle]::Bold)
    $badgePanel = New-Object System.Windows.Forms.Panel
    $badgePanel.Location = New-Object System.Drawing.Point(24, 36)
    $badgePanel.Size = New-Object System.Drawing.Size(320, 25)
    $badgePanel.BackColor = $BadgeColor
    $badgePanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $badgeLabel = New-Object System.Windows.Forms.Label
    $badgeLabel.Text = $Badge
    $badgeLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $badgeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $badgeLabel.BackColor = $BadgeColor
    $badgeLabel.ForeColor = $AccentColor
    $badgeLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]8.4, [System.Drawing.FontStyle]::Bold)
    $badgePanel.Controls.Add($badgeLabel)
    $summaryLabel = New-Label $Summary 24 65 385 37
    $summaryLabel.ForeColor = $muted
    $selectFrame = New-Object System.Windows.Forms.Panel
    $selectFrame.Location = New-Object System.Drawing.Point(24, 112)
    $selectFrame.Size = New-Object System.Drawing.Size(330, 30)
    $selectFrame.BackColor = $AccentColor
    $selectFrame.Padding = New-Object System.Windows.Forms.Padding(1)
    $selectButton = New-Button ("Select " + $Name) 0 0 328 28
    $selectButton.Dock = [System.Windows.Forms.DockStyle]::Fill
    $selectButton.FlatAppearance.BorderSize = 0
    $selectButton.BackColor = $surface
    $selectButton.ForeColor = $AccentColor
    $selectButton.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $selectFrame.Controls.Add($selectButton)
    foreach ($control in @($nameLabel, $badgePanel, $badgeLabel, $summaryLabel, $selectFrame)) {
        $control.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    }
    $panel.Controls.AddRange(@($accent, $nameLabel, $badgePanel, $summaryLabel, $selectFrame))
    $panel.Tag = [pscustomobject]@{ button = $selectButton; buttonFrame = $selectFrame; name = $nameLabel; badge = $badgePanel; badgeText = $badgeLabel; summary = $summaryLabel; accent = $accent }
    $panel.Add_Resize({
        param($sender, $eventArgs)
        $contentWidth = [Math]::Max(180, $sender.ClientSize.Width - 48)
        $badgeWidth = $contentWidth
        $sender.Tag.name.Location = New-Object System.Drawing.Point(24, 6)
        $sender.Tag.name.Size = New-Object System.Drawing.Size($contentWidth, 28)
        $sender.Tag.badge.Location = New-Object System.Drawing.Point(24, 36)
        $sender.Tag.badge.Size = New-Object System.Drawing.Size($badgeWidth, 25)
        $sender.Tag.summary.Location = New-Object System.Drawing.Point(24, 65)
        $sender.Tag.summary.Size = New-Object System.Drawing.Size($contentWidth, 36)
        $buttonTop = [Math]::Max(108, ($sender.ClientSize.Height - 38))
        $sender.Tag.buttonFrame.Location = New-Object System.Drawing.Point(24, $buttonTop)
        $sender.Tag.buttonFrame.Size = New-Object System.Drawing.Size($contentWidth, 30)
    })
    return $panel
}

$rSeqCard = New-OperonChoiceCard 'rSeqTU' 'STARTS FROM AN ALIGNED BAM' 'Windows and R transcription-unit prediction from one aligned bacterial RNA-seq BAM.' $green $greenSoft
$opDetectCard = New-OperonChoiceCard 'OpDetect' 'STARTS FROM RAW FASTQ' 'Replicate-aware QC, alignment, and deep-learning operon prediction from raw reads.' $blue $blueSoft
$tuArchitectureCard = New-OperonChoiceCard 'TU Architecture' 'STARTS FROM TRANSCRIPT DISCOVERY OUTPUT' 'Use predicted transcripts plus the matching RNA Processing reference to add boundary, RBS/start, terminator evidence, and manual TU curation.' $greenDark $greenSoft
$operonChoicePanel.Controls.Add($rSeqCard, 0, 1)
$operonChoicePanel.Controls.Add($opDetectCard, 0, 2)
$operonChoicePanel.Controls.Add($tuArchitectureCard, 0, 3)

$operonDetail = New-Object System.Windows.Forms.Panel
$operonDetail.Dock = [System.Windows.Forms.DockStyle]::Fill
$operonDetail.Margin = New-Object System.Windows.Forms.Padding(12, 5, 0, 5)
$operonDetail.BackColor = $surface
$operonDetail.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$operonColumns.Controls.Add($operonDetail, 1, 0)
$operonDetailMark = New-Label '?' 0 34 70 70 -Bold
$operonDetailMark.Font = New-Object System.Drawing.Font('Segoe UI', 27, [System.Drawing.FontStyle]::Bold)
$operonDetailMark.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$operonDetailMark.BackColor = $greenSoft
$operonDetailMark.ForeColor = $green
$operonDetailMark.Anchor = [System.Windows.Forms.AnchorStyles]::None
$operonDetailMark.Left = 385
$operonDetailTitle = New-Label 'Choose the method that matches your data' 80 118 760 40 -Bold
$operonDetailTitle.Font = New-Object System.Drawing.Font('Segoe UI', [single]16.5, [System.Drawing.FontStyle]::Bold)
$operonDetailTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$operonDetailTitle.Anchor = [System.Windows.Forms.AnchorStyles]::None
$operonDetailIntro = New-Object System.Windows.Forms.Panel
$operonDetailIntro.Location = New-Object System.Drawing.Point(42, 176)
$operonDetailIntro.Size = New-Object System.Drawing.Size(796, 360)
$operonDetailIntro.BackColor = $surface
$operonDetailIntro.Anchor = [System.Windows.Forms.AnchorStyles]::None

$operonIntroLayout = New-Object System.Windows.Forms.TableLayoutPanel
$operonIntroLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$operonIntroLayout.ColumnCount = 1
$operonIntroLayout.RowCount = 7
$operonIntroLayout.Margin = New-Object System.Windows.Forms.Padding(0)
$operonIntroLayout.Padding = New-Object System.Windows.Forms.Padding(0)
[void]$operonIntroLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$operonIntroLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 38)))
[void]$operonIntroLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
[void]$operonIntroLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 6)))
[void]$operonIntroLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
[void]$operonIntroLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 6)))
[void]$operonIntroLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.334)))
[void]$operonIntroLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30)))
$operonDetailIntro.Controls.Add($operonIntroLayout)

$operonIntroHeading = New-Object System.Windows.Forms.Label
$operonIntroHeading.Text = ''
$operonIntroHeading.Dock = [System.Windows.Forms.DockStyle]::Fill
$operonIntroHeading.Font = $script:DescriptionHeaderFont
$operonIntroHeading.ForeColor = $greenDark
$operonIntroHeading.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$operonIntroHeading.UseCompatibleTextRendering = $false
$operonIntroLayout.Controls.Add($operonIntroHeading, 0, 0)

function New-OperonIntroCard([string]$Heading, [string]$Body, [System.Drawing.Color]$AccentColor) {
    $card = New-Object System.Windows.Forms.Panel
    $card.Dock = [System.Windows.Forms.DockStyle]::Fill
    $card.Margin = New-Object System.Windows.Forms.Padding(0)
    $card.BackColor = $surface
    $card.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    $accent = New-Object System.Windows.Forms.Panel
    $accent.Dock = [System.Windows.Forms.DockStyle]::Left
    $accent.Width = 6
    $accent.BackColor = $AccentColor

    $headingLabel = New-Object System.Windows.Forms.Label
    $headingLabel.Text = $Heading
    $headingLabel.Dock = [System.Windows.Forms.DockStyle]::Top
    $headingLabel.Height = 36
    $headingLabel.Padding = New-Object System.Windows.Forms.Padding(12, 5, 10, 2)
    $headingLabel.Font = $script:DescriptionHeaderFont
    $headingLabel.ForeColor = $greenDark

    $bodyLabel = New-Object System.Windows.Forms.Label
    $bodyLabel.Text = $Body
    $bodyLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bodyLabel.Padding = New-Object System.Windows.Forms.Padding(12, 5, 12, 7)
    $bodyLabel.Font = $script:DescriptionBodyFont
    $bodyLabel.ForeColor = $ink
    $bodyLabel.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    $bodyLabel.UseCompatibleTextRendering = $false

    $card.Controls.Add($bodyLabel)
    $card.Controls.Add($headingLabel)
    $card.Controls.Add($accent)
    return $card
}

$operonIntroRSeqCard = New-OperonIntroCard '1. rSeqTU' 'Starts from one coordinate-sorted, stranded RNA-seq BAM with matching bacterial FASTA and annotation. It evaluates coverage continuity and genomic features, then applies random-forest feature selection and SVM prediction. Source reads may be single-end or paired-end after alignment. Validation focused on conventional short-read RNA-seq, so long-read-derived BAM results are exploratory.' $green
$operonIntroOpDetectCard = New-OperonIntroCard '2. OpDetect' 'Starts from one to six single-end or paired-end short-read FASTQ libraries from one condition. It performs QC, HISAT2 alignment, per-base coverage extraction, ten CNN-LSTM model folds, and replicate consensus. It requires WSL2 and more computing resources. Long-read FASTQ, BAM, and POD5 are not accepted by this implementation.' $blue
$operonIntroTUArchitectureCard = New-OperonIntroCard '3. TU Architecture' 'Starts from Transcript Discovery output plus the matching RNA Processing reference. It integrates coverage-inferred boundaries, putative leaders and extensions, optional RBS/start and terminator evidence, and an editable manual curation table without replacing rSeqTU or OpDetect predictions.' $greenDark
$operonIntroLayout.Controls.Add($operonIntroRSeqCard, 0, 1)
$operonIntroLayout.Controls.Add($operonIntroOpDetectCard, 0, 3)
$operonIntroLayout.Controls.Add($operonIntroTUArchitectureCard, 0, 5)

$operonIntroFooter = New-Object System.Windows.Forms.Label
$operonIntroFooter.Text = 'Select rSeqTU or OpDetect for prediction, or choose TU Architecture to integrate evidence and curate transcription units.'
$operonIntroFooter.Dock = [System.Windows.Forms.DockStyle]::Fill
$operonIntroFooter.Font = New-Object System.Drawing.Font('Segoe UI', [single]9, [System.Drawing.FontStyle]::Regular)
$operonIntroFooter.ForeColor = $muted
$operonIntroFooter.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$operonIntroFooter.UseCompatibleTextRendering = $false
$operonIntroLayout.Controls.Add($operonIntroFooter, 0, 6)

$operonInfo = New-Object System.Windows.Forms.RichTextBox
$operonInfo.Location = New-Object System.Drawing.Point(24, 88)
$operonInfo.Size = New-Object System.Drawing.Size(830, 500)
$operonInfo.Anchor = [System.Windows.Forms.AnchorStyles]::None
$operonInfo.ReadOnly = $true
$operonInfo.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$operonInfo.BackColor = $surface
$operonInfo.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$operonInfo.Visible = $false
$operonMethodHeader = New-Label '' 24 18 830 50 -Bold
$operonMethodHeader.Font = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
$operonMethodHeader.Anchor = [System.Windows.Forms.AnchorStyles]::None
$operonMethodHeader.Visible = $false
$operonReadInstructions = New-Button 'Read full instructions' 24 600 185 40
$operonContinue = New-Button 'Continue' 220 600 430 40 -Primary
foreach ($button in @($operonReadInstructions, $operonContinue)) {
    $button.Anchor = [System.Windows.Forms.AnchorStyles]::None
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $button.Visible = $false
}
$operonDetail.Controls.AddRange(@($operonDetailMark, $operonDetailTitle, $operonDetailIntro, $operonMethodHeader, $operonInfo, $operonReadInstructions, $operonContinue))
$operonDetail.Add_Resize({
    param($sender, $eventArgs)
    $detailWidth = [Math]::Max(360, $sender.ClientSize.Width)
    $detailHeight = [Math]::Max(420, $sender.ClientSize.Height)
    $sidePadding = 40
    $buttonTop = [Math]::Max(340, $detailHeight - 58)
    $operonDetailMark.Location = New-Object System.Drawing.Point(([int](($detailWidth - 70) / 2)), 34)
    $operonDetailTitle.Location = New-Object System.Drawing.Point($sidePadding, 118)
    $operonDetailTitle.Size = New-Object System.Drawing.Size(([Math]::Max(280, $detailWidth - (2 * $sidePadding))), 40)
    $operonDetailIntro.Location = New-Object System.Drawing.Point($sidePadding, 176)
    $operonDetailIntro.Size = New-Object System.Drawing.Size(([Math]::Max(280, $detailWidth - (2 * $sidePadding))), ([Math]::Max(250, $detailHeight - 204)))
    $operonMethodHeader.Location = New-Object System.Drawing.Point(24, 18)
    $operonMethodHeader.Size = New-Object System.Drawing.Size(([Math]::Max(300, $detailWidth - 48)), 50)
    $operonInfo.Location = New-Object System.Drawing.Point(24, 88)
    $operonInfo.Size = New-Object System.Drawing.Size(([Math]::Max(300, $detailWidth - 48)), ([Math]::Max(220, $buttonTop - 100)))
    $operonReadInstructions.Location = New-Object System.Drawing.Point(24, $buttonTop)
    $operonReadInstructions.Size = New-Object System.Drawing.Size(185, 40)
    $operonContinue.Location = New-Object System.Drawing.Point(220, $buttonTop)
    $operonContinue.Size = New-Object System.Drawing.Size(([Math]::Max(240, $detailWidth - 244)), 40)
})

$script:SelectedOperonMethod = ''
$rSeqTUInfo = @'
WHAT IT IS

rSeqTU predicts bacterial transcription units from one already aligned RNA-seq BAM file. The Windows interface runs the original rSeqTU feature-generation and SVM functions, then prepares QC, tabular predictions, cleaned annotation output, and IGV-ready coverage tracks.

GENERAL PROCEDURE

1. Validate the BAM, reference FASTA, annotation, sequence identifiers, and strand orientation.
2. Check R and install only missing CRAN or Bioconductor packages.
3. Generate read-quality and coverage information, calculate genomic and expression-continuity features, apply random-forest feature selection, and run SVM transcription-unit prediction.
4. Verify the final Excel workbook, cleaned SVM GFF, strand-aware bedGraph, BAM/BAI, QC report, and full console log.

READ TYPES AND SAMPLES

The interface starts from one coordinate-sorted BAM, so it does not require the original FASTQ files. A BAM generated from single-end or paired-end reads can be used when mapping, indexing, annotation compatibility, and strand orientation are correct. The published rSeqTU method was developed and validated mainly with conventional short-read RNA-seq. A long-read-derived BAM may be tested, but long-read-only accuracy was not established in the original study and the result should be treated as exploratory. rSeqTU processes one BAM per run and does not jointly model biological replicates.

DEVELOPMENT

rSeqTU was published on 15 May 2019 by Sheng-Yong Niu, Binqiang Liu, Qin Ma, and Wen-Chi Chou. The publication credits Niu with implementing the R package with Chou's help, and Niu, Ma, and Chou with designing the study. This integrated Windows interface was developed by Nguyen Hoang An and preserves the original algorithm attribution.

STRENGTHS

1. Starts from an existing BAM, so raw-read QC and alignment do not need to be repeated.
2. Runs directly on Windows and guides R detection and package installation.
3. Allows mapping-quality and base-quality thresholds to be adjusted.
4. Produces interpretable transcription-unit boundaries and browser-ready outputs.

LIMITATIONS

1. Processes one BAM per run and does not jointly model biological replicates.
2. Results depend on expression level, sequencing depth, mapping quality, strand information, and annotation accuracy.
3. The original validation focused on short-read RNA-seq rather than long-read-only data.
4. Model predictions are hypotheses, not experimental confirmation.

REQUIRED INPUTS AND SYSTEM

One coordinate-compatible, indexed or indexable, stranded RNA-seq BAM; matching GFF, GFF3, or GTF annotation; complete genomic DNA FASTA; known library orientation; and a writable result folder. Use 64-bit Windows 10 or 11, allow the interface to locate or install R, and reserve sufficient disk space for temporary coverage and feature matrices.
'@
$opDetectInfo = @'
WHAT IT IS

OpDetect starts from raw short-read RNA-seq FASTQ files, performs QC and alignment, converts alignments into nucleotide-level coverage features, runs ten deep-learning model folds, and exports replicate-aware operon predictions with consensus and uncertainty information.

GENERAL PROCEDURE

1. Validate one to six biological libraries, the complete reference FASTA, matching annotation, project name, output folder, and analysis settings.
2. Check WSL2, Ubuntu, the managed Python environment, Fastp, HISAT2, SAMtools, BEDtools, TensorFlow, and the pretrained OpDetect models.
3. Trim and filter each FASTQ library, align reads to the reference, sort and index BAM files, and extract per-base coverage separately for every replicate.
4. Integrate replicate signals, run the ten CNN-LSTM folds, classify adjacent same-strand gene pairs, assemble supported operons, and export workbooks, tracks, BAM/BAI, QC, and a run report.

READ TYPES AND SAMPLES

This implementation accepts one to six biological short-read libraries from one condition. Each library may be paired-end with two explicitly selected FASTQ mate files or true single-end FASTQ; paired-end filenames do not need R1/R2 tokens. Replicates remain separate during QC, alignment, and coverage generation before their evidence is integrated for prediction. Long-read FASTQ, long-read BAM, PacBio data, and ONT POD5 are not accepted because the published OpDetect preprocessing and pretrained models use short-read FASTQ-derived coverage.

DEVELOPMENT

OpDetect was published on 1 August 2025 by Rezvan Karaji and Lourdes Peña-Castillo at Memorial University of Newfoundland. The publication credits Karaji for software and Peña-Castillo for conceptualization, methodology, and supervision. This integrated Windows interface was developed by Nguyen Hoang An and preserves the original algorithm attribution.

STRENGTHS

1. Handles one to six biological replicates from one condition.
2. Accepts paired-end or single-end FASTQ and keeps replicate QC and coverage separate.
3. Automates Fastp, HISAT2, SAMtools, BEDtools, and the OpDetect neural models.
4. Uses nucleotide-level RNA-seq signals without requiring organism-specific operon databases.
5. Exports BAM/BAI, consensus and uncertainty measures, browser tracks, workbooks, and a run report.

LIMITATIONS

1. Requires WSL2, more setup, disk space, memory, and run time because it starts from raw reads and uses ten model folds.
2. The consensus strategy for fewer than six samples was not independently benchmarked in the original publication.
3. Complex noncontiguous operons, alternative promoters, and internal terminators remain difficult.
4. Long-read and POD5 input are outside the supported workflow.
5. Model predictions are hypotheses, not experimental confirmation.

REQUIRED INPUTS AND SYSTEM

One to six paired-end or single-end biological FASTQ libraries from one condition; complete genomic DNA FASTA; matching GFF, GFF3, or GTF annotation; and a writable result folder. Use 64-bit Windows 10 or 11 with WSL2 and Ubuntu. Internet access is normally needed for first installation or repair. At least 16 GB RAM and about 20 GB of free disk space are recommended, with additional space for large FASTQ and BAM files.
'@

$tuArchitectureInfo = @'
WHAT IT IS

TU Architecture is an evidence-and-curation layer around the existing operon predictions. It does not retrain or overwrite rSeqTU or OpDetect. It reuses Transcript Discovery candidates plus the matching FASTA/GFF to summarize transcript continuity and coverage-inferred boundaries, putative 5-prime leaders / 3-prime extensions, optional Prodigal translation-start/RBS evidence, imported terminator evidence, and a manual TU decision table.

GENERAL PROCEDURE

1. Start from a completed RNA Processing Results folder plus Transcript Discovery predicted_transcripts.tsv.
2. Relate same-strand transcript evidence to annotated genes and construct candidate transcription units.
3. Add optional Prodigal RBS/start-site evidence and verified terminator-call tables.
4. Review the editable TU table and record researcher decisions and notes.
5. Export accepted curated transcription units as GFF3 and BED while retaining the evidence separately.

IMPORTANT INTERPRETATION

Ordinary RNA-seq coverage boundaries are labelled coverage-inferred. Without TSS-enriched or experimental boundary data, the software reports a putative 5-prime leader rather than claiming an experimentally validated TSS or 5-prime UTR. RBS and terminator predictions are supporting evidence, not experimental confirmation.

OUTPUTS

Operon and transcription units.xlsx, manual_tu_review.tsv, curated_transcription_units.gff3, curated_transcription_units.bed, plus RBS/start and terminator evidence tables.
'@

function Show-OperonMethod([string]$Method) {
    $script:SelectedOperonMethod = $Method
    $operonDetailMark.Visible = $false
    $operonDetailTitle.Visible = $false
    $operonDetailIntro.Visible = $false
    $operonMethodHeader.Visible = $true
    $operonInfo.Visible = $true
    $operonReadInstructions.Visible = $true
    $operonContinue.Visible = $true
    if ($Method -eq 'rSeqTU') {
        $operonMethodHeader.Text = 'rSeqTU  |  Starts from an aligned BAM'
        $operonMethodHeader.BackColor = $greenSoft
        Set-DescriptionPanelText -Box $operonInfo -Text $rSeqTUInfo
        $operonContinue.Text = 'I understand and want to continue to rSeqTU'
        $operonContinue.BackColor = $green
        $rSeqCard.BackColor = $greenSoft
        $opDetectCard.BackColor = $surface
        $tuArchitectureCard.BackColor = $surface
    }
    elseif ($Method -eq 'OpDetect') {
        $operonMethodHeader.Text = 'OpDetect  |  Starts from raw FASTQ'
        $operonMethodHeader.BackColor = $blueSoft
        Set-DescriptionPanelText -Box $operonInfo -Text $opDetectInfo
        $operonContinue.Text = 'I understand and want to continue to OpDetect'
        $operonContinue.BackColor = $blue
        $rSeqCard.BackColor = $surface
        $opDetectCard.BackColor = $blueSoft
        $tuArchitectureCard.BackColor = $surface
    }
    else {
        $operonMethodHeader.Text = 'TU Architecture  |  Evidence + manual curation'
        $operonMethodHeader.BackColor = $greenSoft
        Set-DescriptionPanelText -Box $operonInfo -Text $tuArchitectureInfo
        $operonContinue.Text = 'Open TU Architecture and Manual Curation'
        $operonContinue.BackColor = $greenDark
        $rSeqCard.BackColor = $surface
        $opDetectCard.BackColor = $surface
        $tuArchitectureCard.BackColor = $greenSoft
    }
}

function Show-OperonSelector {
    $tabs.Visible = $false
    $topProjectActions.Visible = $false
    $homeSurface.Visible = $false
    try { $enrichmentSelector.Surface.Visible = $false; $networkSelector.Surface.Visible = $false } catch { }
    $moduleOverlay.Visible = $false
    $operonSurface.Visible = $true
    $operonSurface.BringToFront()
    $operonSurface.PerformLayout()
    $operonRoot.PerformLayout()
    $operonColumns.PerformLayout()
    $operonChoicePanel.PerformLayout()
    $operonDetail.PerformLayout()
    $operonSurface.Refresh()
    $footer.Visible = $false
    $rootLayout.RowStyles[2].Height = 0
    $scope.Text = 'Operons and transcription units'
}

function Open-OperonInstructions {
    if ($script:SelectedOperonMethod -eq 'rSeqTU') {
        $path = Join-Path $script:SuiteRoot 'Modules\Operon Prediction Suite\Applications\rSeqTU\Instructions.html'
    }
    elseif ($script:SelectedOperonMethod -eq 'OpDetect') {
        $path = Join-Path $script:SuiteRoot 'Modules\Operon Prediction Suite\Applications\OpDetect\Instructions.html'
    }
    elseif ($script:SelectedOperonMethod -eq 'TUArchitecture') {
        $path = Join-Path $script:SuiteRoot 'Modules\Operon Prediction Suite\Applications\TU Architecture\Instructions.html'
    }
    else { return }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Show-Error "The instruction file was not found: $path"; return }
    Start-Process -FilePath $path
}

$moduleOverlay = New-Object System.Windows.Forms.Panel
$moduleOverlay.Dock = [System.Windows.Forms.DockStyle]::Fill
$moduleOverlay.BackColor = $surface
$moduleOverlay.Visible = $false
$workspaceHost.Controls.Add($moduleOverlay)
$form.Tag.ModuleOverlay = $moduleOverlay
$form.Tag.EmbeddedModuleActive = $false

$script:StandaloneAnalysisProcess = $null
$script:StandaloneAnalysisTimer = $null
$script:StandaloneAnalysisActive = $false
$script:StandaloneShutdownSignal = ''
$script:StandaloneReadySignal = ''
$script:StandaloneStartupLog = ''
$script:StandaloneAnalysisReady = $false
$script:StandaloneModuleName = ''
$form.Tag.MainSuiteClosing = $false

function Restore-MainSuiteAfterStandaloneAnalysis {
    if ($script:StandaloneAnalysisTimer) { $script:StandaloneAnalysisTimer.Stop() }
    foreach ($marker in @($script:StandaloneShutdownSignal, $script:StandaloneReadySignal)) {
        if ($marker) {
            try { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    $script:StandaloneShutdownSignal = ''
    $script:StandaloneReadySignal = ''
    if ($script:StandaloneAnalysisProcess) { try { $script:StandaloneAnalysisProcess.Dispose() } catch { } }
    $script:StandaloneAnalysisProcess = $null
    $script:StandaloneAnalysisActive = $false
    $script:StandaloneAnalysisReady = $false
    $script:StandaloneModuleName = ''
    if ($form.Tag.MainSuiteClosing) { return }
    Show-HomeScreen
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
    $form.BringToFront()
}
function Close-StandaloneAnalysisForSuiteExit {
    if ($script:StandaloneAnalysisTimer) { $script:StandaloneAnalysisTimer.Stop() }
    $process = $script:StandaloneAnalysisProcess
    if (-not $process) {
        foreach ($marker in @($script:StandaloneShutdownSignal, $script:StandaloneReadySignal)) {
            if ($marker) { try { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue } catch { } }
        }
        if ($script:StandaloneStartupLog) { try { Remove-Item -LiteralPath $script:StandaloneStartupLog -Force -ErrorAction SilentlyContinue } catch { } }
        $script:StandaloneShutdownSignal = ''
        $script:StandaloneReadySignal = ''
        $script:StandaloneStartupLog = ''
        $script:StandaloneAnalysisActive = $false
        $script:StandaloneAnalysisReady = $false
        $script:StandaloneModuleName = ''
        return
    }

    try {
        if (-not $process.HasExited) {
            if ($script:StandaloneShutdownSignal) {
                try {
                    $encoding = New-Object System.Text.UTF8Encoding($false)
                    [System.IO.File]::WriteAllText($script:StandaloneShutdownSignal, 'close', $encoding)
                } catch { }
            }

            # The standalone GUI checks this signal four times per second and closes
            # itself without prompting. Wait for that clean path before using fallbacks.
            try { [void]$process.WaitForExit(2500) } catch { }
            if (-not $process.HasExited) {
                try { [void]$process.CloseMainWindow() } catch { }
                try { [void]$process.WaitForExit(1000) } catch { }
            }
            if (-not $process.HasExited) {
                try {
                    Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', [string]$process.Id, '/T', '/F') -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
                } catch {
                    try { $process.Kill() } catch { }
                }
            }
        }
    }
    catch { }
    finally {
        foreach ($marker in @($script:StandaloneShutdownSignal, $script:StandaloneReadySignal)) {
            if ($marker) {
                try { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
        if ($script:StandaloneStartupLog) {
            try { Remove-Item -LiteralPath $script:StandaloneStartupLog -Force -ErrorAction SilentlyContinue } catch { }
        }
        $script:StandaloneShutdownSignal = ''
        $script:StandaloneReadySignal = ''
        $script:StandaloneStartupLog = ''
        $script:StandaloneAnalysisProcess = $null
        $script:StandaloneAnalysisActive = $false
        $script:StandaloneAnalysisReady = $false
        $script:StandaloneModuleName = ''
    }
}

function Open-StandaloneAnalysisModule([string]$Module) {
    if ($script:StandaloneAnalysisActive) {
        Show-Info 'An analysis application is already open. Close it before opening another module.'
        return
    }
    $relativePath = switch ($Module) {
        'enrichment' { 'Modules\GO Enrichment and Pathways\App\enrichment_gui.ps1' }
        'network' { 'Modules\GO Enrichment and Pathways\App\enrichment_gui.ps1' }
        default { 'Modules\Differential Expression\App\differential_expression_gui.ps1' }
    }
    $moduleName = switch ($Module) {
        'enrichment' { 'GO, Enrichment and Pathways' }
        'network' { 'Functional Enrichment and Co-expression Networks' }
        default { 'Differential Expression' }
    }
    $scriptPath = Join-Path $script:SuiteRoot $relativePath
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Show-Error "The standalone analysis application was not found: $scriptPath"
        return
    }

    $signalStem = 'bacterial_rna_analysis_' + [string]$PID + '_' + [Guid]::NewGuid().ToString('N')
    $signalPath = Join-Path $env:TEMP ($signalStem + '.close')
    $readyPath = Join-Path $env:TEMP ($signalStem + '.ready')
    $startupLog = Join-Path $env:TEMP ($signalStem + '.startup.log')
    foreach ($path in @($signalPath, $readyPath, $startupLog)) {
        try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$scriptPath`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.EnvironmentVariables['BRA_PARENT_PID'] = [string]$PID
    $psi.EnvironmentVariables['BRA_SHUTDOWN_SIGNAL'] = $signalPath
    $psi.EnvironmentVariables['BRA_READY_SIGNAL'] = $readyPath
    $psi.EnvironmentVariables['BRA_STARTUP_LOG'] = $startupLog
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
    }
    catch {
        Show-Error ("The analysis application could not start.`r`n`r`n" + $_.Exception.Message)
        return
    }

    $script:StandaloneAnalysisProcess = $process
    $script:StandaloneShutdownSignal = $signalPath
    $script:StandaloneReadySignal = $readyPath
    $script:StandaloneStartupLog = $startupLog
    $script:StandaloneAnalysisActive = $true
    $script:StandaloneAnalysisReady = $false
    $script:StandaloneModuleName = $moduleName

    # Keep the main suite visible until the child form explicitly reports that it
    # has been shown. This prevents a failed child launch from making the entire
    # suite appear to close.
    if (-not $script:StandaloneAnalysisTimer) {
        $script:StandaloneAnalysisTimer = New-Object System.Windows.Forms.Timer
        $script:StandaloneAnalysisTimer.Interval = 250
        $script:StandaloneAnalysisTimer.Add_Tick({
            if (-not $script:StandaloneAnalysisProcess) { return }

            if (-not $script:StandaloneAnalysisProcess.HasExited) {
                if (-not $script:StandaloneAnalysisReady -and $script:StandaloneReadySignal -and (Test-Path -LiteralPath $script:StandaloneReadySignal -PathType Leaf)) {
                    $script:StandaloneAnalysisReady = $true
                    $form.Hide()
                }
                return
            }

            $openedSuccessfully = $script:StandaloneAnalysisReady
            $startupLogPath = $script:StandaloneStartupLog
            $failedModuleName = $script:StandaloneModuleName
            $exitCode = 1
            try { $exitCode = $script:StandaloneAnalysisProcess.ExitCode } catch { }
            Restore-MainSuiteAfterStandaloneAnalysis

            if ($openedSuccessfully) {
                if ($startupLogPath) {
                    try { Remove-Item -LiteralPath $startupLogPath -Force -ErrorAction SilentlyContinue } catch { }
                }
                $script:StandaloneStartupLog = ''
            }
            else {
                $details = ''
                if ($startupLogPath -and (Test-Path -LiteralPath $startupLogPath -PathType Leaf)) {
                    try { $details = (Get-Content -LiteralPath $startupLogPath -Raw -ErrorAction Stop).Trim() } catch { }
                }
                $message = "$failedModuleName did not finish opening. The main suite has remained available.`r`n`r`nChild exit code: $exitCode"
                if ($details) { $message += "`r`n`r`nStartup details:`r`n$details" }
                elseif ($startupLogPath) { $message += "`r`n`r`nStartup log:`r`n$startupLogPath" }
                Show-Error $message
            }
        })
    }
    $script:StandaloneAnalysisTimer.Start()
}

# Full-page GO/network selector pages.  The layout deliberately mirrors the
# Operon selector: compact choices on the left and method documentation on the
# right.  TableLayoutPanels are used instead of resize closures so Windows
# PowerShell 5.1 never has to resolve function-local UI variables after return.
function New-BranchChoiceCard(
    [string]$Name,
    [string]$Badge,
    [string]$Summary,
    [System.Drawing.Color]$AccentColor,
    [System.Drawing.Color]$BadgeColor,
    [string]$ButtonText
) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $panel.Margin = New-Object System.Windows.Forms.Padding(0)
    $panel.BackColor = $script:surface
    $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    $accent = New-Object System.Windows.Forms.Panel
    $accent.Dock = [System.Windows.Forms.DockStyle]::Left
    $accent.Width = 7
    $accent.BackColor = $AccentColor

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    $layout.RowCount = 4
    $layout.Padding = New-Object System.Windows.Forms.Padding(18, 7, 10, 8)
    [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = $Name
    $nameLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $nameLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]12.25, [System.Drawing.FontStyle]::Bold)
    $nameLabel.ForeColor = $greenDark
    $nameLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $nameLabel.UseCompatibleTextRendering = $false
    $layout.Controls.Add($nameLabel, 0, 0)

    $badgeLabel = New-Object System.Windows.Forms.Label
    $badgeLabel.Text = $Badge
    $badgeLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $badgeLabel.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 3)
    $badgeLabel.BackColor = $BadgeColor
    $badgeLabel.ForeColor = $AccentColor
    $badgeLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $badgeLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]8.75, [System.Drawing.FontStyle]::Bold)
    $badgeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $badgeLabel.UseCompatibleTextRendering = $false
    $layout.Controls.Add($badgeLabel, 0, 1)

    $summaryLabel = New-Object System.Windows.Forms.Label
    $summaryLabel.Text = $Summary
    $summaryLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $summaryLabel.Margin = New-Object System.Windows.Forms.Padding(1, 4, 1, 3)
    $summaryLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]9.35, [System.Drawing.FontStyle]::Regular)
    $summaryLabel.ForeColor = $ink
    $summaryLabel.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    $summaryLabel.UseCompatibleTextRendering = $false
    $layout.Controls.Add($summaryLabel, 0, 2)

    $button = New-Button $ButtonText 0 0 300 30
    $button.Dock = [System.Windows.Forms.DockStyle]::Fill
    $button.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
    $button.FlatAppearance.BorderColor = $AccentColor
    $button.ForeColor = $AccentColor
    $button.Font = New-Object System.Drawing.Font('Segoe UI', [single]9.25, [System.Drawing.FontStyle]::Bold)
    $layout.Controls.Add($button, 0, 3)

    $panel.Controls.Add($layout)
    $panel.Controls.Add($accent)
    $panel.Tag = [pscustomobject]@{
        name=$nameLabel; badge=$badgeLabel; summary=$summaryLabel; button=$button; accent=$accent
        Selector=$null; Method=''
    }
    return $panel
}

function Select-BranchMethod {
    param(
        [System.Windows.Forms.Panel]$SelectorSurface,
        [string]$Method
    )
    if (-not $SelectorSurface -or -not $SelectorSurface.Tag) { return }
    $state = $SelectorSurface.Tag
    $state.Selected = $Method
    $entry = if ($Method -eq 'second') { $state.SecondInfo } else { $state.FirstInfo }
    if ($state.IntroPanel) { $state.IntroPanel.Visible = $false }
    $state.DetailHeader.Visible = $true
    $state.DetailBox.Visible = $true
    $state.Continue.Visible = $true
    $state.DetailHeader.Text = $entry.Header
    $state.DetailHeader.BackColor = $entry.HeaderColor
    Set-DescriptionPanelText -Box $state.DetailBox -Text $entry.Info
    $state.DetailBox.SelectionStart = 0
    $state.DetailBox.ScrollToCaret()
    $state.Continue.Enabled = $true
    $state.Continue.Text = $entry.ContinueText
    $state.Continue.BackColor = $entry.ButtonColor
    $state.First.BackColor = if ($Method -eq 'first') { $greenSoft } else { $script:surface }
    $state.Second.BackColor = if ($Method -eq 'second') { $blueSoft } else { $script:surface }
}

function Open-SelectedBranchMethod {
    param([System.Windows.Forms.Panel]$SelectorSurface)
    if (-not $SelectorSurface -or -not $SelectorSurface.Tag) { return }
    $state = $SelectorSurface.Tag
    if ([string]::IsNullOrWhiteSpace([string]$state.Selected)) { return }
    if ($state.Kind -eq 'network') {
        if ($state.Selected -eq 'second') { Open-EmbeddedScientificModule 'string' }
        else { Open-EmbeddedDownstreamModule 'enrichment' }
    }
    else {
        if ($state.Selected -eq 'second') { Open-EmbeddedScientificModule 'pathway' }
        else { Open-EmbeddedDownstreamModule 'enrichment' }
    }
}

function Connect-BranchChoiceCard {
    param(
        [System.Windows.Forms.Panel]$Card,
        [System.Windows.Forms.Panel]$SelectorSurface,
        [string]$Method
    )
    $Card.Tag.Selector = $SelectorSurface
    $Card.Tag.Method = $Method
    # Card/background clicks are for reading/comparing the description only.
    foreach ($control in @($Card, $Card.Tag.name, $Card.Tag.badge, $Card.Tag.summary, $Card.Tag.accent)) {
        if (-not $control) { continue }
        $control.Cursor = [System.Windows.Forms.Cursors]::Hand
        if ($control -ne $Card) { $control.Tag = [pscustomobject]@{ Selector=$SelectorSurface; Method=$Method } }
        $control.Add_Click({
            param($sender,$eventArgs)
            $clickState = $sender.Tag
            if ($clickState -and $clickState.Selector) {
                Select-BranchMethod -SelectorSurface $clickState.Selector -Method ([string]$clickState.Method)
            }
        })
    }
    # Only the explicit Select button opens the chosen module.
    $Card.Tag.button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Card.Tag.button.Tag = [pscustomobject]@{ Selector=$SelectorSurface; Method=$Method }
    $Card.Tag.button.Add_Click({
        param($sender,$eventArgs)
        $clickState = $sender.Tag
        if ($clickState -and $clickState.Selector) {
            Select-BranchMethod -SelectorSurface $clickState.Selector -Method ([string]$clickState.Method)
            Open-SelectedBranchMethod -SelectorSurface $clickState.Selector
        }
    })
}

function New-BranchSelectorSurface([string]$Kind) {
    $selectorSurface = New-Object System.Windows.Forms.Panel
    $selectorSurface.Dock = [System.Windows.Forms.DockStyle]::Fill
    $selectorSurface.BackColor = $background
    $selectorSurface.Visible = $false
    $workspaceHost.Controls.Add($selectorSurface)

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = [System.Windows.Forms.DockStyle]::Fill
    $root.ColumnCount = 1
    $root.RowCount = 2
    $root.Padding = New-Object System.Windows.Forms.Padding(22, 10, 22, 14)
    [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 66)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $selectorSurface.Controls.Add($root)

    $header = New-Object System.Windows.Forms.TableLayoutPanel
    $header.Dock = [System.Windows.Forms.DockStyle]::Fill
    $header.ColumnCount = 2
    $header.RowCount = 2
    $header.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$header.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$header.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 215)))
    [void]$header.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 38)))
    [void]$header.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))
    $root.Controls.Add($header, 0, 0)

    $titleText = if ($Kind -eq 'network') { 'Co-expression and networks' } else { 'GO, enrichment and pathways' }
    $introText = if ($Kind -eq 'network') { 'Choose a network-analysis submodule, review its requirements, then continue.' } else { 'Choose an enrichment-analysis submodule, review its requirements, then continue.' }
    $title = New-Object System.Windows.Forms.Label
    $title.Text = $titleText
    $title.Dock = [System.Windows.Forms.DockStyle]::Fill
    $title.Font = New-Object System.Drawing.Font('Segoe UI', [single]17, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $greenDark
    $title.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $title.UseCompatibleTextRendering = $false
    $header.Controls.Add($title,0,0)
    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = $introText
    $intro.Dock = [System.Windows.Forms.DockStyle]::Fill
    $intro.Font = New-Object System.Drawing.Font('Segoe UI', [single]9.5, [System.Drawing.FontStyle]::Regular)
    $intro.ForeColor = $muted
    $intro.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $intro.UseCompatibleTextRendering = $false
    $header.Controls.Add($intro,0,1)
    $backHome = New-Button '< Back to analysis modules' 0 0 205 36
    $backHome.Anchor = [System.Windows.Forms.AnchorStyles]::None
    $header.Controls.Add($backHome,1,0)
    $header.SetRowSpan($backHome,2)

    $columns = New-Object System.Windows.Forms.TableLayoutPanel
    $columns.Dock = [System.Windows.Forms.DockStyle]::Fill
    $columns.ColumnCount = 2
    $columns.RowCount = 1
    $columns.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$columns.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 38)))
    [void]$columns.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 62)))
    [void]$columns.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $root.Controls.Add($columns,0,1)

    $choicePanel = New-Object System.Windows.Forms.Panel
    $choicePanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $choicePanel.Margin = New-Object System.Windows.Forms.Padding(0, 4, 12, 0)
    $choicePanel.BackColor = $background
    $columns.Controls.Add($choicePanel,0,0)

    $choiceLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $choiceLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $choiceLayout.ColumnCount = 1
    $choiceLayout.RowCount = 5
    $choiceLayout.Padding = New-Object System.Windows.Forms.Padding(0)
    [void]$choiceLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$choiceLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 48)))
    [void]$choiceLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 158)))
    [void]$choiceLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 10)))
    [void]$choiceLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 158)))
    [void]$choiceLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $choicePanel.Controls.Add($choiceLayout)

    $chooseLabel = New-Object System.Windows.Forms.Label
    $chooseLabel.Text = 'CHOOSE A METHOD'
    $chooseLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $chooseLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]10.25, [System.Drawing.FontStyle]::Bold)
    $chooseLabel.ForeColor = $greenDark
    $chooseLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $chooseLabel.UseCompatibleTextRendering = $false
    $choiceLayout.Controls.Add($chooseLabel,0,0)

    if ($Kind -eq 'network') {
        $card1 = New-BranchChoiceCard 'Functional enrichment and co-expression networks' 'STARTS FROM ONE DE HANDOFF' 'clusterProfiler, fgsea, topGO, CEMiTool, WGCNA, and GENIE3 in one shared-annotation run.' $green $greenSoft 'Select combined functional analysis'
        $card2 = New-BranchChoiceCard 'STRING protein associations' 'STARTS FROM A GENE LIST OR TABLE' 'Physical or functional STRING evidence, with optional expression-network overlay.' $blue $blueSoft 'Select STRING analysis'
        $firstInfo = [pscustomobject]@{
            Header='Functional enrichment + co-expression  |  GO + modules + networks'; HeaderColor=$greenSoft; ButtonColor=$green
            ContinueText='I understand and want to continue to the combined analysis workspace'
            Info=@'
WHAT IT IS

This coordinated workflow interprets differential expression and analyzes relationships among genes across biological samples. It combines clusterProfiler, fgsea, or topGO enrichment with CEMiTool, WGCNA, or GENIE3 network analysis, while preparing identifiers and functional annotation once.

REQUIRED INPUTS

A differential-expression result, normalized expression matrix, and matching sample metadata. Supply one offline gene-to-term mapping or enable one online annotation pass. A custom universe and GENIE3 regulator list are optional. At least 20 independent samples are preferable for stable co-expression.

GENERAL PROCEDURE

1. Load the latest DE handoff or scan one result folder once for every shared input.
2. Choose one mapping/annotation source, one enrichment method, and one network method.
3. Review Parameter guide and Guided package options.
4. Run once to create all enrichment, module/network, workbook, figure, and interactive-report results.

STRENGTHS

1. Uses one scan, annotation pass, environment, run, workbook, and interactive report.

2. WGCNA and CEMiTool support automatic modules and module-level functional interpretation.

3. GENIE3 provides directed regulator-target evidence when candidate regulators are known.

LIMITATIONS

1. Correlation or model importance is not proof of direct molecular interaction.

2. Small sample numbers can make expression networks unstable.

3. Enrichment depends on mapping/universe quality, while networks depend strongly on normalization, batch effects, and sample design.

OUTPUTS

One combined Excel workbook and one combined interactive HTML report, plus enrichment tables, module memberships, hubs/regulators, edge/node tables, diagnostics, and figures.
'@
        }
        $secondInfo = [pscustomobject]@{
            Header='STRING protein associations  |  Physical or functional evidence'; HeaderColor=$blueSoft; ButtonColor=$blue
            ContinueText='I understand and want to continue to STRING protein associations'
            Info=@'
WHAT IT IS

STRING analysis retrieves curated and predicted protein-association evidence for a supplied bacterial gene/protein list. The user can choose a physical network or a broader functional association network. STRING confidence scores are evidence confidence, not binding strength.

REQUIRED INPUTS

A gene/protein list or compatible table, the organism taxonomic identifier, and identifiers that STRING can map. An existing expression-network edge table may optionally be supplied for an evidence overlay. Internet access is required for live STRING REST queries.

GENERAL PROCEDURE

1. Map submitted identifiers to STRING identifiers and retain a mapping audit.
2. Query physical or functional associations at the chosen confidence threshold.
3. Keep STRING scores separate from expression-network weights.
4. Optionally combine evidence layers without pretending they measure the same quantity.
5. Export Excel and GraphML network files.

STRENGTHS

1. Adds protein-level biological context that expression correlation alone cannot provide.

2. Supports physical and functional association modes.

3. Keeps unmapped identifiers and evidence scores auditable.

LIMITATIONS

1. STRING coverage depends on organism and identifier mapping.

2. An association score is not experimental proof of binding or regulation.

3. Online queries depend on STRING service availability and internet access.

OUTPUTS

PPI and network.xlsx, mapping/unmapped audits, STRING edge tables, optional combined evidence tables, and GraphML network output.
'@
        }
    }
    else {
        $card1 = New-BranchChoiceCard 'Functional enrichment and co-expression networks' 'STARTS FROM DE RESULTS, RANKINGS, OR EXPRESSION' 'clusterProfiler, fgsea, topGO, CEMiTool, WGCNA, and GENIE3 in one shared-annotation workspace.' $green $greenSoft 'Select functional and co-expression analysis'
        $card2 = New-BranchChoiceCard 'Pathway database analysis' 'STARTS FROM A GENE LIST + PATHWAY MAPPING' 'Use online KEGG without a local mapping file, or import BioCyc, MetaCyc, or custom TERM2GENE data.' $blue $blueSoft 'Select pathway database analysis'
        $firstInfo = [pscustomobject]@{
            Header='Functional enrichment + co-expression  |  GO + modules + networks'; HeaderColor=$greenSoft; ButtonColor=$green
            ContinueText='I understand and want to continue to the combined analysis workspace'
            Info=@'
WHAT IT IS

The coordinated workflow interprets differential-expression results and discovers expression modules or regulatory relationships in one run. It combines clusterProfiler, fgsea, or topGO with CEMiTool, WGCNA, or GENIE3 and reuses one annotation source for both result families.

REQUIRED INPUTS

A differential-expression result, normalized expression matrix, and matching sample metadata. Supply one offline gene-to-term mapping or enable one online annotation pass. A background/universe is recommended for over-representation testing; a regulator list is optional for GENIE3.

GENERAL PROCEDURE

1. Use latest DE analysis results or scan one result folder for automatic input assignment.
2. Select one annotation source, enrichment method, and network method.
3. Review Parameter guide and Guided package options.
4. Run once to generate both analyses, all figures, one workbook, and one interactive report.

STRENGTHS

1. Supports thresholded, ranked, and GO-graph-aware enrichment alongside automatic expression modules or regulatory inference.

2. Retains established Bioconductor methods and prepares annotation only once.

3. Links detected modules and nodes to the same functional evidence used by enrichment.

LIMITATIONS

1. Results depend on identifier mapping and annotation completeness.

2. Over-representation results depend on the chosen gene universe.

3. Enrichment does not prove pathway activation, and co-expression or model importance does not prove direct regulation.

OUTPUTS

One combined Excel workbook and interactive report containing enrichment, term-gene membership, module, trait, node, edge, diagnostic, and mapping results.
'@
        }
        $secondInfo = [pscustomobject]@{
            Header='Pathway database analysis  |  KEGG + BioCyc + MetaCyc'; HeaderColor=$blueSoft; ButtonColor=$blue
            ContinueText='I understand and want to continue to pathway database analysis'
            Info=@'
WHAT IT IS

Pathway database analysis performs pathway-oriented over-representation using a selected gene list and a pathway-to-gene mapping. Online KEGG requires no local mapping file: enter a KEGG organism code, scientific name, or NCBI taxonomy ID and explicitly confirm online use. User-authorized BioCyc, MetaCyc, or custom TERM2GENE tables remain supported.

REQUIRED INPUTS

A selected gene list, preferably a matching tested-gene universe, and at least one pathway mapping source. Online KEGG requires an organism identifier (KEGG code, scientific name, or NCBI taxonomy ID) and explicit online-use confirmation. BioCyc/MetaCyc mappings are imported from user-authorized files and are not silently bundled.

GENERAL PROCEDURE

1. Load the selected genes and optional universe.
2. Use confirmed online KEGG directly, or import TERM2GENE, BioCyc, or MetaCyc mappings.
3. Calculate pathway over-representation and multiple-testing correction.
4. Audit annotation coverage and database provenance.
5. Export pathway tables and a formatted workbook.

STRENGTHS

1. Provides pathway interpretation beyond GO terms.

2. Uses one transparent TERM2GENE representation across supported databases.

3. Reports mapping coverage so sparse annotation is visible to the user.

LIMITATIONS

1. The expansion engine performs over-representation analysis; it does not replace the existing fgsea/GSEA workflow.

2. KEGG live mapping depends on internet access and user confirmation.

3. BioCyc/MetaCyc availability and licensing remain the user's responsibility.

OUTPUTS

Pathway enrichment.xlsx with enrichment, gene-pathway mapping, annotation coverage, database summary, provenance, and cached mapping data under Intermediate files.
'@
        }
    }

    $choiceLayout.Controls.Add($card1,0,1)
    $choiceLayout.Controls.Add($card2,0,3)

    $detail = New-Object System.Windows.Forms.Panel
    $detail.Dock = [System.Windows.Forms.DockStyle]::Fill
    $detail.Margin = New-Object System.Windows.Forms.Padding(12, 4, 0, 0)
    $detail.BackColor = $script:surface
    $detail.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $columns.Controls.Add($detail,1,0)

    $detailLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $detailLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $detailLayout.ColumnCount = 1
    $detailLayout.RowCount = 3
    $detailLayout.Padding = New-Object System.Windows.Forms.Padding(18, 14, 18, 14)
    [void]$detailLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,100)))
    [void]$detailLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,54)))
    [void]$detailLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,100)))
    [void]$detailLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,46)))
    $detail.Controls.Add($detailLayout)

    $detailHeader = New-Object System.Windows.Forms.Label
    $detailHeader.Text = 'Select a method to review its scientific workflow'
    $detailHeader.Dock = [System.Windows.Forms.DockStyle]::Fill
    $detailHeader.Padding = New-Object System.Windows.Forms.Padding(10, 0, 8, 0)
    $detailHeader.Font = New-Object System.Drawing.Font('Segoe UI', [single]14.25, [System.Drawing.FontStyle]::Bold)
    $detailHeader.ForeColor = $greenDark
    $detailHeader.BackColor = $greenSoft
    $detailHeader.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $detailHeader.UseCompatibleTextRendering = $false
    $detailLayout.Controls.Add($detailHeader,0,0)

    $detailBox = New-Object System.Windows.Forms.RichTextBox
    $detailBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $detailBox.Margin = New-Object System.Windows.Forms.Padding(0,10,0,8)
    $detailBox.ReadOnly = $true
    $detailBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $detailBox.BackColor = $script:surface
    $detailBox.Font = New-Object System.Drawing.Font('Segoe UI', [single]9.5)
    $detailBox.Text = if ($Kind -eq 'network') {
        "Choose a method on the left.`r`n`r`nThe right panel will explain required inputs, procedure, strengths, limitations, and outputs before the analysis interface opens."
    } else {
        "Choose a method on the left.`r`n`r`nThe right panel will explain required inputs, procedure, strengths, limitations, and outputs before the analysis interface opens."
    }
    $detailLayout.Controls.Add($detailBox,0,1)

    $continue = New-Button 'Select a method first' 0 0 500 40 -Primary
    $continue.Dock = [System.Windows.Forms.DockStyle]::Fill
    $continue.Enabled = $false
    $continue.Margin = New-Object System.Windows.Forms.Padding(0,3,0,0)
    $continue.Font = New-Object System.Drawing.Font('Segoe UI', [single]9.75, [System.Drawing.FontStyle]::Bold)
    $detailLayout.Controls.Add($continue,0,2)

    # Initial right-hand view mirrors the Operon selector: a compact comparison
    # of both available submodules before the user commits to one method.
    $detailHeader.Visible = $false
    $detailBox.Visible = $false
    $continue.Visible = $false
    $introPanel = New-Object System.Windows.Forms.Panel
    $introPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $introPanel.BackColor = $script:surface
    $detail.Controls.Add($introPanel)
    $introPanel.BringToFront()

    $introLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $introLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $introLayout.ColumnCount = 1
    $introLayout.RowCount = 6
    $introLayout.Padding = New-Object System.Windows.Forms.Padding(22, 16, 22, 14)
    [void]$introLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,100)))
    [void]$introLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,76)))
    [void]$introLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,58)))
    [void]$introLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,50)))
    [void]$introLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,10)))
    [void]$introLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,50)))
    [void]$introLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,38)))
    $introPanel.Controls.Add($introLayout)

    $introIconHost = New-Object System.Windows.Forms.Panel
    $introIconHost.Dock = [System.Windows.Forms.DockStyle]::Fill
    $introIcon = New-Object System.Windows.Forms.Label
    $introIcon.Text = '?'
    $introIcon.Size = New-Object System.Drawing.Size(58,58)
    $introIcon.Location = New-Object System.Drawing.Point(0,5)
    $introIcon.Anchor = [System.Windows.Forms.AnchorStyles]::None
    $introIcon.Font = New-Object System.Drawing.Font('Segoe UI',[single]24,[System.Drawing.FontStyle]::Bold)
    $introIcon.ForeColor = $green
    $introIcon.BackColor = $greenSoft
    $introIcon.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $introIconHost.Controls.Add($introIcon)
    $introIconLayout = { $introIcon.Left = [int](($introIconHost.ClientSize.Width - $introIcon.Width)/2) }.GetNewClosure()
    $introIconHost.Add_Resize($introIconLayout)
    & $introIconLayout
    $introLayout.Controls.Add($introIconHost,0,0)

    $introTitle = New-Object System.Windows.Forms.Label
    $introTitle.Text = 'Choose the method that matches your data'
    $introTitle.Dock = [System.Windows.Forms.DockStyle]::Fill
    $introTitle.Font = New-Object System.Drawing.Font('Segoe UI',[single]15.5,[System.Drawing.FontStyle]::Bold)
    $introTitle.ForeColor = $greenDark
    $introTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $introTitle.UseCompatibleTextRendering = $false
    $introLayout.Controls.Add($introTitle,0,1)

    if ($Kind -eq 'network') {
        $introFirst = New-OperonIntroCard '1. Functional enrichment and co-expression networks' 'Starts from one completed DE handoff. One scan loads DE statistics, normalized expression, metadata, and annotation inputs for clusterProfiler, fgsea, topGO, CEMiTool, WGCNA, or GENIE3.' $green
        $introSecond = New-OperonIntroCard '2. STRING protein associations' 'Starts from a bacterial gene/protein list and organism taxon ID. Retrieve physical or functional STRING associations and optionally compare them with an existing expression-network edge layer.' $blue
        $introFooterText = 'Select the combined functional-analysis workflow for enrichment and expression-derived networks, or STRING for separate protein-association evidence.'
    } else {
        $introFirst = New-OperonIntroCard '1. Functional enrichment and co-expression networks' 'Use clusterProfiler, fgsea, or topGO for functional interpretation, then CEMiTool, WGCNA, or GENIE3 for automatic modules and expression-derived networks with the same annotation controls.' $green
        $introSecond = New-OperonIntroCard '2. Pathway database analysis' 'Starts from a selected gene list plus a real tested-gene universe and pathway mappings. Use KEGG, BioCyc, MetaCyc, or a user-supplied TERM2GENE mapping.' $blue
        $introFooterText = 'Select the combined functional/co-expression workspace, or the dedicated pathway-database workflow.'
    }
    $introLayout.Controls.Add($introFirst,0,2)
    $introLayout.Controls.Add($introSecond,0,4)
    $introFooter = New-Object System.Windows.Forms.Label
    $introFooter.Text = $introFooterText
    $introFooter.Dock = [System.Windows.Forms.DockStyle]::Fill
    $introFooter.Font = New-Object System.Drawing.Font('Segoe UI',[single]9.2)
    $introFooter.ForeColor = $muted
    $introFooter.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $introFooter.UseCompatibleTextRendering = $false
    $introLayout.Controls.Add($introFooter,0,5)

    $selectorSurface.Tag = [pscustomobject]@{
        Kind=$Kind; Selected=''; First=$card1; Second=$card2; FirstInfo=$firstInfo; SecondInfo=$secondInfo
        DetailHeader=$detailHeader; DetailBox=$detailBox; Continue=$continue; IntroPanel=$introPanel
    }
    Connect-BranchChoiceCard -Card $card1 -SelectorSurface $selectorSurface -Method 'first'
    Connect-BranchChoiceCard -Card $card2 -SelectorSurface $selectorSurface -Method 'second'
    $continue.Tag = $selectorSurface
    $continue.Add_Click({ param($sender,$eventArgs) Open-SelectedBranchMethod -SelectorSurface $sender.Tag })

    return [pscustomobject]@{ Surface=$selectorSurface; Back=$backHome; First=$card1; Second=$card2; Continue=$continue }
}

# The enrichment/pathway and co-expression choices are now contained in one
# downstream workspace. Do not construct the retired intermediate selector
# surfaces: besides duplicating the combined interface, their live control
# trees could reappear behind an embedded module during return navigation.
$enrichmentSelector = $null
$networkSelector = $null


function Open-EmbeddedScientificModule {
    param([string]$Module,[string]$ReturnTarget='')

    $relativePath = switch ($Module) {
        'transcript' { 'Modules\Transcript Discovery\App\transcript_discovery_gui.ps1' }
        'string' { 'Modules\Co-expression and Networks\App\string_ppi_gui.ps1' }
        'pathway' { 'Modules\GO Enrichment and Pathways\App\pathway_expansion_gui.ps1' }
        default { return }
    }
    $moduleName = switch ($Module) {
        'transcript' { 'Transcript Discovery' }
        'string' { 'Networks | STRING protein associations' }
        'pathway' { 'GO / Enrichment | Pathway databases' }
    }
    $scriptPath = Join-Path $script:SuiteRoot $relativePath
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Show-Error "The integrated analysis module was not found: $scriptPath"
        return
    }

    # Opening a module must be UI-only. Get-WslDistro performs real WSL probes
    # and can take seconds, especially when several distributions are installed.
    # Do not touch WSL here. The explicit Check environment / Run action resolves
    # and then caches the distro only when backend execution is actually needed.

    $form.Tag.EmbeddedModuleActive = $true
    $header.Visible = $false
    $rootLayout.RowStyles[0].Height = 0
    $homeSurface.Visible = $false
    $operonSurface.Visible = $false
    $tabs.Visible = $false
    $topProjectActions.Visible = $false
    $footer.Visible = $false
    $rootLayout.RowStyles[2].Height = 0
    $moduleOverlay.Visible = $true
    $moduleOverlay.BringToFront()
    $scope.Text = $moduleName
    $global:BacterialRNAAnalysisEmbeddedHost = $moduleOverlay
    $global:BacterialRNAAnalysisReturnTarget = if ($ReturnTarget) { $ReturnTarget } elseif ($Module -in @('string','pathway')) { 'combined' } else { 'home' }
    $global:BacterialRNAAnalysisSuiteRoot = $script:SuiteRoot
    $global:BacterialRNAAnalysisScienceCommonPath = Join-Path $script:SuiteRoot 'Modules\Scientific Expansion\Backend\scientific_gui_common.ps1'
    try {
        & $scriptPath
    }
    catch {
        Show-Error ("The integrated $moduleName interface could not open.`r`n`r`n" + $_.Exception.Message)
    }
    finally {
        $returnTarget = 'home'
        try {
            $requestedTarget = Get-Variable -Name BacterialRNAAnalysisReturnTarget -Scope Global -ValueOnly -ErrorAction Stop
            if ([string]$requestedTarget -in @('combined','home')) { $returnTarget = [string]$requestedTarget }
        } catch { }
        Remove-Variable -Name BacterialRNAAnalysisEmbeddedHost -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name BacterialRNAAnalysisReturnTarget -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name BacterialRNAAnalysisSuiteRoot -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name BacterialRNAAnalysisScienceCommonPath -Scope Global -ErrorAction SilentlyContinue
        while ($moduleOverlay.Controls.Count -gt 0) {
            $control = $moduleOverlay.Controls[0]
            $moduleOverlay.Controls.RemoveAt(0)
            try { $control.Dispose() } catch { }
        }
        $moduleOverlay.Visible = $false
        $form.Tag.EmbeddedModuleActive = $false
        if (-not $form.Tag.MainSuiteClosing) {
            switch ($returnTarget) {
                'combined' { Open-EmbeddedDownstreamModule 'enrichment' }
                default { Show-HomeScreen }
            }
        }
    }
}

function Open-EmbeddedDownstreamModule {
    param(
        [string]$Module,
        [switch]$AutoLoadLatestRnaSeq
    )
    $relativePath = switch ($Module) {
        'enrichment' { 'Modules\GO Enrichment and Pathways\App\enrichment_gui.ps1' }
        'network' { 'Modules\GO Enrichment and Pathways\App\enrichment_gui.ps1' }
        default { 'Modules\Differential Expression\App\differential_expression_gui.ps1' }
    }
    $moduleName = switch ($Module) {
        'enrichment' { 'GO, enrichment and pathways' }
        'network' { 'Functional enrichment and co-expression networks' }
        default { 'Differential expression' }
    }
    $scriptPath = Join-Path $script:SuiteRoot $relativePath
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Show-Error "The integrated analysis module was not found: $scriptPath"
        return
    }

    $form.Tag.EmbeddedModuleActive = $true
    # Give the embedded downstream application the full 1500 x 900 client area.
    # Its own header already contains the module title, instructions, and return
    # button, so retaining the suite header only wastes vertical space and causes
    # unnecessary scrolling.
    $header.Visible = $false
    $rootLayout.RowStyles[0].Height = 0
    $homeSurface.Visible = $false
    $operonSurface.Visible = $false
    $tabs.Visible = $false
    $topProjectActions.Visible = $false
    $footer.Visible = $false
    $rootLayout.RowStyles[2].Height = 0
    $moduleOverlay.Visible = $true
    $moduleOverlay.BringToFront()
    $scope.Text = $moduleName
    $global:BacterialRNAAnalysisEmbeddedHost = $moduleOverlay
    $global:BacterialRNAAnalysisReturnTarget = 'home'
    if ($AutoLoadLatestRnaSeq -and $Module -eq 'de') {
        $global:BacterialRNAAnalysisAutoLoadLatestRnaSeq = $true
    }
    try {
        & $scriptPath
    }
    catch {
        Show-Error ("The integrated $moduleName interface could not open.`r`n`r`n" + $_.Exception.Message)
    }
    finally {
        # Functional enrichment, networks, pathways, and STRING now share one
        # combined workspace. Returning from it goes directly to the module
        # overview; the retired intermediate method selector must not reappear.
        $returnTarget = 'home'
        $nextModule = ''
        try {
            $requestedTarget = Get-Variable -Name BacterialRNAAnalysisReturnTarget -Scope Global -ValueOnly -ErrorAction Stop
            if ([string]$requestedTarget -eq 'home') { $returnTarget = 'home' }
        } catch { }
        try {
            $requestedModule = Get-Variable -Name BacterialRNAAnalysisNextModule -Scope Global -ValueOnly -ErrorAction Stop
            if ([string]$requestedModule -in @('pathway','string')) { $nextModule = [string]$requestedModule }
        } catch { }
        Remove-Variable -Name BacterialRNAAnalysisEmbeddedHost -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name BacterialRNAAnalysisReturnTarget -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name BacterialRNAAnalysisDownstreamModule -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name BacterialRNAAnalysisAutoLoadLatestRnaSeq -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name BacterialRNAAnalysisNextModule -Scope Global -ErrorAction SilentlyContinue
        while ($moduleOverlay.Controls.Count -gt 0) {
            $control = $moduleOverlay.Controls[0]
            $moduleOverlay.Controls.RemoveAt(0)
            try { $control.Dispose() } catch { }
        }
        $moduleOverlay.Visible = $false
        $form.Tag.EmbeddedModuleActive = $false
        if (-not $form.Tag.MainSuiteClosing) {
            if ($nextModule) { Open-EmbeddedScientificModule -Module $nextModule -ReturnTarget 'combined' }
            else {
                Show-HomeScreen
            }
        }
    }
}

function Open-EmbeddedOperonModule([string]$Method) {
    if ($Method -eq 'rSeqTU') {
        $scriptPath = Join-Path $script:SuiteRoot 'Modules\Operon Prediction Suite\Applications\rSeqTU\Application Files\rSeqTU GUI.ps1'
    }
    elseif ($Method -eq 'OpDetect') {
        $scriptPath = Join-Path $script:SuiteRoot 'Modules\Operon Prediction Suite\Applications\OpDetect\App\opdetect.ps1'
    }
    elseif ($Method -eq 'TUArchitecture') {
        $scriptPath = Join-Path $script:SuiteRoot 'Modules\Operon Prediction Suite\Applications\TU Architecture\App\tu_architecture_gui.ps1'
    }
    else { return }
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { Show-Error "The integrated module was not found: $scriptPath"; return }

    $form.Tag.EmbeddedModuleActive = $true
    $operonSurface.Visible = $false
    $topProjectActions.Visible = $false
    $footer.Visible = $false
    $rootLayout.RowStyles[2].Height = 0
    $moduleOverlay.Visible = $true
    $moduleOverlay.BringToFront()
    $scope.Text = "Operon prediction | $Method"
    $global:BacterialRNAAnalysisEmbeddedHost = $moduleOverlay
    $global:BacterialRNAAnalysisReturnTarget = 'operon'
    $global:BacterialRNAAnalysisSuiteRoot = $script:SuiteRoot
    $global:BacterialRNAAnalysisScienceCommonPath = Join-Path $script:SuiteRoot 'Modules\Scientific Expansion\Backend\scientific_gui_common.ps1'
    try {
        & $scriptPath
    }
    catch {
        Show-Error ("The integrated $Method interface could not open.`r`n`r`n" + $_.Exception.Message)
    }
    finally {
        $returnTarget = 'operon'
        try {
            $requestedTarget = Get-Variable -Name BacterialRNAAnalysisReturnTarget -Scope Global -ValueOnly -ErrorAction Stop
            if ([string]$requestedTarget -eq 'home') { $returnTarget = 'home' }
        } catch { }
        Remove-Variable -Name BacterialRNAAnalysisEmbeddedHost -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name BacterialRNAAnalysisReturnTarget -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name BacterialRNAAnalysisSuiteRoot -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name BacterialRNAAnalysisScienceCommonPath -Scope Global -ErrorAction SilentlyContinue
        while ($moduleOverlay.Controls.Count -gt 0) {
            $control = $moduleOverlay.Controls[0]
            $moduleOverlay.Controls.RemoveAt(0)
            try { $control.Dispose() } catch { }
        }
        $moduleOverlay.Visible = $false
        $form.Tag.EmbeddedModuleActive = $false
        if (-not $form.Tag.MainSuiteClosing) {
            if ($returnTarget -eq 'home') { Show-HomeScreen } else { Show-OperonSelector }
        }
    }
}

$showRSeqTU = { Show-OperonMethod 'rSeqTU' }
$showOpDetect = { Show-OperonMethod 'OpDetect' }
$showTUArchitecture = { Show-OperonMethod 'TUArchitecture' }
foreach ($control in @($rSeqCard, $rSeqCard.Tag.name, $rSeqCard.Tag.badge, $rSeqCard.Tag.badgeText, $rSeqCard.Tag.summary, $rSeqCard.Tag.accent)) {
    $control.Cursor = [System.Windows.Forms.Cursors]::Hand
    $control.Add_Click($showRSeqTU)
}
foreach ($control in @($opDetectCard, $opDetectCard.Tag.name, $opDetectCard.Tag.badge, $opDetectCard.Tag.badgeText, $opDetectCard.Tag.summary, $opDetectCard.Tag.accent)) {
    $control.Cursor = [System.Windows.Forms.Cursors]::Hand
    $control.Add_Click($showOpDetect)
}
foreach ($control in @($tuArchitectureCard, $tuArchitectureCard.Tag.name, $tuArchitectureCard.Tag.badge, $tuArchitectureCard.Tag.badgeText, $tuArchitectureCard.Tag.summary, $tuArchitectureCard.Tag.accent)) {
    $control.Cursor = [System.Windows.Forms.Cursors]::Hand
    $control.Add_Click($showTUArchitecture)
}
$rSeqCard.Tag.button.Cursor = [System.Windows.Forms.Cursors]::Hand
$opDetectCard.Tag.button.Cursor = [System.Windows.Forms.Cursors]::Hand
$tuArchitectureCard.Tag.button.Cursor = [System.Windows.Forms.Cursors]::Hand
$rSeqCard.Tag.button.Add_Click({ Open-EmbeddedOperonModule 'rSeqTU' })
$opDetectCard.Tag.button.Add_Click({ Open-EmbeddedOperonModule 'OpDetect' })
$tuArchitectureCard.Tag.button.Add_Click({ Open-EmbeddedOperonModule 'TUArchitecture' })
$operonReadInstructions.Add_Click({ Open-OperonInstructions })
$operonContinue.Add_Click({ if ($script:SelectedOperonMethod) { Open-EmbeddedOperonModule $script:SelectedOperonMethod } })
$operonBackHome.Add_Click({ Show-HomeScreen })

# Page 1: read type
$typeRoot = New-Object System.Windows.Forms.TableLayoutPanel
$typeRoot.Dock = [System.Windows.Forms.DockStyle]::Fill
$typeRoot.ColumnCount = 1
$typeRoot.RowCount = 3
$typeRoot.Padding = New-Object System.Windows.Forms.Padding(24, 14, 24, 14)
[void]$typeRoot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$typeRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 88)))
[void]$typeRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 258)))
[void]$typeRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$pageType.Controls.Add($typeRoot)

$typeHeader = New-Object System.Windows.Forms.TableLayoutPanel
$typeHeader.Dock = [System.Windows.Forms.DockStyle]::Fill
$typeHeader.ColumnCount = 2
$typeHeader.RowCount = 2
$typeHeader.Margin = New-Object System.Windows.Forms.Padding(0)
[void]$typeHeader.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$typeHeader.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 145)))
[void]$typeHeader.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 47)))
[void]$typeHeader.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 38)))
$typeRoot.Controls.Add($typeHeader, 0, 0)
$typeTitle = New-TableLabel 'What sequencing data will this project analyze?'
$typeTitle.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$typeTitle.ForeColor = $greenDark
$typeHeader.Controls.Add($typeTitle, 0, 0)
$typeIntro = New-TableLabel 'Choose one. In a combined project, short-read and long-read BAMs remain separate and are never merged.'
$typeIntro.ForeColor = $muted
$typeHeader.Controls.Add($typeIntro, 0, 1)
$clearType = New-Button 'Clear selection' 0 0 130 32
$clearType.Anchor = [System.Windows.Forms.AnchorStyles]::None
$typeHeader.Controls.Add($clearType, 1, 0)
$typeHeader.SetRowSpan($clearType, 2)

$typePanel = New-Object System.Windows.Forms.TableLayoutPanel
$typePanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$typePanel.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 8)
$typePanel.ColumnCount = 3
$typePanel.RowCount = 1
foreach ($index in 1..3) { [void]$typePanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.3333))) }
[void]$typePanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$typeRoot.Controls.Add($typePanel, 0, 1)

$script:TypeRadios = @()
$script:TypeCards = @()
function New-TypeCard([string]$Tag, [string]$Heading, [string]$Body, [string]$Outputs) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Size = New-Object System.Drawing.Size(355, 240)
    $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $panel.Margin = New-Object System.Windows.Forms.Padding(8)
    $panel.BackColor = $surface
    $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    $cardLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $cardLayout.Name = 'type_card_layout'
    $cardLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $cardLayout.ColumnCount = 1
    $cardLayout.RowCount = 3
    $cardLayout.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 10)
    $cardLayout.BackColor = $surface
    [void]$cardLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$cardLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42)))
    [void]$cardLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$cardLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 72)))
    $panel.Controls.Add($cardLayout)

    $cardHeader = New-Object System.Windows.Forms.TableLayoutPanel
    $cardHeader.Dock = [System.Windows.Forms.DockStyle]::Fill
    $cardHeader.ColumnCount = 2
    $cardHeader.RowCount = 1
    $cardHeader.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$cardHeader.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$cardHeader.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 105)))
    [void]$cardHeader.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $cardLayout.Controls.Add($cardHeader, 0, 0)

    $radio = New-Object System.Windows.Forms.RadioButton
    $radio.Tag = $Tag
    $radio.Text = $Heading
    $radio.Dock = [System.Windows.Forms.DockStyle]::Fill
    $radio.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
    $radio.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $radio.ForeColor = $greenDark
    $cardHeader.Controls.Add($radio, 0, 0)
    $selectionStatus = New-TableLabel 'Click to select'
    $selectionStatus.Name = 'selection_status'
    $selectionStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $selectionStatus.ForeColor = $muted
    $selectionStatus.Font = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
    $cardHeader.Controls.Add($selectionStatus, 1, 0)
    $bodyLabel = New-TableLabel $Body
    $bodyLabel.ForeColor = $ink
    $bodyLabel.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    $bodyLabel.Padding = New-Object System.Windows.Forms.Padding(4, 10, 4, 4)
    $bodyLabel.AutoEllipsis = $false
    $bodyLabel.UseCompatibleTextRendering = $false
    $bodyLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.25)
    $cardLayout.Controls.Add($bodyLabel, 0, 1)
    $outputLabel = New-TableLabel $Outputs
    $outputLabel.BackColor = $greenSoft
    $outputLabel.ForeColor = $greenDark
    $outputLabel.Padding = New-Object System.Windows.Forms.Padding(9)
    $outputLabel.Margin = New-Object System.Windows.Forms.Padding(3, 4, 3, 0)
    $cardLayout.Controls.Add($outputLabel, 0, 2)
    $panel.Tag = $radio
    $cardLayout.Tag = $radio
    $cardHeader.Tag = $radio
    $bodyLabel.Tag = $radio
    $outputLabel.Tag = $radio
    $selectionStatus.Tag = $radio
    $panel.Add_Click({ $this.Tag.Checked = $true })
    $cardLayout.Add_Click({ $this.Tag.Checked = $true })
    $cardHeader.Add_Click({ $this.Tag.Checked = $true })
    $bodyLabel.Add_Click({ $this.Tag.Checked = $true })
    $outputLabel.Add_Click({ $this.Tag.Checked = $true })
    $selectionStatus.Add_Click({ $this.Tag.Checked = $true })
    $radio.Add_CheckedChanged({
        param($sender, $eventArgs)
        if ($sender.Checked) {
            foreach ($other in $script:TypeRadios) {
                if (-not [object]::ReferenceEquals($other, $sender) -and $other.Checked) { $other.Checked = $false }
            }
            $script:AnalysisType = [string]$sender.Tag
            Update-AnalysisVisibility
            if ($script:methodCombos -and $script:methodCombos.ContainsKey('quantification')) {
                if ($script:AnalysisType -eq 'long') { Set-MethodValue 'quantification' 'featurecounts' }
                else { Set-MethodValue 'quantification' 'featurecounts_fadu_audit' }
            }
        }
        elseif (@($script:TypeRadios | Where-Object { $_.Checked }).Count -eq 0) {
            $script:AnalysisType = ''
            Update-AnalysisVisibility
        }
        Update-ModeSelectionDisplay
        Update-RequiredInputInstructions
    })
    $script:TypeRadios += $radio
    $script:TypeCards += $panel
    return $panel
}

$shortCard = New-TypeCard 'short' 'Short reads' "Illumina, DNBSEQ, or other single-end or paired-end FASTQ.`r`nBest for gene-level quantification and high-precision bacterial mapping." 'Exports cleaned FASTQ, short primary BAM/BAI, optional audit BAM, counts, coverage, and QC.'
$longCard = New-TypeCard 'long' 'Long reads' "Oxford Nanopore cDNA or direct RNA, or PacBio HiFi or CLR.`r`nAccepts FASTQ, unaligned BAM, or an Oxford Nanopore POD5 folder." 'Exports long primary BAM/BAI, optional repeat-audit BAM, counts, coverage, and QC.'
$bothCard = New-TypeCard 'both' 'Both, same samples' "Processes matching short-read and long-read data for the same samples.`r`nUses modality-specific methods with shared metadata." 'Exports two independent BAM families. They are linked by sample ID but never merged.'
$typePanel.Controls.Add($shortCard, 0, 0)
$typePanel.Controls.Add($longCard, 1, 0)
$typePanel.Controls.Add($bothCard, 2, 0)

$requiredInputsGroup = New-Object System.Windows.Forms.GroupBox
$requiredInputsGroup.Text = 'Files required for the selected mode'
$requiredInputsGroup.Font = New-Object System.Drawing.Font('Segoe UI', [single]10, [System.Drawing.FontStyle]::Bold)
$requiredInputsGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$requiredInputsGroup.Margin = New-Object System.Windows.Forms.Padding(8, 4, 8, 0)
$requiredInputsGroup.BackColor = $surface
$typeRoot.Controls.Add($requiredInputsGroup, 0, 2)
$requiredInputs = New-Object System.Windows.Forms.RichTextBox
$requiredInputs.Dock = [System.Windows.Forms.DockStyle]::Fill
$requiredInputs.Margin = New-Object System.Windows.Forms.Padding(10)
$requiredInputs.ReadOnly = $true
$requiredInputs.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$requiredInputs.BackColor = $surface
$requiredInputs.ForeColor = $ink
$requiredInputs.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$requiredInputs.WordWrap = $true
$requiredInputs.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
$requiredInputsGroup.Padding = New-Object System.Windows.Forms.Padding(12, 25, 12, 10)
$requiredInputsGroup.Controls.Add($requiredInputs)

function Update-ModeSelectionDisplay {
    foreach ($card in $script:TypeCards) {
        $radio = [System.Windows.Forms.RadioButton]$card.Tag
        $statusMatches = @($card.Controls.Find('selection_status', $true))
        $layoutMatches = @($card.Controls.Find('type_card_layout', $true))
        if ($statusMatches.Count -eq 0 -or $layoutMatches.Count -eq 0) { continue }
        $status = $statusMatches[0]
        $cardLayout = $layoutMatches[0]
        if ($radio.Checked) {
            $card.BackColor = $greenSoft
            $cardLayout.BackColor = $greenSoft
            $status.Text = 'SELECTED'
            $status.BackColor = $green
            $status.ForeColor = $surface
        }
        else {
            $card.BackColor = $surface
            $cardLayout.BackColor = $surface
            $status.Text = 'Click to select'
            $status.BackColor = $surface
            $status.ForeColor = $muted
        }
    }
}

function Update-RequiredInputInstructions {
    $instructionText = ''
    switch ($script:AnalysisType) {
        'short' {
            $instructionText = @"
SHORT-READ FILES
1. Reference genome FASTA (.fa, .fasta, or .fna).
2. Matching bacterial annotation in GFF3 or GTF format.
3. Single-end: one FASTQ per run. Paired-end: explicitly choose mate 1 and mate 2 for the same row. Filenames do not need R1/R2, _1/_2, or any other naming pattern.
4. Sample ID, biological condition, and replicate identity for every included row. Batch is optional. One project may contain Control, Treatment, time points, strains, mutants, or any other number of conditions.

Use a different Sample ID for each biological replicate. Replicate numbering may restart at 1 within each condition. Reuse an ID only for technical sequencing runs that should be merged within that sample.
"@
        }
        'long' {
            $instructionText = @"
LONG-READ FILES
1. Reference genome FASTA (.fa, .fasta, or .fna).
2. Matching bacterial annotation in GFF3 or GTF format.
3. For each run, provide one of: basecalled FASTQ, unaligned BAM, or an ONT POD5 folder.
4. Select ONT cDNA, ONT direct RNA, PacBio HiFi, or PacBio CLR for every long-read row.
5. POD5 input additionally requires Dorado and a chemistry-matched SUP or HAC model.

Assign every row to a biological condition. Use a different Sample ID for each biological replicate, and reuse an ID only for technical runs from the same biological sample. Replicate numbering may restart at 1 within each condition.
"@
        }
        'both' {
            $instructionText = @"
MATCHED SHORT + LONG FILES
1. One reference FASTA and one matching bacterial GFF3 or GTF annotation.
2. Short data: one FASTQ for single-end, or explicitly selected mate 1 and mate 2 FASTQ files for paired-end. Their filenames may use any naming convention.
3. Long data: basecalled FASTQ, unaligned BAM, or an ONT POD5 folder, plus the long-read platform.
4. Use the same Sample ID to link short and long data from the same biological sample. Separate rows are allowed.

Short-read and long-read BAM/BAI families remain independent and are never merged. Multiple biological conditions are supported. Biological replicates require distinct Sample IDs, while the same ID links the short and long modalities of one sample.
"@
        }
        default {
            $instructionText = "Select Short reads, Long reads, or Both above. This panel will then show the exact required files and replicate rules for that mode."
        }
    }
    Set-DescriptionPanelText -Box $requiredInputs -Text $instructionText
}

$clearType.Add_Click({
    foreach ($radio in $script:TypeRadios) { $radio.Checked = $false }
    $script:AnalysisType = ''
    Update-AnalysisVisibility
    Update-ModeSelectionDisplay
    Update-RequiredInputInstructions
})

# Page 2: project, reference, and sample rows
$inputsLayout = New-Object System.Windows.Forms.TableLayoutPanel
$inputsLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$inputsLayout.ColumnCount = 1
$inputsLayout.RowCount = 2
$inputsLayout.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 10)
[void]$inputsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$inputsLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 205)))
[void]$inputsLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$pageInputs.Controls.Add($inputsLayout)

$projectPanel = New-Object System.Windows.Forms.GroupBox
$projectPanel.Text = 'Project and reference'
$projectPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$projectPanel.Margin = New-Object System.Windows.Forms.Padding(4, 2, 4, 5)
$projectPanel.BackColor = $surface
$inputsLayout.Controls.Add($projectPanel, 0, 0)

$projectTable = New-Object System.Windows.Forms.TableLayoutPanel
$projectTable.Dock = [System.Windows.Forms.DockStyle]::Fill
$projectTable.ColumnCount = 3
$projectTable.RowCount = 4
$projectTable.Padding = New-Object System.Windows.Forms.Padding(10, 20, 10, 7)
[void]$projectTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 105)))
[void]$projectTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$projectTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 112)))
[void]$projectTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 60)))
foreach ($index in 1..3) { [void]$projectTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.333))) }
$projectPanel.Controls.Add($projectTable)

$projectName = New-TextBox 0 0 220
$projectName.Width = 220
$projectName.Margin = New-Object System.Windows.Forms.Padding(3, 5, 12, 3)
$cpuTopology = Get-CpuTopology
$threadsBox = New-Object System.Windows.Forms.NumericUpDown
$threadsBox.Minimum = 1; $threadsBox.Maximum = [Math]::Max(1, $cpuTopology.Logical); $threadsBox.Value = $cpuTopology.Recommended
$threadsBox.Size = New-Object System.Drawing.Size(65, 25)
$threadsBox.Margin = New-Object System.Windows.Forms.Padding(3, 5, 6, 3)
$mapqBox = New-Object System.Windows.Forms.NumericUpDown
$mapqBox.Minimum = 0; $mapqBox.Maximum = 255; $mapqBox.Value = 10
$mapqBox.Size = New-Object System.Drawing.Size(60, 25)
$mapqBox.Margin = New-Object System.Windows.Forms.Padding(3, 5, 10, 3)
$featureType = New-Object System.Windows.Forms.ComboBox
$featureType.Size = New-Object System.Drawing.Size(105, 25)
$featureType.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($choice in @('auto','gene','CDS','exon','Custom...')) { [void]$featureType.Items.Add($choice) }
$featureType.SelectedIndex = 0
$featureType.Margin = New-Object System.Windows.Forms.Padding(3, 5, 10, 3)
$idAttribute = New-Object System.Windows.Forms.ComboBox
$idAttribute.Size = New-Object System.Drawing.Size(110, 25)
$idAttribute.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($choice in @('auto','locus_tag','gene_id','ID','gene','Name','Parent','Custom...')) { [void]$idAttribute.Items.Add($choice) }
$idAttribute.SelectedIndex = 0
$idAttribute.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 3)

# Keep these selectors visually neutral while still supporting unusual bacterial
# annotations. The visible controls are true list selectors, so Windows cannot
# select the edit text in blue. "Custom..." opens a small one-time entry dialog.
$featureType.Add_SelectedIndexChanged({
    if ([string]$featureType.SelectedItem -ne 'Custom...') { return }
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue } catch { }
    $value = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Enter the exact feature type used in the annotation (for example transcript, ncRNA, or pseudogene).',
        'Custom feature type',
        ''
    ).Trim()
    if ($value) {
        if (-not $featureType.Items.Contains($value)) {
            $customIndex = $featureType.Items.IndexOf('Custom...')
            if ($customIndex -lt 0) { [void]$featureType.Items.Add($value) } else { $featureType.Items.Insert($customIndex, $value) }
        }
        $featureType.SelectedItem = $value
    } else { $featureType.SelectedItem = 'auto' }
})
$idAttribute.Add_SelectedIndexChanged({
    if ([string]$idAttribute.SelectedItem -ne 'Custom...') { return }
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue } catch { }
    $value = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Enter the exact GFF/GTF attribute name that uniquely identifies each feature.',
        'Custom gene ID attribute',
        ''
    ).Trim()
    if ($value) {
        if (-not $idAttribute.Items.Contains($value)) {
            $customIndex = $idAttribute.Items.IndexOf('Custom...')
            if ($customIndex -lt 0) { [void]$idAttribute.Items.Add($value) } else { $idAttribute.Items.Insert($customIndex, $value) }
        }
        $idAttribute.SelectedItem = $value
    } else { $idAttribute.SelectedItem = 'auto' }
})

$projectOptions = New-Object System.Windows.Forms.FlowLayoutPanel
$projectOptions.Dock = [System.Windows.Forms.DockStyle]::Fill
$projectOptions.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$projectOptions.WrapContents = $true
$projectOptions.Margin = New-Object System.Windows.Forms.Padding(0)
$projectOptions.Padding = New-Object System.Windows.Forms.Padding(0)
$threadsLabel = New-TableLabel 'Threads'; $threadsLabel.Size = New-Object System.Drawing.Size(53, 29); $threadsLabel.Dock = [System.Windows.Forms.DockStyle]::None
$mapqLabel = New-TableLabel 'Minimum MAPQ'; $mapqLabel.Size = New-Object System.Drawing.Size(102, 29); $mapqLabel.Dock = [System.Windows.Forms.DockStyle]::None
$featureLabel = New-TableLabel 'Feature type'; $featureLabel.Size = New-Object System.Drawing.Size(78, 29); $featureLabel.Dock = [System.Windows.Forms.DockStyle]::None
$idLabel = New-TableLabel 'Gene ID'; $idLabel.Size = New-Object System.Drawing.Size(55, 29); $idLabel.Dock = [System.Windows.Forms.DockStyle]::None
$cpuHint = New-TableLabel ("CPU: {0} logical | Recommended: {1}" -f $cpuTopology.Logical, $cpuTopology.Recommended)
$cpuHint.Size = New-Object System.Drawing.Size(220, 29)
$cpuHint.Dock = [System.Windows.Forms.DockStyle]::None
$cpuHint.ForeColor = $muted
$cpuHint.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$cpuDescription = "This computer reports $($cpuTopology.Logical) logical processor(s)" + $(if ($cpuTopology.Physical) { " and $($cpuTopology.Physical) physical core(s)" } else { '' }) + ". The recommended value reserves about 25% for Windows and the GUI. You may lower it when running other demanding software."
$toolTip.SetToolTip($threadsBox, $cpuDescription)
$toolTip.SetToolTip($cpuHint, $cpuDescription)
$mapqHelpText = @"
What this setting controls:
MAPQ means mapping quality. It indicates how confidently an aligner placed a read at a genomic location. Minimum MAPQ is the lowest score accepted when the software creates gene counts, performs the strand audit, and generates coverage tracks. Alignments below the cutoff remain in the exported BAM file, but they are excluded from these derived results.

Allowed and practical range:
The software accepts values from [0] to [255]. For most bacterial RNA-seq projects, the useful working range is [0] to [30]. MAPQ scales differ among aligners, so the same number does not represent exactly the same confidence for every alignment method.

Recommended starting value:
[10] is the recommended balanced setting for general bacterial RNA-seq. It retains most confidently placed reads while excluding alignments with very low mapping confidence.

When to use a different value:
Choose [0] to [5] when retaining reads from repetitive, highly similar, or divergent regions matters more than mapping specificity. Choose [20] to [30] when only strongly supported placements should contribute to counts and coverage. Higher cutoffs can reduce counts for paralogs, repeats, and closely related genes.
"@
$featureHelpText = @"
What this setting controls:
The third column of a GFF3 or GTF file labels each annotation row as a feature type, such as gene, CDS, or exon. This setting tells the software which type of row should become a countable feature. Rows with other feature types are not used to construct the count table.

Recommended selection:
[auto]  Uses gene rows when available. If gene rows are absent, it tries CDS and then exon. If none of those types exists, it uses the most common feature type in the annotation.

Available selections:
[gene]  Usually gives one count-table entry per annotated bacterial gene and is the preferred explicit choice when gene rows are present.
[CDS]  Uses coding-sequence rows. Choose this when the annotation does not provide suitable gene rows.
[exon]  Uses exon rows and is mainly intended for annotations organized around exon features.

If you are unsure, leave [auto] selected.
"@
$idHelpText = @"
What this setting controls:
Every row in the exported count matrix needs a stable identifier. This setting chooses which attribute from the ninth column of the GFF3 or GTF file supplies that identifier. It changes the count-table row names; it does not change the genomic coordinates or sequence.

Recommended selection:
[auto]  Chooses the identifier attribute found on the largest number of selected feature rows. For bacterial gene annotations, this is often locus_tag.

Available selections:
[locus_tag]  Usually contains a stable bacterial locus identifier, for example AMY_01234.
[gene_id]  Is commonly used as the identifier in GTF files.
[ID]  Is commonly used as the identifier in GFF3 files.
[gene] or [Name]  May provide a readable gene symbol, but the values are not always unique.
[Parent]  Is mainly useful for CDS or exon rows that refer to a parent gene.

If you are unsure, leave [auto] selected. Choose a specific field only when you know that it is present and uniquely identifies the features being counted.
"@
$mapqHelp = New-HelpIcon $mapqHelpText 'Minimum mapping quality (MAPQ)'
$featureHelp = New-HelpIcon $featureHelpText 'Annotation feature type'
$idHelp = New-HelpIcon $idHelpText 'Count-table gene identifier'
$projectOptions.Controls.AddRange(@($projectName, $threadsLabel, $threadsBox, $cpuHint, $mapqLabel, $mapqBox, $mapqHelp, $featureLabel, $featureType, $featureHelp, $idLabel, $idAttribute, $idHelp))

$outputFolder = New-TextBox 0 0
$referenceFasta = New-TextBox 0 0
$annotationFile = New-TextBox 0 0
foreach ($box in @($outputFolder, $referenceFasta, $annotationFile)) {
    $box.Dock = [System.Windows.Forms.DockStyle]::Fill
    $box.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 3)
}
$browseOutput = New-Button 'Browse' 0 0 104 28
$browseFasta = New-Button 'Browse' 0 0 104 28
$browseAnnotation = New-Button 'Browse' 0 0 104 28
foreach ($button in @($browseOutput, $browseFasta, $browseAnnotation)) {
    $button.Dock = [System.Windows.Forms.DockStyle]::Fill
    $button.Margin = New-Object System.Windows.Forms.Padding(4, 3, 3, 3)
}

$projectNameLabel = New-TableLabel 'Project name'
$projectNameLabel.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
$projectNameLabel.Padding = New-Object System.Windows.Forms.Padding(0, 9, 0, 0)
$projectNameLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$projectTable.Controls.Add($projectNameLabel, 0, 0)
$projectTable.Controls.Add($projectOptions, 1, 0)
$projectTable.SetColumnSpan($projectOptions, 2)
$projectTable.Controls.Add((New-TableLabel 'Output folder'), 0, 1)
$projectTable.Controls.Add($outputFolder, 1, 1)
$projectTable.Controls.Add($browseOutput, 2, 1)
$projectTable.Controls.Add((New-TableLabel 'Reference FASTA'), 0, 2)
$projectTable.Controls.Add($referenceFasta, 1, 2)
$projectTable.Controls.Add($browseFasta, 2, 2)
$projectTable.Controls.Add((New-TableLabel 'GFF3 or GTF'), 0, 3)
$projectTable.Controls.Add($annotationFile, 1, 3)
$projectTable.Controls.Add($browseAnnotation, 2, 3)

$browseOutput.Add_Click({ $value = Select-Folder 'Select the analysis output folder'; if ($value) { $outputFolder.Text = $value } })
$browseFasta.Add_Click({ $value = Select-File 'FASTA (*.fa;*.fasta;*.fna;*.gz)|*.fa;*.fasta;*.fna;*.fa.gz;*.fasta.gz;*.fna.gz|All files (*.*)|*.*'; if ($value) { $referenceFasta.Text = $value } })
$browseAnnotation.Add_Click({ $value = Select-File 'Annotation (*.gff;*.gff3;*.gtf;*.gz)|*.gff;*.gff3;*.gtf;*.gff.gz;*.gff3.gz;*.gtf.gz|All files (*.*)|*.*'; if ($value) { $annotationFile.Text = $value } })


$toolTip.SetToolTip($outputFolder, 'Select the writable Results folder for this RNA-seq run. After successful completion the visible root is simplified to Counts & Annotation.xlsx, BAM-BAI-IGV, QC Analysis.html, and intermediate.')
$toolTip.SetToolTip($browseOutput, 'Choose the writable parent Results folder for the RNA-seq processing run.')
$toolTip.SetToolTip($referenceFasta, 'Required reference genome FASTA. Accepted: .fa, .fasta, .fna and gzipped equivalents. Use the same genome build as the annotation file.')
$toolTip.SetToolTip($browseFasta, 'Browse for the reference genome FASTA (.fa, .fasta, .fna, optionally .gz).')
$toolTip.SetToolTip($annotationFile, 'Required genome annotation matching the reference FASTA. Accepted: .gff, .gff3, .gtf and gzipped equivalents. Contig names must match the FASTA.')
$toolTip.SetToolTip($browseAnnotation, 'Browse for the matching GFF/GFF3/GTF annotation file.')

$gridGroup = New-Object System.Windows.Forms.GroupBox
$gridGroup.Text = 'Samples and replicates  Reuse a Sample ID for technical runs; use distinct IDs for biological replicates'
$gridGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$gridGroup.Margin = New-Object System.Windows.Forms.Padding(4, 5, 4, 2)
$gridGroup.BackColor = $surface
$inputsLayout.Controls.Add($gridGroup, 0, 1)

$gridLayout = New-Object System.Windows.Forms.TableLayoutPanel
$gridLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$gridLayout.ColumnCount = 1
$gridLayout.RowCount = 3
$gridLayout.Padding = New-Object System.Windows.Forms.Padding(9, 22, 9, 8)
[void]$gridLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$gridLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 43)))
[void]$gridLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$gridLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 82)))
$gridGroup.Controls.Add($gridLayout)

$designBar = New-Object System.Windows.Forms.FlowLayoutPanel
$designBar.Dock = [System.Windows.Forms.DockStyle]::Fill
$designBar.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$designBar.WrapContents = $false
$designBar.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$designBar.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$gridLayout.Controls.Add($designBar, 0, 0)

$conditionLabel = New-Object System.Windows.Forms.Label
$conditionLabel.Text = 'Condition for new rows'
$conditionLabel.AutoSize = $false
$conditionLabel.Size = New-Object System.Drawing.Size(145, 29)
$conditionLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$conditionLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.25, [System.Drawing.FontStyle]::Bold)
$conditionLabel.ForeColor = $greenDark
$conditionLabel.Margin = New-Object System.Windows.Forms.Padding(0, 1, 4, 0)

$conditionSelector = New-Object System.Windows.Forms.ComboBox
$conditionSelector.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$conditionSelector.Size = New-Object System.Drawing.Size(175, 28)
$conditionSelector.Margin = New-Object System.Windows.Forms.Padding(0, 1, 8, 0)
[void]$conditionSelector.Items.Add('Control')
[void]$conditionSelector.Items.Add('Treatment')
[void]$conditionSelector.Items.Add('Add new condition...')
$conditionSelector.SelectedItem = 'Control'
$conditionSelector.Add_SelectedIndexChanged({
    if ([string]$conditionSelector.SelectedItem -ne 'Add new condition...') { return }
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue } catch { }
    $value = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Enter a biological condition name, for example Time_0, Time_24, Wild_type, or Mutant.',
        'Add condition',
        ''
    ).Trim()
    if ($value) {
        if (-not $conditionSelector.Items.Contains($value)) {
            $addIndex = $conditionSelector.Items.IndexOf('Add new condition...')
            if ($addIndex -lt 0) { [void]$conditionSelector.Items.Add($value) } else { $conditionSelector.Items.Insert($addIndex, $value) }
        }
        $conditionSelector.SelectedItem = $value
    } else { $conditionSelector.SelectedItem = 'Control' }
})

$applyCondition = New-Button 'Apply to selected row(s)' 0 0 168 29
$applyCondition.Margin = New-Object System.Windows.Forms.Padding(0, 0, 7, 0)
$addBlankReplicate = New-Button 'Add blank replicate' 0 0 138 29
$addBlankReplicate.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)

$designSummary = New-Object System.Windows.Forms.Label
$designSummary.Text = 'Study design: no samples assigned yet'
$designSummary.AutoSize = $false
$designSummary.Size = New-Object System.Drawing.Size(500, 29)
$designSummary.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$designSummary.ForeColor = $muted
$designSummary.Font = New-Object System.Drawing.Font('Segoe UI', 8.75)
$designSummary.Margin = New-Object System.Windows.Forms.Padding(0, 1, 0, 0)

$designBar.Controls.AddRange(@($conditionLabel, $conditionSelector, $applyCondition, $addBlankReplicate, $designSummary))
$toolTip.SetToolTip($conditionSelector, 'Choose the biological condition assigned to newly added rows. Use Add new condition... for Time_0, Time_24, Wild_type, Mutant, or any other condition. Any number of conditions is supported.')
$toolTip.SetToolTip($applyCondition, 'Applies the condition shown on the left to the current row and every row containing a selected cell. Replicate numbering remains independent within each condition.')
$toolTip.SetToolTip($addBlankReplicate, 'Adds an empty sample row for the selected condition and assigns the next replicate number within that condition.')

$sampleGrid = New-Object System.Windows.Forms.DataGridView
$sampleGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$sampleGrid.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$sampleGrid.AllowUserToAddRows = $true
$sampleGrid.AllowUserToDeleteRows = $true
$sampleGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$sampleGrid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::None
$sampleGrid.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$sampleGrid.RowHeadersWidth = 38
$sampleGrid.BackgroundColor = $surface
$sampleGrid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$sampleGrid.EnableHeadersVisualStyles = $false
$sampleGrid.GridColor = [System.Drawing.Color]::Black
$sampleGrid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::Single
$sampleGrid.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::Single
# Several input headings intentionally wrap (for example, Short mate 1 /
# single-end FASTQ). Auto-size the header row so the second line remains visible
# at Windows display scaling above 100%.
$sampleGrid.ColumnHeadersHeight = 46
$sampleGrid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
$sampleGrid.ColumnHeadersDefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
$sampleGrid.ColumnHeadersDefaultCellStyle.BackColor = $greenSoft
$sampleGrid.ColumnHeadersDefaultCellStyle.ForeColor = $greenDark
$sampleGrid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $greenSoft
$sampleGrid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $greenDark
$sampleGrid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9.25, [System.Drawing.FontStyle]::Bold)
$sampleGrid.DefaultCellStyle.BackColor = $surface
$sampleGrid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(249, 251, 249)
$sampleGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::CellSelect
$sampleGrid.MultiSelect = $true
$sampleGrid.EditMode = [System.Windows.Forms.DataGridViewEditMode]::EditOnEnter
$gridLayout.Controls.Add($sampleGrid, 0, 1)

$includeCol = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$includeCol.Name = 'include'; $includeCol.HeaderText = 'Use'; $includeCol.Width = 42; $includeCol.MinimumWidth = 42; $includeCol.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::None; $includeCol.TrueValue = $true; $includeCol.FalseValue = $false
$sampleGrid.Columns.Add($includeCol) | Out-Null
foreach ($spec in @(
    @('sample_id','Sample ID',105,11), @('condition','Condition',115,11), @('replicate','Replicate',72,7), @('batch','Batch',70,7),
    @('short_r1','Short mate 1 / single-end FASTQ',235,20), @('short_r2','Short mate 2 FASTQ',190,19), @('long_reads','Long FASTQ or BAM',180,18), @('pod5_dir','ONT POD5 folder',170,17)
)) {
    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $spec[0]; $column.HeaderText = $spec[1]; $column.MinimumWidth = [int]$spec[2]; $column.FillWeight = [single]$spec[3]; $column.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $sampleGrid.Columns.Add($column) | Out-Null
}
$script:LongPlatformOptions = @(
    [ordered]@{ Label = 'Oxford Nanopore cDNA'; Value = 'ont_cdna' },
    [ordered]@{ Label = 'Oxford Nanopore direct RNA'; Value = 'ont_direct_rna' },
    [ordered]@{ Label = 'PacBio HiFi'; Value = 'pacbio_hifi' },
    [ordered]@{ Label = 'PacBio CLR'; Value = 'pacbio_clr' }
)
# DataGridViewComboBoxColumn requires a .NET data source whose fields are visible
# through TypeDescriptor. A DataTable is used instead of PSCustomObject rows so
# Windows PowerShell 5.1 can reliably resolve the Label and Value fields.
$script:LongPlatformTable = New-Object System.Data.DataTable 'LongPlatformOptions'
[void]$script:LongPlatformTable.Columns.Add('Label', [string])
[void]$script:LongPlatformTable.Columns.Add('Value', [string])
foreach ($option in $script:LongPlatformOptions) {
    $optionRow = $script:LongPlatformTable.NewRow()
    $optionRow['Label'] = [string]$option['Label']
    $optionRow['Value'] = [string]$option['Value']
    [void]$script:LongPlatformTable.Rows.Add($optionRow)
}
function Convert-ToLongPlatformCode([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $normalized = (($Value.Trim().ToLowerInvariant()) -replace '[^a-z0-9]+', '_').Trim('_')
    switch ($normalized) {
        'ont_cdna' { return 'ont_cdna' }
        'oxford_nanopore_cdna' { return 'ont_cdna' }
        'ont_direct_rna' { return 'ont_direct_rna' }
        'oxford_nanopore_direct_rna' { return 'ont_direct_rna' }
        'pacbio_hifi' { return 'pacbio_hifi' }
        'pacbio_clr' { return 'pacbio_clr' }
        default { return $Value.Trim() }
    }
}
$platformCol = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$platformCol.Name = 'long_platform'; $platformCol.HeaderText = 'Long-read platform'; $platformCol.MinimumWidth = 180; $platformCol.FillWeight = [single]15; $platformCol.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
$platformCol.DisplayMember = 'Label'
$platformCol.ValueMember = 'Value'
$platformCol.DataSource = $script:LongPlatformTable
$platformCol.DisplayStyle = [System.Windows.Forms.DataGridViewComboBoxDisplayStyle]::DropDownButton
$sampleGrid.Columns.Add($platformCol) | Out-Null

$sampleGrid.Columns['condition'].ToolTipText = 'Biological condition or group. Multiple conditions are supported in one project, for example Control and Treatment.'
$sampleGrid.Columns['replicate'].ToolTipText = 'Biological replicate number within the condition. Numbering may restart at 1 for each condition.'
$sampleGrid.Columns['sample_id'].ToolTipText = 'Sample identifier used in count matrices and downstream metadata. Reuse an ID only for technical runs that should be combined; biological replicates should have distinct IDs.'
$sampleGrid.Columns['batch'].ToolTipText = 'Optional batch label for downstream statistical adjustment. Leave blank when there is no known batch factor.'
$sampleGrid.Columns['short_r1'].ToolTipText = 'Short-read FASTQ mate 1, or the only FASTQ for a single-end library. Accepted compressed or uncompressed FASTQ.'
$sampleGrid.Columns['short_r2'].ToolTipText = 'Short-read FASTQ mate 2 for paired-end libraries. Leave empty for single-end libraries.'
$sampleGrid.Columns['long_reads'].ToolTipText = 'Long-read input: Oxford Nanopore/PacBio FASTQ or an unaligned BAM when supported by the selected workflow.'
$sampleGrid.Columns['pod5_dir'].ToolTipText = 'Optional Oxford Nanopore POD5 folder. Use only when Dorado basecalling is required; otherwise provide long-read FASTQ/BAM instead.'
$sampleGrid.Columns['long_platform'].ToolTipText = 'Long-read platform used to choose suitable defaults: Oxford Nanopore, PacBio HiFi, or PacBio CLR.'
$sampleGrid.Columns['condition'].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(244, 249, 255)
$sampleGrid.Columns['replicate'].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(249, 252, 247)

$sampleActions = New-Object System.Windows.Forms.FlowLayoutPanel
$sampleActions.Dock = [System.Windows.Forms.DockStyle]::Fill
$sampleActions.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$sampleActions.WrapContents = $true
$sampleActions.AutoScroll = $true
$sampleActions.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$sampleActions.Margin = New-Object System.Windows.Forms.Padding(0)
$gridLayout.Controls.Add($sampleActions, 0, 2)
$addPaired = New-Button 'Add paired-end (mate 1 + mate 2)' 0 0 218 30
$addSingle = New-Button 'Add single-end FASTQ(s)' 0 0 162 30
$scanFastq = New-Button 'Scan FASTQ folder' 0 0 145 30
$addLongReads = New-Button 'Add long FASTQ/BAM' 0 0 157 30
$addPod5 = New-Button 'Add ONT POD5 folder' 0 0 155 30
$removeRow = New-Button 'Remove selected' 0 0 125 30
$clearSamples = New-Button 'Clear samples' 0 0 112 30
$importSheet = New-Button 'Import sample sheet' 0 0 145 30
$exportSheet = New-Button 'Export template' 0 0 120 30
foreach ($button in @($addPaired, $addSingle, $scanFastq, $addLongReads, $addPod5, $removeRow, $clearSamples, $importSheet, $exportSheet)) {
    $button.Margin = New-Object System.Windows.Forms.Padding(3, 0, 5, 4)
}
$sampleActions.Controls.AddRange(@($addPaired, $addSingle, $scanFastq, $addLongReads, $addPod5, $removeRow, $clearSamples, $importSheet, $exportSheet))
$toolTip.SetToolTip($importSheet, 'Imports only a sample sheet containing metadata and paths to FASTQ, BAM, or POD5 inputs. CSV/TSV is not a raw RNA-seq read format; the sequencing files themselves must remain FASTQ, BAM, or POD5.')
$toolTip.SetToolTip($exportSheet, 'Exports a CSV sample-sheet template. Fill it with sample metadata and file paths, then use Import sample sheet.')
$toolTip.SetToolTip($addPaired, 'Select exactly two files sequentially. The first is mate 1 and the second is mate 2. Filenames do not need R1/R2 or matching stems.')
$toolTip.SetToolTip($scanFastq, 'Automatic folder scanning still uses common R1/R2 or _1/_2 filename patterns. For arbitrary filenames, use Add paired-end and select the two mates explicitly.')

function Get-FastqStem([string]$Path) {
    $name = [System.IO.Path]::GetFileName($Path)
    return [regex]::Replace($name, '(?i)\.(fastq|fq|bam)(\.gz)?$', '')
}

function Get-ReadMateNumber([string]$Path) {
    $stem = Get-FastqStem $Path
    if ($stem -match '(?i)(^|[._-])R1([._-]?00[1-9])?$') { return 1 }
    if ($stem -match '(?i)(^|[._-])R2([._-]?00[1-9])?$') { return 2 }
    if ($stem -match '(?i)(^|[._-])1$') { return 1 }
    if ($stem -match '(?i)(^|[._-])2$') { return 2 }
    return 0
}

function Get-ReadPairKey([string]$Path) {
    $stem = Get-FastqStem $Path
    return [regex]::Replace($stem, '(?i)([._-])R?[12]([._-]?00[1-9])?$', '')
}

function Get-SafeSampleId([string]$Path) {
    $stem = Get-ReadPairKey $Path
    $stem = [regex]::Replace($stem, '(?i)([._-])S\d+([._-])L\d{3}$', '')
    $stem = [regex]::Replace($stem, '(?i)([._-])L\d{3}$', '')
    $sampleId = [regex]::Replace($stem, '[^A-Za-z0-9._-]+', '_')
    $sampleId = $sampleId.Trim([char[]]'_-.')
    if (-not $sampleId) { $sampleId = 'sample' }
    if ($sampleId -notmatch '^[A-Za-z0-9]') { $sampleId = "sample_$sampleId" }
    return $sampleId
}

function Test-SampleRowEmpty([System.Windows.Forms.DataGridViewRow]$Row) {
    foreach ($name in @('sample_id','condition','batch','short_r1','short_r2','long_reads','pod5_dir','long_platform')) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Row.Cells[$name].Value)) { return $false }
    }
    return $true
}

function Get-ActiveCondition {
    $condition = $conditionSelector.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($condition)) {
        $condition = 'Control'
        $conditionSelector.Text = $condition
    }
    return $condition
}

function Get-NextReplicateNumber([string]$Condition) {
    $targetCondition = ([string]$Condition).Trim()
    $largest = 0
    foreach ($row in $sampleGrid.Rows) {
        if ($row.IsNewRow) { continue }
        $rowCondition = ([string]$row.Cells['condition'].Value).Trim()
        if (-not [string]::Equals($rowCondition, $targetCondition, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $value = [string]$row.Cells['replicate'].Value
        if ($value -match '^\d+$') { $largest = [Math]::Max($largest, [int]$value) }
    }
    return ($largest + 1)
}

function Get-SelectedSampleRows {
    $indices = @{}
    foreach ($cell in $sampleGrid.SelectedCells) {
        if ($cell.RowIndex -ge 0 -and -not $sampleGrid.Rows[$cell.RowIndex].IsNewRow) { $indices[$cell.RowIndex] = $true }
    }
    if ($sampleGrid.CurrentRow -and -not $sampleGrid.CurrentRow.IsNewRow) { $indices[$sampleGrid.CurrentRow.Index] = $true }
    return @($indices.Keys | Sort-Object | ForEach-Object { $sampleGrid.Rows[[int]$_] })
}

function Update-ConditionDesignSummary {
    if (-not $designSummary -or -not $sampleGrid) { return }
    $conditionSamples = @{}
    $unassigned = 0
    foreach ($row in $sampleGrid.Rows) {
        if ($row.IsNewRow) { continue }
        $includeValue = $row.Cells['include'].Value
        if ($null -ne $includeValue -and -not [bool]$includeValue) { continue }
        if (Test-SampleRowEmpty $row) { continue }
        $condition = ([string]$row.Cells['condition'].Value).Trim()
        if (-not $condition) { $unassigned++; continue }
        if (-not $conditionSamples.ContainsKey($condition)) { $conditionSamples[$condition] = @{} }
        $sampleId = ([string]$row.Cells['sample_id'].Value).Trim()
        if (-not $sampleId) { $sampleId = "row_$($row.Index)" }
        $conditionSamples[$condition][$sampleId] = $true
        if (-not $conditionSelector.Items.Contains($condition)) {
            $addIndex = $conditionSelector.Items.IndexOf('Add new condition...')
            if ($addIndex -lt 0) { [void]$conditionSelector.Items.Add($condition) } else { $conditionSelector.Items.Insert($addIndex, $condition) }
        }
    }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($condition in ($conditionSamples.Keys | Sort-Object)) {
        $parts.Add("$condition $($conditionSamples[$condition].Count)")
    }
    if ($unassigned -gt 0) { $parts.Add("Unassigned $unassigned") }
    if ($parts.Count -eq 0) {
        $designSummary.Text = 'Study design: no samples assigned yet'
        $designSummary.ForeColor = $muted
    }
    else {
        $designSummary.Text = 'Study design: ' + ($parts -join '  |  ')
        $designSummary.ForeColor = $(if ($conditionSamples.Count -ge 2) { $greenDark } else { $muted })
    }
}

function Get-AvailableSampleRowIndex {
    foreach ($row in $sampleGrid.Rows) {
        if (-not $row.IsNewRow -and (Test-SampleRowEmpty $row)) { return $row.Index }
    }
    return $sampleGrid.Rows.Add()
}

function Add-SampleFileRow([hashtable]$Values) {
    $matchingRow = $null
    if ($Values.ContainsKey('sample_id')) {
        $sampleId = [string]$Values['sample_id']
        foreach ($candidate in $sampleGrid.Rows) {
            if ($candidate.IsNewRow -or [string]$candidate.Cells['sample_id'].Value -ne $sampleId) { continue }
            if ($null -eq $matchingRow) { $matchingRow = $candidate }
            if ($script:AnalysisType -ne 'both') { continue }
            $shortCompatible = $true
            $longCompatible = $true
            if ($Values.ContainsKey('short_r1') -or $Values.ContainsKey('short_r2')) {
                $shortCompatible = [string]::IsNullOrWhiteSpace([string]$candidate.Cells['short_r1'].Value) -and [string]::IsNullOrWhiteSpace([string]$candidate.Cells['short_r2'].Value)
            }
            if ($Values.ContainsKey('long_reads') -or $Values.ContainsKey('pod5_dir')) {
                $longCompatible = [string]::IsNullOrWhiteSpace([string]$candidate.Cells['long_reads'].Value) -and [string]::IsNullOrWhiteSpace([string]$candidate.Cells['pod5_dir'].Value)
            }
            if ($shortCompatible -and $longCompatible) {
                foreach ($name in $Values.Keys) { $candidate.Cells[$name].Value = [string]$Values[$name] }
                $candidate.Cells['include'].Value = $true
                return $candidate.Index
            }
        }
    }

    $index = Get-AvailableSampleRowIndex
    $row = $sampleGrid.Rows[$index]
    $row.Cells['include'].Value = $true
    if ($null -ne $matchingRow) {
        foreach ($name in @('condition','replicate','batch')) {
            if ([string]::IsNullOrWhiteSpace([string]$row.Cells[$name].Value)) { $row.Cells[$name].Value = $matchingRow.Cells[$name].Value }
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace([string]$row.Cells['condition'].Value)) { $row.Cells['condition'].Value = Get-ActiveCondition }
        if ([string]::IsNullOrWhiteSpace([string]$row.Cells['replicate'].Value)) {
            $row.Cells['replicate'].Value = (Get-NextReplicateNumber ([string]$row.Cells['condition'].Value)).ToString()
        }
    }
    foreach ($name in $Values.Keys) { $row.Cells[$name].Value = [string]$Values[$name] }
    Update-ConditionDesignSummary
    return $index
}

function Add-PairedShortReadFiles {
    $mate1 = Select-File -Filter 'FASTQ (*.fastq;*.fq;*.gz)|*.fastq;*.fq;*.fastq.gz;*.fq.gz|All files (*.*)|*.*' -Title 'Choose paired-end mate 1. The filename can be anything.'
    if (-not $mate1) { return }
    $mate2 = Select-File -Filter 'FASTQ (*.fastq;*.fq;*.gz)|*.fastq;*.fq;*.fastq.gz;*.fq.gz|All files (*.*)|*.*' -Title 'Choose paired-end mate 2. The filename can be anything.'
    if (-not $mate2) { return }
    if ([string]::Equals($mate1, $mate2, [System.StringComparison]::OrdinalIgnoreCase)) {
        Show-Error 'Mate 1 and mate 2 must be two different FASTQ files.'
        return
    }

    # Explicit user selection defines the layout. Filenames are deliberately
    # not inspected for R1/R2, _1/_2, forward/reverse, or matching stems.
    [void](Add-SampleFileRow @{
        sample_id = (Get-SafeSampleId $mate1)
        short_r1 = $mate1
        short_r2 = $mate2
    })
    Show-Info "One paired-end biological replicate row was added.`r`n`r`nThe first selected file is mate 1 and the second selected file is mate 2. Filename patterns are not required. Review Sample ID, Condition, and Replicate before continuing."
}

function Add-SingleShortReadFiles {
    $files = @(Select-Files 'Select single-end FASTQ file(s)' 'FASTQ (*.fastq;*.fq;*.gz)|*.fastq;*.fq;*.fastq.gz;*.fq.gz|All files (*.*)|*.*')
    if ($files.Count -eq 0) { return }
    $added = 0
    foreach ($path in ($files | Sort-Object)) {
        # The selected action defines a single-end library. A filename ending in
        # R2, _2, reverse, or any other token is not used to override the user.
        [void](Add-SampleFileRow @{ sample_id = (Get-SafeSampleId $path); short_r1 = $path })
        $added++
    }
    Show-Info "$added single-end biological replicate row(s) were added. Filename patterns were not interpreted. Review Sample ID, Condition, and Replicate before continuing."
}

function Scan-ShortFastqFolder {
    $folder = Select-Folder 'Select a folder containing short-read FASTQ files. Automatic pairing uses common filename patterns; use Add paired-end for arbitrary names.'
    if (-not $folder) { return }
    $files = @(Get-ChildItem -LiteralPath $folder -File | Where-Object { $_.Name -match '(?i)\.(fastq|fq)(\.gz)?$' } | ForEach-Object { $_.FullName })
    if ($files.Count -eq 0) { Show-Error 'No .fastq, .fq, .fastq.gz, or .fq.gz files were found in the selected folder.'; return }

    $groups = @{}
    $unmarked = New-Object System.Collections.Generic.List[string]
    foreach ($path in $files) {
        $mate = Get-ReadMateNumber $path
        if ($mate -eq 0) { $unmarked.Add($path); continue }
        $key = (Get-ReadPairKey $path).ToLowerInvariant()
        if (-not $groups.ContainsKey($key)) { $groups[$key] = @{ r1 = @(); r2 = @() } }
        if ($mate -eq 1) { $groups[$key].r1 += $path } else { $groups[$key].r2 += $path }
    }

    $added = 0
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($key in ($groups.Keys | Sort-Object)) {
        $r1 = @($groups[$key].r1 | Sort-Object)
        $r2 = @($groups[$key].r2 | Sort-Object)
        if ($r1.Count -gt 0 -and $r2.Count -eq 0) {
            foreach ($path in $r1) { [void](Add-SampleFileRow @{ sample_id = (Get-SafeSampleId $path); short_r1 = $path }); $added++ }
        }
        elseif ($r1.Count -eq $r2.Count -and $r1.Count -gt 0) {
            for ($i = 0; $i -lt $r1.Count; $i++) {
                [void](Add-SampleFileRow @{ sample_id = (Get-SafeSampleId $r1[$i]); short_r1 = $r1[$i]; short_r2 = $r2[$i] })
                $added++
            }
        }
        else {
            $warnings.Add("Skipped '$key': found $($r1.Count) R1 and $($r2.Count) R2 files.")
        }
    }
    foreach ($path in $unmarked) { [void](Add-SampleFileRow @{ sample_id = (Get-SafeSampleId $path); short_r1 = $path }); $added++ }

    $message = "$added sample row(s) were added from the folder. Automatic folder pairing uses common R1/R2 or _1/_2 patterns. Use Add paired-end for arbitrary filenames. Review Sample ID, Condition, and Replicate."
    if ($warnings.Count -gt 0) { $message += "`r`n`r`n" + ($warnings -join "`r`n") }
    if ($added -eq 0) { Show-Error $message } else { Show-Info $message }
}

function Add-LongReadFiles {
    $files = @(Select-Files 'Select long-read FASTQ or unaligned BAM file(s)' 'Long reads (*.fastq;*.fq;*.bam;*.gz)|*.fastq;*.fq;*.fastq.gz;*.fq.gz;*.bam|All files (*.*)|*.*')
    if ($files.Count -eq 0) { return }
    foreach ($path in ($files | Sort-Object)) {
        [void](Add-SampleFileRow @{ sample_id = (Get-SafeSampleId $path); long_reads = $path })
    }
    Show-Info "$($files.Count) long-read row(s) were added. Select Oxford Nanopore cDNA, Oxford Nanopore direct RNA, PacBio HiFi, or PacBio CLR in each row before continuing."
}

function Add-Pod5Folder {
    $folder = Select-Folder 'Select one ONT POD5 folder'
    if (-not $folder) { return }
    [void](Add-SampleFileRow @{ sample_id = (Get-SafeSampleId $folder); pod5_dir = $folder })
    if ($script:methodCombos.ContainsKey('long_basecalling')) { Set-MethodValue 'long_basecalling' 'dorado_sup' }
    Show-Info 'The POD5 folder was added and Dorado SUP was selected. Choose Oxford Nanopore cDNA or Oxford Nanopore direct RNA in the Long-read platform column, and verify the chemistry-matched Dorado model.'
}

$addPaired.Add_Click({ Add-PairedShortReadFiles })
$addSingle.Add_Click({ Add-SingleShortReadFiles })
$scanFastq.Add_Click({ Scan-ShortFastqFolder })
$addLongReads.Add_Click({ Add-LongReadFiles })
$addPod5.Add_Click({ Add-Pod5Folder })

$applyCondition.Add_Click({
    $condition = Get-ActiveCondition
    $rows = @(Get-SelectedSampleRows)
    if ($rows.Count -eq 0) { Show-Info 'Select one or more sample-table cells first.'; return }
    foreach ($row in $rows) {
        $row.Cells['condition'].Value = $condition
        if ([string]::IsNullOrWhiteSpace([string]$row.Cells['replicate'].Value)) {
            $row.Cells['replicate'].Value = (Get-NextReplicateNumber $condition).ToString()
        }
    }
    Update-ConditionDesignSummary
    Update-Review
})
$addBlankReplicate.Add_Click({
    $condition = Get-ActiveCondition
    $index = Get-AvailableSampleRowIndex
    $row = $sampleGrid.Rows[$index]
    $nextReplicate = Get-NextReplicateNumber $condition
    $row.Cells['include'].Value = $true
    $row.Cells['condition'].Value = $condition
    $row.Cells['replicate'].Value = $nextReplicate.ToString()
    $sampleGrid.CurrentCell = $row.Cells['sample_id']
    $sampleGrid.BeginEdit($true)
    Update-ConditionDesignSummary
})
$removeRow.Add_Click({ if ($sampleGrid.CurrentRow -and -not $sampleGrid.CurrentRow.IsNewRow) { $sampleGrid.Rows.Remove($sampleGrid.CurrentRow) } })
$clearSamples.Add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show('Remove every sample row from this project?', 'Bacterial RNA Analysis', 'YesNo', 'Question')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $sampleGrid.Rows.Clear()
    $index = $sampleGrid.Rows.Add()
    $sampleGrid.Rows[$index].Cells['include'].Value = $true
    $sampleGrid.Rows[$index].Cells['replicate'].Value = '1'
    Update-ConditionDesignSummary
})

function Browse-SelectedSampleCell {
    if (-not $sampleGrid.CurrentCell -or $sampleGrid.CurrentRow.IsNewRow) { return }
    $name = $sampleGrid.Columns[$sampleGrid.CurrentCell.ColumnIndex].Name
    $value = ''
    if ($name -in @('short_r1','short_r2')) { $value = Select-File 'FASTQ (*.fastq;*.fq;*.gz)|*.fastq;*.fq;*.fastq.gz;*.fq.gz|All files (*.*)|*.*' }
    elseif ($name -eq 'long_reads') { $value = Select-File 'Long reads (*.fastq;*.fq;*.bam;*.gz)|*.fastq;*.fq;*.fastq.gz;*.fq.gz;*.bam|All files (*.*)|*.*' }
    elseif ($name -eq 'pod5_dir') { $value = Select-Folder 'Select a folder containing POD5 files' }
    else { Show-Info 'Select a Short R1, Short R2, Long reads, or POD5 cell first.'; return }
    if ($value) {
        $sampleGrid.CurrentCell.Value = $value
        if ($name -eq 'pod5_dir' -and $script:methodCombos.ContainsKey('long_basecalling')) { Set-MethodValue 'long_basecalling' 'dorado_sup' }
    }
}

$sampleGrid.Add_CellDoubleClick({
    param($sender, $eventArgs)
    if ($eventArgs.RowIndex -lt 0 -or $eventArgs.ColumnIndex -lt 0) { return }
    $columnName = $sender.Columns[$eventArgs.ColumnIndex].Name
    if ($columnName -notin @('short_r1','short_r2','long_reads','pod5_dir')) { return }
    $sender.CurrentCell = $sender.Rows[$eventArgs.RowIndex].Cells[$eventArgs.ColumnIndex]
    Browse-SelectedSampleCell
})

$sampleGrid.Add_CurrentCellDirtyStateChanged({
    if ($sampleGrid.IsCurrentCellDirty) { [void]$sampleGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
})
$sampleGrid.Add_CellValueChanged({
    param($sender, $eventArgs)
    if ($eventArgs.RowIndex -lt 0 -or $eventArgs.ColumnIndex -lt 0) { return }
    $name = $sender.Columns[$eventArgs.ColumnIndex].Name
    if ($name -in @('include','sample_id','condition','replicate')) { Update-ConditionDesignSummary }
})
$sampleGrid.Add_RowsAdded({ Update-ConditionDesignSummary })
$sampleGrid.Add_RowsRemoved({ Update-ConditionDesignSummary })
$conditionSelector.Add_SelectedIndexChanged({ Update-ConditionDesignSummary })

$importSheet.Add_Click({
    $path = Select-File 'Sample sheet (*.csv;*.tsv)|*.csv;*.tsv|All files (*.*)|*.*'
    if (-not $path) { return }
    try {
        $delimiter = ','
        if ([System.IO.Path]::GetExtension($path) -ieq '.tsv') { $delimiter = "`t" }
        $rows = Import-Csv -LiteralPath $path -Delimiter $delimiter
        $sampleGrid.Rows.Clear()
        foreach ($item in $rows) {
            $index = $sampleGrid.Rows.Add()
            foreach ($column in $sampleGrid.Columns) {
                $name = $column.Name
                if ($name -eq 'include') {
                    $raw = [string]$item.$name
                    $sampleGrid.Rows[$index].Cells[$name].Value = ($raw -notmatch '^(?i:false|no|0)$')
                }
                elseif ($null -ne $item.$name) {
                    $cellValue = [string]$item.$name
                    if ($name -eq 'long_platform') { $cellValue = Convert-ToLongPlatformCode $cellValue }
                    $sampleGrid.Rows[$index].Cells[$name].Value = $cellValue
                }
            }
        }
    }
    catch { Show-Error ("Could not import sample sheet.`r`n`r`n" + $_.Exception.Message) }
})

$exportSheet.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'CSV (*.csv)|*.csv'
    $dialog.FileName = 'samples_template.csv'
    if ($dialog.ShowDialog() -ne 'OK') { return }
    'include,sample_id,condition,replicate,batch,short_r1,short_r2,long_reads,pod5_dir,long_platform' | Set-Content -LiteralPath $dialog.FileName -Encoding UTF8
    Show-Info 'Sample template exported.'
})

# Page 3: methods and explanations
$methodsLayout = New-Object System.Windows.Forms.TableLayoutPanel
$methodsLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$methodsLayout.ColumnCount = 2
$methodsLayout.RowCount = 1
$methodsLayout.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 10)
[void]$methodsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 47)))
[void]$methodsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 53)))
[void]$methodsLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$pageMethods.Controls.Add($methodsLayout)

$methodLeft = New-Object System.Windows.Forms.Panel
$methodLeft.Dock = [System.Windows.Forms.DockStyle]::Fill
$methodLeft.Margin = New-Object System.Windows.Forms.Padding(4, 2, 8, 2)
$methodLeft.BackColor = $surface
$methodLeft.AutoScroll = $false
$methodsLayout.Controls.Add($methodLeft, 0, 0)

$methodRight = New-Object System.Windows.Forms.Panel
$methodRight.Dock = [System.Windows.Forms.DockStyle]::Fill
$methodRight.Margin = New-Object System.Windows.Forms.Padding(8, 2, 4, 2)
$methodRight.BackColor = $surface
$methodsLayout.Controls.Add($methodRight, 1, 0)

$methodRightLayout = New-Object System.Windows.Forms.TableLayoutPanel
$methodRightLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$methodRightLayout.ColumnCount = 1
$methodRightLayout.RowCount = 3
$methodRightLayout.Padding = New-Object System.Windows.Forms.Padding(16, 14, 16, 14)
[void]$methodRightLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$methodRightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32)))
[void]$methodRightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 67)))
[void]$methodRightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$methodRight.Controls.Add($methodRightLayout)
$methodTitleLabel = New-TableLabel 'Method definition and trade-offs'
$methodTitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]12.5, [System.Drawing.FontStyle]::Bold)
$methodTitleLabel.ForeColor = $greenDark
$methodRightLayout.Controls.Add($methodTitleLabel, 0, 0)
$methodContext = New-Object System.Windows.Forms.Label
$methodContext.Dock = [System.Windows.Forms.DockStyle]::Fill
$methodContext.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 8)
$methodContext.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 6)
$methodContext.BackColor = $blueSoft
$methodContext.ForeColor = $ink
$methodContext.AutoEllipsis = $true
$methodContext.Text = 'Select or focus a method on the left.'
$methodContext.Font = New-Object System.Drawing.Font('Segoe UI', [single]9.5, [System.Drawing.FontStyle]::Bold)
$methodRightLayout.Controls.Add($methodContext, 0, 1)
$methodDetailsGrid = New-Object System.Windows.Forms.TableLayoutPanel
$methodDetailsGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$methodDetailsGrid.Margin = New-Object System.Windows.Forms.Padding(0)
$methodDetailsGrid.ColumnCount = 1
$methodDetailsGrid.RowCount = 5
$methodDetailsGrid.BackColor = $surface
[void]$methodDetailsGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$methodDetailsGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 104)))
[void]$methodDetailsGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 86)))
[void]$methodDetailsGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 72)))
[void]$methodDetailsGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 66)))
[void]$methodDetailsGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$methodRightLayout.Controls.Add($methodDetailsGrid, 0, 2)

function New-MethodParagraphSection([string]$Heading) {
    $section = New-Object System.Windows.Forms.Panel
    $section.Dock = [System.Windows.Forms.DockStyle]::Fill
    $section.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 3)
    $section.BackColor = $surface
    $headingLabel = New-Object System.Windows.Forms.Label
    $headingLabel.Text = $Heading
    $headingLabel.Dock = [System.Windows.Forms.DockStyle]::Top
    $headingLabel.Height = 31
    $headingLabel.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 2)
    $headingLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]11.25, [System.Drawing.FontStyle]::Bold)
    $headingLabel.ForeColor = $greenDark
    $headingLabel.BackColor = $surface
    $bodyLabel = New-Object System.Windows.Forms.Label
    $bodyLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bodyLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 4, 4)
    $bodyLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]9.6)
    $bodyLabel.ForeColor = $ink
    $bodyLabel.BackColor = $surface
    $bodyLabel.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    $bodyLabel.UseCompatibleTextRendering = $false
    $section.Controls.Add($bodyLabel)
    $section.Controls.Add($headingLabel)
    $section.Tag = [pscustomobject]@{ heading = $headingLabel; body = $bodyLabel }
    return $section
}

function New-MethodTradeoffCard([string]$Heading) {
    $card = New-Object System.Windows.Forms.Panel
    $card.Dock = [System.Windows.Forms.DockStyle]::Fill
    $card.Margin = New-Object System.Windows.Forms.Padding(4)
    $card.BackColor = $surface
    $card.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $headingLabel = New-Object System.Windows.Forms.Label
    $headingLabel.Text = $Heading
    $headingLabel.Dock = [System.Windows.Forms.DockStyle]::Top
    $headingLabel.Height = 35
    $headingLabel.Padding = New-Object System.Windows.Forms.Padding(10, 7, 8, 4)
    $headingLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]11.25, [System.Drawing.FontStyle]::Bold)
    $headingLabel.ForeColor = $greenDark
    $headingLabel.BackColor = $surface
    $bodyLabel = New-Object System.Windows.Forms.Label
    $bodyLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bodyLabel.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
    $bodyLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single]9.5)
    $bodyLabel.ForeColor = $ink
    $bodyLabel.BackColor = $surface
    $bodyLabel.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    $bodyLabel.UseCompatibleTextRendering = $false
    $card.Controls.Add($bodyLabel)
    $card.Controls.Add($headingLabel)
    $card.Tag = [pscustomobject]@{ heading = $headingLabel; body = $bodyLabel }
    return $card
}

$methodDefinitionCard = New-MethodParagraphSection 'Definition'
$methodUseCard = New-MethodParagraphSection 'When to use'
$methodAiCard = New-MethodParagraphSection 'Uses AI or machine learning'
$methodCommandsCard = New-MethodParagraphSection 'Required commands'
$methodTradeoffGrid = New-Object System.Windows.Forms.TableLayoutPanel
$methodTradeoffGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$methodTradeoffGrid.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$methodTradeoffGrid.ColumnCount = 2
$methodTradeoffGrid.RowCount = 1
$methodTradeoffGrid.BackColor = $background
[void]$methodTradeoffGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$methodTradeoffGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$methodTradeoffGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$methodAdvantagesCard = New-MethodTradeoffCard 'Advantages'
$methodLimitationsCard = New-MethodTradeoffCard 'Limitations'
$methodTradeoffGrid.Controls.Add($methodAdvantagesCard, 0, 0)
$methodTradeoffGrid.Controls.Add($methodLimitationsCard, 1, 0)
$methodDetailsGrid.Controls.Add($methodDefinitionCard, 0, 0)
$methodDetailsGrid.Controls.Add($methodUseCard, 0, 1)
$methodDetailsGrid.Controls.Add($methodAiCard, 0, 2)
$methodDetailsGrid.Controls.Add($methodCommandsCard, 0, 3)
$methodDetailsGrid.Controls.Add($methodTradeoffGrid, 0, 4)

$script:methodCombos = @{}
$script:methodRows = @{}
$script:methodOptions = @{}
$stageOrder = @('short_qc','short_alignment','long_basecalling','long_qc','long_alignment','quantification','coverage')
$readStageOrder = @('short_qc','short_alignment','long_basecalling','long_qc','long_alignment')
$sharedStageOrder = @('quantification','coverage')

$methodSessionHeading = New-Label 'READ PROCESSING AND ANALYSIS-READY EXPORT' 18 8 680 22 -Bold
$methodSessionHeading.ForeColor = $greenDark
$methodSessionHint = New-Label 'Choose processing, counting, and coverage settings in one continuous workflow.' 18 31 650 34
$methodSessionHint.ForeColor = $muted
$methodSessionHint.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$advancedToolOptionsButton = New-Button 'Guided tool options...' 480 34 205 30
$advancedToolOptionsButton.Font = New-Object System.Drawing.Font('Segoe UI', [single]9.3, [System.Drawing.FontStyle]::Bold)
$methodLeft.Controls.AddRange(@($methodSessionHeading, $methodSessionHint, $advancedToolOptionsButton))

# Section headings remain in the same continuous page; they are not separate
# cards, panels, tabs, or columns.
$readMethodsTitle = New-Label 'Read-processing methods' 18 62 500 24 -Bold
$readMethodsTitle.ForeColor = $greenDark
$readMethodsTitle.Font = New-Object System.Drawing.Font('Segoe UI', [single]11.25, [System.Drawing.FontStyle]::Bold)
$sharedExportTitle = New-Label 'Analysis-ready export' 18 430 500 24 -Bold
$sharedExportTitle.ForeColor = $greenDark
$sharedExportTitle.Font = New-Object System.Drawing.Font('Segoe UI', [single]11.25, [System.Drawing.FontStyle]::Bold)
$sharedExportTitle.Visible = $false
$methodLeft.Controls.AddRange(@($readMethodsTitle, $sharedExportTitle))

$y = 116
foreach ($stageName in $stageOrder) {
    $stage = $script:Catalog.stages.$stageName
    $label = New-Label ([string]$stage.label) 18 $y 350 20 -Bold
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Location = New-Object System.Drawing.Point(18, ($y + 22))
    $combo.Size = New-Object System.Drawing.Size(350, 27)
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $combo.DropDownWidth = 620
    $combo.Tag = $stageName
    $options = @($stage.options)
    foreach ($catalogOption in $options) { [void]$combo.Items.Add([string]$catalogOption.name) }
    $combo.Add_SelectedIndexChanged({ param($sender, $eventArgs) Update-MethodExplanation ([string]$sender.Tag) })
    $combo.Add_Enter({ param($sender, $eventArgs) Update-MethodExplanation ([string]$sender.Tag) })
    $combo.Add_DropDown({ param($sender, $eventArgs) Update-MethodExplanation ([string]$sender.Tag) })
    $methodLeft.Controls.AddRange(@($label, $combo))
    $script:methodCombos[$stageName] = $combo
    $script:methodRows[$stageName] = @($label, $combo)
    $script:methodOptions[$stageName] = $options
}

$shortStrandLabel = New-Label 'Short-read strand' 18 460 145 22 -Bold
$strandCombo = New-Object System.Windows.Forms.ComboBox
$strandCombo.Location = New-Object System.Drawing.Point(170, 458)
$strandCombo.Size = New-Object System.Drawing.Size(180, 26)
$strandCombo.DropDownStyle = 'DropDownList'
$strandCombo.Items.AddRange(@('auto','reverse','forward','unstranded'))
$strandCombo.SelectedItem = 'reverse'
$methodLeft.Controls.AddRange(@($shortStrandLabel, $strandCombo))

$longStrandLabel = New-Label 'Long-read strand' 18 492 145 22 -Bold
$longStrandCombo = New-Object System.Windows.Forms.ComboBox
$longStrandCombo.Location = New-Object System.Drawing.Point(170, 490)
$longStrandCombo.Size = New-Object System.Drawing.Size(180, 26)
$longStrandCombo.DropDownStyle = 'DropDownList'
$longStrandCombo.Items.AddRange(@('auto','forward','reverse','unstranded'))
$longStrandCombo.SelectedItem = 'auto'
$methodLeft.Controls.AddRange(@($longStrandLabel, $longStrandCombo))

$strandHelp = New-Label 'Short-read and long-read strand orientation are evaluated independently.' 18 524 350 38
$strandHelp.ForeColor = $muted
$methodLeft.Controls.Add($strandHelp)

$strictStrand = New-Object System.Windows.Forms.CheckBox
$strictStrand.Text = 'Stop if declared and inferred strand disagree'
$strictStrand.Location = New-Object System.Drawing.Point(390, 280)
$strictStrand.Size = New-Object System.Drawing.Size(330, 25)
$strictStrand.Checked = $true
$methodLeft.Controls.Add($strictStrand)

$filterLong = New-Object System.Windows.Forms.CheckBox
$filterLong.Text = 'Filter long reads by Q score and length'
$filterLong.Location = New-Object System.Drawing.Point(18, 566)
$filterLong.Size = New-Object System.Drawing.Size(330, 25)
$filterLong.Checked = $false
$methodLeft.Controls.Add($filterLong)

$adapterR1Label = New-Label 'Cutadapt R1 adapter' 18 598 145
$adapterR1 = New-TextBox 170 596 210
$methodLeft.Controls.AddRange(@($adapterR1Label, $adapterR1))
$adapterR2Label = New-Label 'Cutadapt R2 adapter' 18 628 145
$adapterR2 = New-TextBox 170 626 210
$methodLeft.Controls.AddRange(@($adapterR2Label, $adapterR2))
$doradoModelLabel = New-Label 'Dorado model' 18 598 145
$doradoModel = New-TextBox 170 596 210
$doradoModel.Text = 'sup'
$methodLeft.Controls.AddRange(@($doradoModelLabel, $doradoModel))
$doradoPathLabel = New-Label 'Dorado executable' 18 628 145
$doradoPath = New-TextBox 170 626 150
$doradoPath.Text = 'dorado'
$browseDorado = New-Button 'Browse' 326 623 58 28
$methodLeft.Controls.AddRange(@($doradoPathLabel, $doradoPath, $browseDorado))
$browseDorado.Add_Click({ $value = Select-File 'Dorado executable (dorado;dorado.exe)|dorado;dorado.exe|All files (*.*)|*.*'; if ($value) { $doradoPath.Text = $value } })

$script:methodOptionalControls = @(
    $shortStrandLabel, $strandCombo, $longStrandLabel, $longStrandCombo, $strandHelp,
    $strictStrand, $filterLong, $adapterR1Label, $adapterR1, $adapterR2Label, $adapterR2,
    $doradoModelLabel, $doradoModel, $doradoPathLabel, $doradoPath, $browseDorado
)

$script:Bowtie2Preset = 'sensitive'
$script:Bowtie2Mode = 'end-to-end'

$script:ToolOptionCatalogPath = Join-Path $script:AppRoot 'tool_option_catalog.json'
if (-not (Test-Path -LiteralPath $script:ToolOptionCatalogPath -PathType Leaf)) {
    throw "The discoverable tool-option catalog is missing: $($script:ToolOptionCatalogPath)"
}
$script:ToolOptionCatalogDocument = Get-Content -LiteralPath $script:ToolOptionCatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:ToolOptionCatalog = @($script:ToolOptionCatalogDocument.tools)
if ($script:ToolOptionCatalog.Count -eq 0) { throw 'The discoverable tool-option catalog contains no tools.' }
$script:ToolArgumentDefinitions = @(
    foreach ($toolDefinition in $script:ToolOptionCatalog) {
        [pscustomobject]@{ Key = [string]$toolDefinition.key; Label = [string]$toolDefinition.label }
    }
)
$script:AdvancedToolArguments = [ordered]@{}
foreach ($definition in $script:ToolArgumentDefinitions) { $script:AdvancedToolArguments[[string]$definition.Key] = '' }
$script:AdvancedToolOptionValues = @{}

function Copy-ToolSelectionMap([object]$Source) {
    $copy = @{}
    if ($null -eq $Source) { return $copy }
    $sourceKeys = if ($Source -is [System.Collections.IDictionary]) { @($Source.Keys) } else { @($Source.PSObject.Properties.Name) }
    foreach ($toolKeyValue in $sourceKeys) {
        $toolKey = [string]$toolKeyValue
        $sourceValues = if ($Source -is [System.Collections.IDictionary]) { $Source[$toolKeyValue] } else { $Source.PSObject.Properties[$toolKey].Value }
        $inner = @{}
        if ($null -ne $sourceValues) {
            $innerKeys = if ($sourceValues -is [System.Collections.IDictionary]) { @($sourceValues.Keys) } else { @($sourceValues.PSObject.Properties.Name) }
            foreach ($optionKeyValue in $innerKeys) {
                $optionKey = [string]$optionKeyValue
                $inner[$optionKey] = if ($sourceValues -is [System.Collections.IDictionary]) { $sourceValues[$optionKeyValue] } else { $sourceValues.PSObject.Properties[$optionKey].Value }
            }
        }
        $copy[$toolKey] = $inner
    }
    return $copy
}

function ConvertTo-ToolOptionDisplayValue([object]$Value) {
    if ($Value -is [single] -or $Value -is [double]) { return ([double]$Value).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [decimal]) { return ([decimal]$Value).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    return [string]$Value
}

function ConvertTo-ToolArgumentToken([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value -match '^[A-Za-z0-9_@%+=:,./-]+$') { return $Value }
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Convert-ToolSelectionsToArgumentString([string]$ToolKey, [object]$SelectionMap) {
    if ($null -eq $SelectionMap -or -not $SelectionMap.ContainsKey($ToolKey)) { return '' }
    $toolMatches = @($script:ToolOptionCatalog | Where-Object { [string]$_.key -eq $ToolKey } | Select-Object -First 1)
    if ($toolMatches.Count -eq 0) { return '' }
    $selected = $SelectionMap[$ToolKey]
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($option in @($toolMatches[0].options)) {
        $optionId = [string]$option.id
        if (-not $selected.ContainsKey($optionId)) { continue }
        $type = [string]$option.type
        $flag = [string]$option.flag
        $value = $selected[$optionId]
        if ($type -eq 'boolean') {
            if ([bool]$value -and $flag) { [void]$tokens.Add((ConvertTo-ToolArgumentToken $flag)) }
            continue
        }
        $textValue = [string]$value
        if ($type -eq 'pipeline_setting') { continue }
        if ($type -eq 'choice_flag') {
            if ($textValue -and $textValue -ne 'default') { [void]$tokens.Add((ConvertTo-ToolArgumentToken $textValue)) }
            continue
        }
        if ($type -eq 'key_value') {
            if ($textValue) { [void]$tokens.Add((ConvertTo-ToolArgumentToken "$flag=$textValue")) }
            continue
        }
        if ($flag) { [void]$tokens.Add((ConvertTo-ToolArgumentToken $flag)) }
        [void]$tokens.Add((ConvertTo-ToolArgumentToken $textValue))
    }
    return ($tokens -join ' ')
}

function Get-EffectiveToolArgumentString([string]$ToolKey) {
    $parts = New-Object System.Collections.Generic.List[string]
    $structured = Convert-ToolSelectionsToArgumentString $ToolKey $script:AdvancedToolOptionValues
    if (-not [string]::IsNullOrWhiteSpace($structured)) { [void]$parts.Add($structured.Trim()) }
    # Free-form command arguments are intentionally not exposed. Only documented
    # guided options can alter tool invocation.
    return ($parts -join ' ')
}


function Format-ToolCommandPreview([string]$Template, [string]$GuidedArguments) {
    $guided = if ([string]::IsNullOrWhiteSpace($GuidedArguments)) { '' } else { $GuidedArguments.Trim() }
    $result = $Template.Replace('{GUIDED}', $guided)
    # Keep line breaks and shell punctuation intact while removing spacing left by
    # an empty guided-argument slot.
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($result -split "`r?`n")) {
        [void]$lines.Add($line.TrimEnd())
    }
    return ($lines -join "`r`n").Trim()
}

function Get-ToolCommandPreview([string]$ToolKey, [object]$SelectionMap) {
    $guided = Convert-ToolSelectionsToArgumentString $ToolKey $SelectionMap
    $sortGuided = Convert-ToolSelectionsToArgumentString 'samtools_sort' $SelectionMap
    $template = ''

    switch ($ToolKey) {
        'fastqc' {
            $template = 'fastqc --threads <threads> --outdir <qc_output_dir> {GUIDED} <input.fastq.gz> [<mate2.fastq.gz>]'
        }
        'fastp' {
            $template = 'fastp --thread <threads> --in1 <R1.fastq.gz> --out1 <clean_R1.fastq.gz> --qualified_quality_phred <quality> --unqualified_percent_limit <percent> --cut_front --cut_tail --cut_window_size 4 --cut_mean_quality <quality> --length_required <min_length> --json <report.json> --html <report.html> [--in2 <R2.fastq.gz> --out2 <clean_R2.fastq.gz> --detect_adapter_for_pe] {GUIDED}'
        }
        'cutadapt' {
            $template = 'cutadapt --cores <threads> -q 20,20 --minimum-length <min_length> -a <adapter_R1> -o <clean_R1.fastq.gz> [-A <adapter_R2> -p <clean_R2.fastq.gz>] {GUIDED} <R1.fastq.gz> [<R2.fastq.gz>]'
        }
        'multiqc' {
            $template = 'multiqc <run_directory> --outdir <multiqc_output_dir> --force --filename multiqc_report.html {GUIDED}'
        }
        'bowtie2_build' {
            $template = 'bowtie2-build --threads <threads> {GUIDED} <reference.fasta> <index_prefix>'
        }
        'bowtie2' {
            $preset = [string]$SelectionMap['bowtie2']['preset']
            $mode = [string]$SelectionMap['bowtie2']['mode']
            if ([string]::IsNullOrWhiteSpace($preset)) { $preset = 'sensitive' }
            if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'end-to-end' }
            $presetFlag = if ($preset -eq 'default') { '' } else { "--$preset" }
            $sortPart = if ([string]::IsNullOrWhiteSpace($sortGuided)) { '' } else { ' ' + $sortGuided.Trim() }
            $template = "bowtie2 --$mode $presetFlag --threads <threads> --rg-id <run_id> --rg SM:<sample_id> --rg LB:<sample_id> --rg PL:ILLUMINA --rg PU:<run_id> -x <index_prefix> {GUIDED} [-1 <R1.fastq.gz> -2 <R2.fastq.gz> | -U <R1.fastq.gz>] | samtools sort$sortPart -@ <threads> -o <output.bam> -"
        }
        'bwa_mem2_index' {
            $template = 'bwa-mem2 index {GUIDED} <reference.fasta>'
        }
        'bwa_mem2' {
            $sortPart = if ([string]::IsNullOrWhiteSpace($sortGuided)) { '' } else { ' ' + $sortGuided.Trim() }
            $template = "bwa-mem2 mem -t <threads> -Y -R <read_group> {GUIDED} <reference.fasta> <R1.fastq.gz> [<R2.fastq.gz>] | samtools sort$sortPart -@ <threads> -o <output.bam> -"
        }
        'hisat2_build' {
            $template = 'hisat2-build -p <threads> {GUIDED} <reference.fasta> <index_prefix>'
        }
        'hisat2' {
            $sortPart = if ([string]::IsNullOrWhiteSpace($sortGuided)) { '' } else { ' ' + $sortGuided.Trim() }
            $template = "hisat2 --no-spliced-alignment --no-softclip -p <threads> --rg-id <run_id> --rg SM:<sample_id> -x <index_prefix> {GUIDED} [-1 <R1.fastq.gz> -2 <R2.fastq.gz> | -U <R1.fastq.gz>] | samtools sort$sortPart -@ <threads> -o <output.bam> -"
        }
        'samtools_faidx' {
            $template = 'samtools faidx {GUIDED} <reference.fasta>'
        }
        'samtools_sort' {
            $template = 'samtools sort {GUIDED} -@ <threads> -o <output.bam> <input.sam_or_bam>'
        }
        'samtools_merge' {
            $template = 'samtools merge -f -@ <threads> {GUIDED} <merged.bam> <input1.bam> <input2.bam> [...]'
        }
        'samtools_index' {
            $template = 'samtools index -@ <threads> {GUIDED} <input.bam>'
        }
        'samtools_fastq' {
            $template = 'samtools fastq {GUIDED} -@ <threads> <input.bam> | pigz -p <threads> > <output.fastq.gz>'
        }
        'samtools_quickcheck' {
            $template = 'samtools quickcheck -v {GUIDED} <input.bam>'
        }
        'samtools_flagstat' {
            $template = 'samtools flagstat -@ <threads> {GUIDED} <input.bam> > <flagstat.txt>'
        }
        'samtools_stats' {
            $template = 'samtools stats -@ <threads> {GUIDED} <input.bam> > <samtools_stats.txt>'
        }
        'samtools_idxstats' {
            $template = 'samtools idxstats {GUIDED} <input.bam> > <idxstats.tsv>'
        }
        'dorado' {
            $template = 'dorado basecaller <model> {GUIDED} <pod5_directory> > <basecalls.bam>'
        }
        'chopper' {
            $template = '<FASTQ_stream> | chopper --quality <min_quality> --minlength <min_length> --threads <threads> {GUIDED} | pigz -p <threads> > <filtered.fastq.gz>'
        }
        'pigz' {
            $template = '<input_stream> | pigz {GUIDED} -p <threads> > <output.fastq.gz>'
        }
        'nanoplot' {
            $template = 'NanoPlot --fastq <reads.fastq.gz> --threads <threads> --outdir <qc_directory> {GUIDED}'
        }
        'longqc' {
            $template = 'python <LongQC/longQC.py> sampleqc -x <platform_preset> -t -p <threads> -o <qc_directory> {GUIDED} <reads.fastq.gz>'
        }
        'minimap2' {
            $sortPart = if ([string]::IsNullOrWhiteSpace($sortGuided)) { '' } else { ' ' + $sortGuided.Trim() }
            $template = "minimap2 -a -x <platform_preset> --secondary=yes -t <threads> -R <read_group> {GUIDED} <reference.fasta> <reads.fastq.gz> | samtools sort$sortPart -@ <threads> -o <output.bam> -"
        }
        'winnowmap' {
            $sortPart = if ([string]::IsNullOrWhiteSpace($sortGuided)) { '' } else { ' ' + $sortGuided.Trim() }
            $template = "winnowmap -W <repetitive_kmers.txt> -a -x <platform_preset> -t <threads> -R <read_group> {GUIDED} <reference.fasta> <reads.fastq.gz> | samtools sort$sortPart -@ <threads> -o <output.bam> -"
        }
        'meryl_count' {
            $template = 'meryl k=15 count {GUIDED} output <reference.meryl> <reference.fasta>'
        }
        'meryl_print' {
            $template = 'meryl print greater-than distinct=0.9998 {GUIDED} <reference.meryl> > <repetitive_kmers.txt>'
        }
        'featurecounts' {
            $template = 'featureCounts -T <threads> -F SAF -a <features.saf> -o <counts.tsv> -s <strand_code> -Q <MAPQ> --primary [-p --countReadPairs -B -C] [-L] {GUIDED} <input.bam>'
        }
        'htseq_count' {
            $template = 'htseq-count --format=bam --order=pos --stranded=<yes|no|reverse> --type=gene --idattr=ID --nonunique=none {GUIDED} <input.bam> <annotation.gff3> > <counts.tsv>'
        }
        'fadu' {
            $template = 'julia <FADU/fadu.jl> -g <annotation.gff3> -b <input.bam> -o <output_directory> -s <strand> -f gene -a ID [-p] {GUIDED}'
        }
        'bamcoverage' {
            $template = 'bamCoverage -b <input.bam> --outFileName <coverage.bw> --outFileFormat bigwig --binSize 1 --numberOfProcessors <threads> --minMappingQuality <MAPQ> --samFlagExclude <flags> --normalizeUsing <None|CPM> --exactScaling [--filterRNAstrand <forward|reverse>] [--samFlagInclude <flags>] {GUIDED}'
        }
        default {
            $template = '<tool> <pipeline-managed arguments> {GUIDED}'
        }
    }

    $command = Format-ToolCommandPreview $template $guided

    # Fill values already known in the GUI. Sample-specific and generated paths stay
    # as <...> placeholders because one analysis can submit a different command for
    # every sample/run while using the same guided option set.
    try { $command = $command.Replace('<threads>', ([string][int]$threadsBox.Value)) } catch { }
    try { $command = $command.Replace('<MAPQ>', ([string][int]$mapqBox.Value)) } catch { }
    try {
        $referenceValue = [string]$referenceFasta.Text
        if (-not [string]::IsNullOrWhiteSpace($referenceValue)) {
            $command = $command.Replace('<reference.fasta>', (ConvertTo-ToolArgumentToken $referenceValue.Trim()))
        }
    } catch { }
    try {
        $adapterValue = [string]$adapterR1.Text
        if (-not [string]::IsNullOrWhiteSpace($adapterValue)) { $command = $command.Replace('<adapter_R1>', (ConvertTo-ToolArgumentToken $adapterValue.Trim())) }
        $adapterValue2 = [string]$adapterR2.Text
        if (-not [string]::IsNullOrWhiteSpace($adapterValue2)) { $command = $command.Replace('<adapter_R2>', (ConvertTo-ToolArgumentToken $adapterValue2.Trim())) }
    } catch { }
    try {
        $modelValue = [string]$doradoModel.Text
        if (-not [string]::IsNullOrWhiteSpace($modelValue)) { $command = $command.Replace('<model>', (ConvertTo-ToolArgumentToken $modelValue.Trim())) }
    } catch { }
    $command = $command.Replace('<quality>', '20').Replace('<percent>', '40')
    if ($ToolKey -in @('fastp','cutadapt')) { $command = $command.Replace('<min_length>', '30') }
    if ($ToolKey -eq 'chopper') { $command = $command.Replace('<min_quality>', '10').Replace('<min_length>', '200') }

    $header = '# Effective command preview' + "`r`n" + '# Selected options are exact; sample-specific/generated paths remain as <...> until the run starts.'
    return $header + "`r`n" + $command
}

function Test-ToolOptionSelection([object]$Tool, [object]$Selections, [ref]$Message) {
    foreach ($option in @($Tool.options)) {
        $optionId = [string]$option.id
        if (-not $Selections.ContainsKey($optionId)) { continue }
        $raw = [string]$Selections[$optionId]
        $type = [string]$option.type
        if ($type -in @('boolean','choice_flag','pipeline_setting')) {
            if ($type -in @('choice_flag','pipeline_setting') -and @($option.choices) -notcontains $raw) {
                $Message.Value = "$($Tool.label) / $($option.label): choose one of the listed values."
                return $false
            }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $Message.Value = "$($Tool.label) / $($option.label): enter a value or clear the Use checkbox."
            return $false
        }
        if ($type -eq 'choice' -and @($option.choices) -notcontains $raw) {
            $Message.Value = "$($Tool.label) / $($option.label): choose one of the listed values."
            return $false
        }
        if ($type -eq 'integer') {
            $parsedInteger = 0L
            if (-not [long]::TryParse($raw, [ref]$parsedInteger)) {
                $Message.Value = "$($Tool.label) / $($option.label): enter a whole number."
                return $false
            }
            $minimumProperty = $option.PSObject.Properties['minimum']
            $maximumProperty = $option.PSObject.Properties['maximum']
            if ($null -ne $minimumProperty -and $parsedInteger -lt [long]$minimumProperty.Value) {
                $Message.Value = "$($Tool.label) / $($option.label): minimum value is $($minimumProperty.Value)."
                return $false
            }
            if ($null -ne $maximumProperty -and $parsedInteger -gt [long]$maximumProperty.Value) {
                $Message.Value = "$($Tool.label) / $($option.label): maximum value is $($maximumProperty.Value)."
                return $false
            }
        }
        if ($type -eq 'number') {
            $parsedNumber = 0.0
            $numberStyle = [System.Globalization.NumberStyles]::Float
            $culture = [System.Globalization.CultureInfo]::InvariantCulture
            if (-not [double]::TryParse($raw, $numberStyle, $culture, [ref]$parsedNumber)) {
                $Message.Value = "$($Tool.label) / $($option.label): enter a number using a decimal point."
                return $false
            }
            $minimumProperty = $option.PSObject.Properties['minimum']
            $maximumProperty = $option.PSObject.Properties['maximum']
            if ($null -ne $minimumProperty -and $parsedNumber -lt [double]$minimumProperty.Value) {
                $Message.Value = "$($Tool.label) / $($option.label): minimum value is $($minimumProperty.Value)."
                return $false
            }
            if ($null -ne $maximumProperty -and $parsedNumber -gt [double]$maximumProperty.Value) {
                $Message.Value = "$($Tool.label) / $($option.label): maximum value is $($maximumProperty.Value)."
                return $false
            }
        }
    }
    return $true
}

function Show-AdvancedToolOptions {
    $workingSelections = Copy-ToolSelectionMap $script:AdvancedToolOptionValues
    foreach ($definition in $script:ToolArgumentDefinitions) {
        $key = [string]$definition.Key
        if (-not $workingSelections.ContainsKey($key)) { $workingSelections[$key] = @{} }
    }
    # Bowtie2 preset and alignment mode are first-class guided settings inside
    # the Bowtie2 alignment page rather than separate controls above the tool list.
    if (-not $workingSelections.ContainsKey('bowtie2')) { $workingSelections['bowtie2'] = @{} }
    $workingSelections['bowtie2']['preset'] = $script:Bowtie2Preset
    $workingSelections['bowtie2']['mode'] = $script:Bowtie2Mode

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Guided tool options'
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.ClientSize = New-Object System.Drawing.Size(1180, 760)
    $dialog.MinimumSize = New-Object System.Drawing.Size(980, 660)
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dialog.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $dialog.BackColor = $background
    $dialog.Tag = [pscustomobject]@{ Loading = $false }

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = 'Choose a tool on the left. Check Use beside a documented option, then choose or enter its value. The panel explains what the pipeline already controls. Only listed, validated options can change a command.'
    $intro.SetBounds(16, 12, 930, 45)
    $intro.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $intro.ForeColor = $ink

    $manualButton = New-Button 'Open offline manual' 970 20 194 32
    $manualButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $toolList = New-Object System.Windows.Forms.ListBox
    $toolList.SetBounds(16, 70, 245, 612)
    $toolList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $toolList.IntegralHeight = $false
    Enable-NeutralListBox $toolList
    foreach ($tool in $script:ToolOptionCatalog) { [void]$toolList.Items.Add([string]$tool.label) }

    $toolTitle = New-Label '' 280 70 660 28 -Bold
    $toolTitle.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $toolTitle.ForeColor = $greenDark
    $toolTitle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $toolSummary = New-Object System.Windows.Forms.Label
    $toolSummary.SetBounds(280, 101, 884, 38)
    $toolSummary.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $toolSummary.ForeColor = $ink

    $pipelineManaged = New-Object System.Windows.Forms.Label
    $pipelineManaged.SetBounds(280, 142, 884, 43)
    $pipelineManaged.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $pipelineManaged.ForeColor = [System.Drawing.Color]::FromArgb(126, 70, 20)
    $pipelineManaged.BackColor = [System.Drawing.Color]::FromArgb(255, 247, 225)
    $pipelineManaged.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)

    $optionsStatus = New-Label '' 280 190 884 23 -Bold
    $optionsStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.SetBounds(280, 216, 884, 300)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $true
    $grid.RowHeadersVisible = $false
    $grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCells
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
    $optionColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $optionColumn.Name = 'option'
    $optionColumn.HeaderText = 'Option'
    $optionColumn.ReadOnly = $true
    $optionColumn.Width = 190
    $flagColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $flagColumn.Name = 'flag'
    $flagColumn.HeaderText = 'Command flag'
    $flagColumn.ReadOnly = $true
    $flagColumn.Width = 130
    $valueColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $valueColumn.Name = 'value'
    $valueColumn.HeaderText = 'Value'
    $valueColumn.Width = 135
    $descriptionColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $descriptionColumn.Name = 'description'
    $descriptionColumn.HeaderText = 'What it changes'
    $descriptionColumn.ReadOnly = $true
    $descriptionColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $descriptionColumn.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
    [void]$grid.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($useColumn, $optionColumn, $flagColumn, $valueColumn, $descriptionColumn))

    $commandHeader = New-Label 'Effective command' 280 522 180 24 -Bold
    $commandHeader.ForeColor = $greenDark
    $commandHeader.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

    $commandHint = New-Label 'Exact selected flags are shown. Runtime file paths use <...> placeholders.' 470 523 605 22
    $commandHint.ForeColor = $muted
    $commandHint.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $copyCommand = New-Button 'Copy' 1090 518 74 28
    $copyCommand.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right

    $preview = New-Object System.Windows.Forms.RichTextBox
    $preview.SetBounds(280, 550, 884, 132)
    $preview.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $preview.ReadOnly = $true
    $preview.WordWrap = $false
    $preview.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
    $preview.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $preview.BackColor = [System.Drawing.Color]::FromArgb(20, 26, 34)
    $preview.ForeColor = [System.Drawing.Color]::FromArgb(238, 242, 247)
    $preview.Font = New-Object System.Drawing.Font('Consolas', 9.5, [System.Drawing.FontStyle]::Regular)
    $preview.DetectUrls = $false

    $resetSelected = New-Button 'Reset selected tool' 16 701 150 38
    $resetSelected.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $resetAll = New-Button 'Reset all' 176 701 85 38
    $resetAll.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $cancelButton = New-Button 'Cancel' 942 701 100 38
    $cancelButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $applyButton = New-Button 'Apply options' 1052 701 112 38 -Primary
    $applyButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right

    function Save-CurrentToolEditor {
        if ([bool]$dialog.Tag.Loading -or [string]::IsNullOrWhiteSpace([string]$grid.Tag)) { return }
        [void]$grid.EndEdit()
        $toolKey = [string]$grid.Tag
        $selectedValues = @{}
        foreach ($row in $grid.Rows) {
            $option = $row.Tag
            $alwaysUsed = $false
            $alwaysProperty = $option.PSObject.Properties['always_used']
            if ($null -ne $alwaysProperty) { $alwaysUsed = [bool]$alwaysProperty.Value }
            if (-not $alwaysUsed -and -not [bool]$row.Cells['use'].Value) { continue }
            $optionId = [string]$option.id
            if ([string]$option.type -eq 'boolean') { $selectedValues[$optionId] = $true }
            else {
                $value = [string]$row.Cells['value'].Value
                if ([string]::IsNullOrWhiteSpace($value)) { $value = [string]$option.default }
                $selectedValues[$optionId] = $value
            }
        }
        $workingSelections[$toolKey] = $selectedValues
    }

    function Update-ToolArgumentPreview {
        if ([string]::IsNullOrWhiteSpace([string]$grid.Tag)) { $preview.Text = ''; return }
        Save-CurrentToolEditor
        $toolKey = [string]$grid.Tag
        $preview.Text = Get-ToolCommandPreview $toolKey $workingSelections
        $preview.SelectionStart = 0
        $preview.SelectionLength = 0
        $preview.ScrollToCaret()
    }

    function Load-SelectedToolEditor {
        if ($toolList.SelectedIndex -lt 0) { return }
        $dialog.Tag.Loading = $true
        try {
            $tool = $script:ToolOptionCatalog[$toolList.SelectedIndex]
            $toolKey = [string]$tool.key
            $grid.Tag = $toolKey
            $toolTitle.Text = [string]$tool.label
            $toolSummary.Text = [string]$tool.summary
            $pipelineManaged.Text = 'Pipeline-managed and protected: ' + (@($tool.pipeline_managed) -join ', ')
            $grid.Rows.Clear()
            $options = @($tool.options)
            $optionsStatus.Text = if ($options.Count) { "Common supported options ($($options.Count))" } else { 'No user-adjustable documented overrides are needed for this tool; see the explanation and offline manual.' }
            $grid.Enabled = ($options.Count -gt 0)
            $selection = $workingSelections[$toolKey]
            foreach ($option in $options) {
                $rowIndex = $grid.Rows.Add()
                $row = $grid.Rows[$rowIndex]
                $row.Tag = $option
                $optionId = [string]$option.id
                $alwaysUsed = $false
                $alwaysProperty = $option.PSObject.Properties['always_used']
                if ($null -ne $alwaysProperty) { $alwaysUsed = [bool]$alwaysProperty.Value }
                $isSelected = $alwaysUsed -or $selection.ContainsKey($optionId)
                $rawSavedValue = if ($selection.ContainsKey($optionId)) { $selection[$optionId] } else { $option.default }
                $savedValue = ConvertTo-ToolOptionDisplayValue $rawSavedValue
                $row.Cells['use'].Value = $isSelected
                if ($alwaysUsed) { $row.Cells['use'].ReadOnly = $true; $row.Cells['use'].Style.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240) }
                $row.Cells['option'].Value = [string]$option.label
                $row.Cells['flag'].Value = if ([string]$option.type -eq 'pipeline_setting') { '(pipeline setting)' } elseif ([string]$option.flag) { [string]$option.flag } else { '(selected value)' }
                if ([string]$option.type -in @('choice','choice_flag','pipeline_setting')) {
                    $choiceCell = New-Object System.Windows.Forms.DataGridViewComboBoxCell
                    $choiceCell.DisplayStyle = [System.Windows.Forms.DataGridViewComboBoxDisplayStyle]::DropDownButton
                    [void]$choiceCell.Items.AddRange([object[]]@($option.choices))
                    if ($isSelected -and @($option.choices) -notcontains [string]$savedValue) { [void]$choiceCell.Items.Add([string]$savedValue) }
                    $row.Cells[$valueColumn.Index] = $choiceCell
                    $row.Cells['value'].Value = [string]$savedValue
                }
                elseif ([string]$option.type -eq 'boolean') {
                    $row.Cells['value'].Value = 'Enabled when Use is checked'
                    $row.Cells['value'].ReadOnly = $true
                    $row.Cells['value'].Style.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
                }
                else { $row.Cells['value'].Value = [string]$savedValue }
                $row.Cells['description'].Value = [string]$option.description
                $row.MinimumHeight = 38
            }
        }
        finally { $dialog.Tag.Loading = $false }
        Update-ToolArgumentPreview
    }

    $toolList.Add_SelectedIndexChanged({
        if (-not [bool]$dialog.Tag.Loading) { Save-CurrentToolEditor }
        Load-SelectedToolEditor
    })
    $grid.Add_CurrentCellDirtyStateChanged({ if ($grid.IsCurrentCellDirty) { $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null } })
    $grid.Add_CellValueChanged({ if (-not [bool]$dialog.Tag.Loading) { Update-ToolArgumentPreview } })
    $grid.Add_CellEndEdit({ if (-not [bool]$dialog.Tag.Loading) { Update-ToolArgumentPreview } })
    $copyCommand.Add_Click({
        if (-not [string]::IsNullOrWhiteSpace($preview.Text)) {
            try { [System.Windows.Forms.Clipboard]::SetText($preview.Text) } catch { Show-Error 'The command preview could not be copied to the clipboard.' }
        }
    })
    $manualButton.Add_Click({
        if ($toolList.SelectedIndex -ge 0) {
            $tool = $script:ToolOptionCatalog[$toolList.SelectedIndex]
            $offlineProperty = $tool.PSObject.Properties['offline_manual']
            $offlineRelative = if ($null -ne $offlineProperty) { [string]$offlineProperty.Value } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($offlineRelative)) {
                $offlinePath = [System.IO.Path]::GetFullPath((Join-Path $script:AppRoot $offlineRelative))
                if (Test-Path -LiteralPath $offlinePath -PathType Leaf) { Start-Process $offlinePath; return }
            }
            Show-Error 'The bundled offline manual is missing. Re-extract the complete application package.'
        }
    })
    $resetSelected.Add_Click({
        if ($toolList.SelectedIndex -lt 0) { return }
        $toolKey = [string]$script:ToolOptionCatalog[$toolList.SelectedIndex].key
        $workingSelections[$toolKey] = @{}
        if ($toolKey -eq 'bowtie2') { $workingSelections[$toolKey]['preset'] = 'sensitive'; $workingSelections[$toolKey]['mode'] = 'end-to-end' }
        Load-SelectedToolEditor
    })
    $resetAll.Add_Click({
        foreach ($tool in $script:ToolOptionCatalog) { $workingSelections[[string]$tool.key] = @{} }
        $workingSelections['bowtie2']['preset'] = 'sensitive'
        $workingSelections['bowtie2']['mode'] = 'end-to-end'
        Load-SelectedToolEditor
    })
    $applyButton.Add_Click({
        Save-CurrentToolEditor
        for ($index = 0; $index -lt $script:ToolOptionCatalog.Count; $index++) {
            $tool = $script:ToolOptionCatalog[$index]
            $message = ''
            if (-not (Test-ToolOptionSelection $tool $workingSelections[[string]$tool.key] ([ref]$message))) {
                $toolList.SelectedIndex = $index
                Show-Error $message
                return
            }
        }
        $script:Bowtie2Preset = [string]$workingSelections['bowtie2']['preset']
        $script:Bowtie2Mode = [string]$workingSelections['bowtie2']['mode']
        $script:AdvancedToolOptionValues = Copy-ToolSelectionMap $workingSelections
        foreach ($definition in $script:ToolArgumentDefinitions) { $script:AdvancedToolArguments[[string]$definition.Key] = '' }
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $dialog.AcceptButton = $applyButton
    $dialog.CancelButton = $cancelButton
    $dialog.Controls.AddRange(@(
        $intro, $manualButton, $toolList, $toolTitle, $toolSummary, $pipelineManaged, $optionsStatus, $grid,
        $commandHeader, $commandHint, $copyCommand, $preview, $resetSelected, $resetAll, $cancelButton, $applyButton
    ))
    $toolList.SelectedIndex = 0
    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()
    Update-Review
}

$advancedToolOptionsButton.Add_Click({ Show-AdvancedToolOptions })
$toolTip.SetToolTip($advancedToolOptionsButton, 'Choose documented options with guided checkboxes, dropdowns and validated value fields. Every tool has a bundled offline manual.')

# This label is created lazily by Update-MethodSectionLayout. Initialize the
# script-scoped reference before any resize or visibility event can call the
# layout function while Set-StrictMode is active.
$script:SharedExportNote = $null

function Update-MethodSectionLayout {
    foreach ($stageKey in $stageOrder) {
        foreach ($control in $script:methodRows[$stageKey]) { $control.Visible = $false }
    }
    foreach ($control in $script:methodOptionalControls) { $control.Visible = $false }
    if ($script:SharedExportNote) { $script:SharedExportNote.Visible = $false }

    # One vertical workflow. Processing and export are consecutive sections,
    # never side-by-side panels. Labels and selectors share a row so even the
    # combined short + long mode fits without scrolling.
    $availableWidth = [Math]::Max(470, ($methodLeft.ClientSize.Width - 36))
    $x = 18
    $labelWidth = [Math]::Min(235, [Math]::Max(165, [int][Math]::Floor($availableWidth * 0.34)))
    $controlX = $x + $labelWidth
    $controlWidth = [Math]::Max(220, ($availableWidth - $labelWidth))
    $rowHeight = 34

    $methodSessionHeading.SetBounds($x, 8, $availableWidth, 22)
    $advancedWidth = 205
    $methodSessionHint.SetBounds($x, 31, [Math]::Max(230, ($availableWidth - $advancedWidth - 8)), 34)
    $advancedToolOptionsButton.SetBounds(($x + $availableWidth - $advancedWidth), 34, $advancedWidth, 30)
    $readMethodsTitle.SetBounds($x, 70, $availableWidth, 25)
    $sharedExportTitle.Visible = $false

    $readStages = @()
    switch ($script:AnalysisType) {
        'short' { $readStages = @('short_qc','short_alignment'); $readMethodsTitle.Text = 'Short-read processing, counts, and coverage' }
        'long'  { $readStages = @('long_basecalling','long_qc','long_alignment'); $readMethodsTitle.Text = 'Long-read processing, counts, and coverage' }
        'both'  { $readStages = @('short_qc','short_alignment','long_basecalling','long_qc','long_alignment'); $readMethodsTitle.Text = 'Short- and long-read processing, counts, and coverage' }
        default { $readStages = @('short_qc','short_alignment'); $readMethodsTitle.Text = 'Read processing, counts, and coverage' }
    }

    $y = 99
    foreach ($stageKey in $readStages) {
        $label = $script:methodRows[$stageKey][0]
        $combo = $script:methodRows[$stageKey][1]
        $label.SetBounds($x, ($y + 4), ($labelWidth - 8), 22)
        $combo.SetBounds($controlX, $y, $controlWidth, 27)
        $label.Visible = $true
        $combo.Visible = $true
        $y += $rowHeight
    }

    if ($script:AnalysisType -in @('short','both')) {
        $shortStrandLabel.SetBounds($x, ($y + 4), ($labelWidth - 8), 22)
        $strandCombo.SetBounds($controlX, $y, $controlWidth, 27)
        $shortStrandLabel.Visible = $true
        $strandCombo.Visible = $true
        $y += 32
    }
    if ($script:AnalysisType -in @('long','both')) {
        $longStrandLabel.SetBounds($x, ($y + 4), ($labelWidth - 8), 22)
        $longStrandCombo.SetBounds($controlX, $y, $controlWidth, 27)
        $longStrandLabel.Visible = $true
        $longStrandCombo.Visible = $true
        $y += 32
    }

    switch ($script:AnalysisType) {
        'short' { $strandHelp.Text = 'Most bacterial dUTP short-read libraries are reverse-stranded. Choose auto when the protocol is uncertain.' }
        'long'  { $strandHelp.Text = 'Long-read orientation depends on cDNA or direct-RNA preparation. Auto audits each long-read BAM.' }
        'both'  { $strandHelp.Text = 'Short-read and long-read strand orientation are configured and audited independently.' }
        default { $strandHelp.Text = 'Strand-aware processing is configured after a read type is selected.' }
    }
    $strandHelp.SetBounds($x, $y, $availableWidth, 34)
    $strandHelp.Visible = $true
    $y += 36

    if ($script:AnalysisType -in @('long','both')) {
        $filterLong.SetBounds($x, $y, $availableWidth, 25)
        $filterLong.Visible = $true
        $y += 29
    }
    if ($script:AnalysisType -in @('short','both')) {
        $adapterR1Label.SetBounds($x, ($y + 4), ($labelWidth - 8), 22)
        $adapterR1.SetBounds($controlX, $y, $controlWidth, 27)
        $adapterR1Label.Visible = $true; $adapterR1.Visible = $true
        $y += 32
        $adapterR2Label.SetBounds($x, ($y + 4), ($labelWidth - 8), 22)
        $adapterR2.SetBounds($controlX, $y, $controlWidth, 27)
        $adapterR2Label.Visible = $true; $adapterR2.Visible = $true
        $y += 32
    }
    if ($script:AnalysisType -in @('long','both')) {
        $doradoModelLabel.SetBounds($x, ($y + 4), ($labelWidth - 8), 22)
        $doradoModel.SetBounds($controlX, $y, $controlWidth, 27)
        $doradoModelLabel.Visible = $true; $doradoModel.Visible = $true
        $y += 32
        $browseWidth = 78
        $doradoPathLabel.SetBounds($x, ($y + 4), ($labelWidth - 8), 22)
        $browseDorado.SetBounds(($x + $availableWidth - $browseWidth), ($y - 1), $browseWidth, 29)
        $doradoPath.SetBounds($controlX, $y, [Math]::Max(100, ($browseDorado.Left - $controlX - 7)), 27)
        $doradoPathLabel.Visible = $true; $doradoPath.Visible = $true; $browseDorado.Visible = $true
        $y += 32
    }

    # Counting and coverage continue immediately after read processing. There is
    # no separate export panel, tab, column, or second session.
    $y += 4
    $sharedExportTitle.Visible = $false
    foreach ($stageKey in $sharedStageOrder) {
        $label = $script:methodRows[$stageKey][0]
        $combo = $script:methodRows[$stageKey][1]
        $label.SetBounds($x, ($y + 4), ($labelWidth - 8), 22)
        $combo.SetBounds($controlX, $y, $controlWidth, 27)
        $label.Visible = $true
        $combo.Visible = $true
        $y += $rowHeight
    }

    switch ($script:AnalysisType) {
        'short' { $strandHelpShared = 'Counting and coverage are generated from the short-read BAM family.' }
        'long'  { $strandHelpShared = 'Counting and coverage are generated from the long-read BAM family.' }
        'both'  { $strandHelpShared = 'The same export settings are applied independently; short- and long-read BAM families are never merged.' }
        default { $strandHelpShared = 'Analysis-ready export creates raw gene counts and coverage files.' }
    }
    if (-not $script:SharedExportNote) {
        $script:SharedExportNote = New-Label '' $x $y $availableWidth 34
        $script:SharedExportNote.ForeColor = $muted
        $methodLeft.Controls.Add($script:SharedExportNote)
    }
    $script:SharedExportNote.Text = $strandHelpShared
    $script:SharedExportNote.SetBounds($x, $y, $availableWidth, 34)
    $script:SharedExportNote.Visible = $true
    $y += 36
    $strictStrand.SetBounds($x, $y, $availableWidth, 25)
    $strictStrand.Visible = $true

    $methodLeft.AutoScroll = $false
    $methodLeft.AutoScrollMinSize = New-Object System.Drawing.Size(0, 0)
}
function Update-MethodSessionButtons { Update-MethodSectionLayout }
function Resize-MethodSessionButtons { Update-MethodSectionLayout }
function Set-MethodSession([string]$Session) { Update-MethodSectionLayout }

$methodLeft.Add_Resize({ Update-MethodSectionLayout })

function Set-MethodValue([string]$Stage, [string]$Value) {
    if (-not $script:methodCombos.ContainsKey($Stage) -or -not $script:methodOptions.ContainsKey($Stage)) { return }
    $combo = $script:methodCombos[$Stage]
    $options = @($script:methodOptions[$Stage])
    for ($i = 0; $i -lt $options.Count; $i++) {
        if ([string]$options[$i].id -eq $Value) {
            if ($i -ge $combo.Items.Count) { throw "Method list for '$Stage' was not populated before selecting '$Value'." }
            $combo.SelectedIndex = $i
            return
        }
    }
    throw "Unknown method '$Value' for stage '$Stage'."
}

function Get-MethodValue([string]$Stage) {
    if (-not $script:methodCombos.ContainsKey($Stage) -or -not $script:methodOptions.ContainsKey($Stage)) { return '' }
    $combo = $script:methodCombos[$Stage]
    if ($combo.SelectedIndex -lt 0) { return '' }
    $options = @($script:methodOptions[$Stage])
    if ($combo.SelectedIndex -ge $options.Count) { return '' }
    return [string]$options[$combo.SelectedIndex].id
}

function Update-MethodExplanation([string]$StageName) {
    if (-not $script:methodCombos.ContainsKey($StageName)) { return }
    $selectedId = Get-MethodValue $StageName
    $stage = $script:Catalog.stages.$StageName
    $matches = @($stage.options | Where-Object { [string]$_.id -eq $selectedId } | Select-Object -First 1)
    if ($matches.Count -eq 0) { return }
    $option = $matches[0]
    $methodContext.Text = "Stage: $([string]$stage.label)`r`nSelected method: $([string]$option.name)"
    $methodDefinitionCard.Tag.body.Text = [string]$option.definition
    $methodUseCard.Tag.body.Text = [string]$option.best_for
    $methodAiCard.Tag.body.Text = $(if ([bool]$option.ai_ml) { 'Yes. This method uses a task-matched neural model.' } else { 'No. This is an algorithmic bioinformatics method.' })
    $advantageLines = New-Object System.Collections.Generic.List[string]
    $number = 1
    foreach ($item in @($option.pros)) { $advantageLines.Add("$number. $item"); $number++ }
    $methodAdvantagesCard.Tag.body.Text = ($advantageLines -join "`r`n`r`n")
    $limitationLines = New-Object System.Collections.Generic.List[string]
    $number = 1
    foreach ($item in @($option.cons)) { $limitationLines.Add("$number. $item"); $number++ }
    $methodLimitationsCard.Tag.body.Text = ($limitationLines -join "`r`n`r`n")
    $commands = @($option.requires) -join ', '
    if (-not $commands) { $commands = 'None. This stage uses the supplied basecalled reads.' }
    $methodCommandsCard.Tag.body.Text = $commands
}

# Accuracy-first defaults. They can be changed freely.
Set-MethodValue 'short_qc' 'fastqc_fastp_multiqc'
Set-MethodValue 'short_alignment' 'dual_bowtie2_bwa'
Set-MethodValue 'long_basecalling' 'already_basecalled'
Set-MethodValue 'long_qc' 'nanoplot_longqc'
Set-MethodValue 'long_alignment' 'dual_minimap2_winnowmap'
Set-MethodValue 'quantification' 'featurecounts'
Set-MethodValue 'coverage' 'cpm_bigwig_stranded'
Update-MethodExplanation 'short_qc'

function Update-AnalysisVisibility {
    $shortEnabled = $script:AnalysisType -in @('short','both')
    $longEnabled = $script:AnalysisType -in @('long','both')
    foreach ($name in @('short_qc','short_alignment')) {
        foreach ($control in $script:methodRows[$name]) { $control.Enabled = $shortEnabled }
    }
    foreach ($name in @('long_basecalling','long_qc','long_alignment')) {
        foreach ($control in $script:methodRows[$name]) { $control.Enabled = $longEnabled }
    }
    foreach ($name in @('short_r1','short_r2')) { $sampleGrid.Columns[$name].Visible = $shortEnabled }
    foreach ($name in @('long_reads','pod5_dir','long_platform')) { $sampleGrid.Columns[$name].Visible = $longEnabled }
    $addPaired.Visible = $shortEnabled
    $addSingle.Visible = $shortEnabled
    $scanFastq.Visible = $shortEnabled
    $addLongReads.Visible = $longEnabled
    $addPod5.Visible = $longEnabled
    switch ($script:AnalysisType) {
        'short' { $gridGroup.Text = 'Biological RNA-seq samples  Multiple conditions are supported; choose the condition for new rows above' }
        'long' { $gridGroup.Text = 'Biological RNA-seq samples  Multiple conditions are supported; choose the condition for new rows above' }
        'both' { $gridGroup.Text = 'Matched short + long samples across conditions  Reuse Sample ID only to link modalities from the same biological sample' }
        default { $gridGroup.Text = 'Samples and replicates  Choose a read type first to show the correct file-import actions' }
    }
    $sampleActions.PerformLayout()
    $filterLong.Enabled = $longEnabled
    $strandCombo.Enabled = $shortEnabled
    $longStrandCombo.Enabled = $longEnabled
    Update-MethodSectionLayout
    if ($runStepGrid -and -not ($script:PipelineProcess -and -not $script:PipelineProcess.HasExited)) {
        Initialize-RunStepGrid
    }
}

# Page 2: environment (depends on read type, not sample files)
$envTitle = New-Label 'Linux execution environment' 30 25 520 35 -Bold
$envTitle.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$envTitle.ForeColor = $greenDark
$pageEnvironment.Controls.Add($envTitle)
$envIntro = New-Object System.Windows.Forms.Label
$envIntro.Location = New-Object System.Drawing.Point(32, 67)
$envIntro.Size = New-Object System.Drawing.Size(1130, 72)
$envIntro.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$envIntro.Text = 'Bioinformatics commands run in Linux. On Windows, this application uses WSL2 and Ubuntu. The checker evaluates the core tool family required by the read type selected on page 1; sample files are not needed. Dorado is optional and needed only for raw ONT POD5; supplied FASTQ/BAM does not require it.'
$envIntro.BackColor = $blueSoft
$envIntro.Padding = New-Object System.Windows.Forms.Padding(12)
$pageEnvironment.Controls.Add($envIntro)

$checkEnv = New-Button 'Check environment for read type' 32 155 205 36 -Primary
$installEnv = New-Button 'Install or repair core' 247 155 170 36
$installOptional = New-Button 'Install optional tools' 427 155 190 36
$doradoHelp = New-Button 'Dorado setup (POD5 only)' 627 155 205 36
$uninstallEnv = New-Button 'Uninstall environments' 842 155 190 36
$pageEnvironment.Controls.AddRange(@($checkEnv, $installEnv, $installOptional, $doradoHelp, $uninstallEnv))

$envStatus = New-Object System.Windows.Forms.RichTextBox
$envStatus.Location = New-Object System.Drawing.Point(32, 210)
$envStatus.Size = New-Object System.Drawing.Size(1130, 430)
$envStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$envStatus.ReadOnly = $true
$envStatus.BackColor = $surface
$envStatus.Font = New-Object System.Drawing.Font('Consolas', 9)
$envStatus.Text = "Not checked yet.`r`n`r`nCore tools are installed automatically. FADU and LongQC are optional accuracy-audit tools. Dorado is separate because its official binary and acceleration support depend on the computer."
$pageEnvironment.Controls.Add($envStatus)

function Start-CoreEnvironmentInstaller([switch]$RepairPythonPackages) {
    if ($script:AnalysisType -notin @('short','long','both')) {
        Show-Error 'Choose Short reads, Long reads, or Both on page 1 before installing the environment.'
        return $false
    }
    $setupScript = Join-Path $script:AppRoot 'environment\setup_windows_wsl.ps1'
    if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) {
        Show-Error "The core installer is missing:`r`n$setupScript"
        return $false
    }
    try {
        $quotedSetup = '"' + $setupScript + '"'
        $repairArgument = if ($RepairPythonPackages) { ' -RepairPythonPackages' } else { '' }
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File $quotedSetup -AnalysisType $($script:AnalysisType)$repairArgument"
        [void](Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -ErrorAction Stop)
        $modeLabel = switch ($script:AnalysisType) { 'short' { 'short reads' } 'long' { 'long reads' } default { 'short and long reads' } }
        if ($RepairPythonPackages) {
            $envStatus.Text = "The lightweight OpenPyXL repair opened for $modeLabel. It updates only the existing Python export dependency and does not reinstall WSL. When it reports completion, select Check environment for read type again."
        }
        else {
            $envStatus.Text = "Core setup opened for $modeLabel. Complete any Windows/UAC, restart, or Ubuntu account prompts, then return here and select Check environment for read type."
        }
        return $true
    }
    catch {
        if ($_.Exception.Message -match '(?i)canceled|cancelled|operation was canceled') {
            $envStatus.Text = 'Core setup was canceled. No changes were made. Select Install or repair core whenever you are ready.'
            return $false
        }
        Show-Error ("The core installer could not open.`r`n`r`n" + $_.Exception.Message)
        return $false
    }
}

$installEnv.Add_Click({ [void](Start-CoreEnvironmentInstaller) })
$uninstallEnv.Add_Click({
    $uninstaller = Join-Path $script:SuiteRoot 'Maintenance\Uninstall Bacterial RNA Analysis.bat'
    if (Test-Path -LiteralPath $uninstaller -PathType Leaf) { Start-Process -FilePath $uninstaller }
    else { Show-Error "The uninstall utility is missing:`r`n$uninstaller" }
})
$installOptional.Add_Click({
    if ($script:AnalysisType -notin @('short','long','both')) {
        Show-Error 'Choose Short reads, Long reads, or Both on page 1 before installing optional tools.'
        return
    }
    $distro = Get-WslDistro
    if (-not $distro) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $form,
            'Optional accuracy-audit tools run inside WSL/Ubuntu, but no Linux distribution is ready. Open the core installer now?',
            'Core environment required',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { [void](Start-CoreEnvironmentInstaller) }
        return
    }
    try {
        $linuxApp = Convert-ToWslPath $script:AppRoot $distro
        $optionalArguments = "-d `"$distro`" -u root -- /bin/bash `"$linuxApp/environment/install_optional_tools.sh`" --analysis-type $($script:AnalysisType)"
        Start-Process -FilePath 'wsl.exe' -ArgumentList $optionalArguments
        $optionalLabel = switch ($script:AnalysisType) { 'short' { 'FADU' } 'long' { 'LongQC' } default { 'FADU and LongQC' } }
        Show-Info "The optional $optionalLabel installer opened in Linux. Return here and check the environment after it finishes."
    }
    catch { Show-Error $_.Exception.Message }
})
$doradoHelp.Add_Click({
    $path = Join-Path $script:SuiteRoot 'Documentation\Dorado SUP setup.md'
    if (Test-Path -LiteralPath $path) { Start-Process $path } else { Show-Error 'Dorado guide was not found.' }
})
$toolTip.SetToolTip($doradoHelp, 'Dorado is optional. The user must approve and install an official platform-specific binary only when basecalling raw ONT POD5. It is not needed for supplied FASTQ or unaligned BAM.')

# Page 5: compact summary + complete step list + full-width live console
$runDashboard = New-Object System.Windows.Forms.TableLayoutPanel
$runDashboard.Dock = [System.Windows.Forms.DockStyle]::Fill
$runDashboard.ColumnCount = 2
$runDashboard.RowCount = 2
$runDashboard.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 10)
[void]$runDashboard.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 44)))
[void]$runDashboard.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 56)))
[void]$runDashboard.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 462)))
[void]$runDashboard.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$pageRun.Controls.Add($runDashboard)

$summaryStack = New-Object System.Windows.Forms.TableLayoutPanel
$summaryStack.Dock = [System.Windows.Forms.DockStyle]::Fill
$summaryStack.ColumnCount = 1
$summaryStack.RowCount = 1
$summaryStack.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 4)
[void]$summaryStack.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$summaryStack.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$runDashboard.Controls.Add($summaryStack, 0, 0)

$reviewBox = New-Object System.Windows.Forms.RichTextBox
$reviewBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$reviewBox.Margin = New-Object System.Windows.Forms.Padding(0)
$reviewBox.ReadOnly = $true
$reviewBox.BackColor = $surface
$reviewBox.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$reviewBox.WordWrap = $true
$reviewBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
$summaryStack.Controls.Add($reviewBox, 0, 0)

$processedSamplesGroup = New-Object System.Windows.Forms.GroupBox
$processedSamplesGroup.Text = 'Processed this session - 0 projects, 0 biological samples'
$processedSamplesGroup.Dock = [System.Windows.Forms.DockStyle]::None
$processedSamplesGroup.Margin = New-Object System.Windows.Forms.Padding(0)
$processedSamplesGroup.Font = New-Object System.Drawing.Font('Segoe UI', [single]9.5, [System.Drawing.FontStyle]::Bold)
$processedSamplesGroup.BackColor = $surface
$processedSamplesGroup.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$processedSamplesList = New-Object System.Windows.Forms.ListBox
$processedSamplesList.Dock = [System.Windows.Forms.DockStyle]::Fill
$processedSamplesList.Margin = New-Object System.Windows.Forms.Padding(8)
$processedSamplesList.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$processedSamplesList.HorizontalScrollbar = $true
[void]$processedSamplesList.Items.Add('No completed projects yet.')
$processedSamplesGroup.Padding = New-Object System.Windows.Forms.Padding(8, 22, 8, 8)
$processedSamplesGroup.Controls.Add($processedSamplesList)

$runPanel = New-Object System.Windows.Forms.Panel
$runPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$runPanel.Margin = New-Object System.Windows.Forms.Padding(6, 0, 0, 4)
$runPanel.BackColor = $surface
$runDashboard.Controls.Add($runPanel, 1, 0)
# The final footer button is the only Run analysis control. Keep these
# compatibility objects private so older state-management code remains safe.
$runButton = New-Button 'Run analysis' 0 0 1 1 -Primary
$runButton.Visible = $false
$dryRunButton = New-Button 'Command plan' 0 0 1 1
$dryRunButton.Visible = $false
$openOutput = New-Button 'Open export' 0 0 1 1
$openOutput.Visible = $false
$stopButton = New-Button 'Stop safely' 12 8 105 36
$resetProjectButton = New-Button 'Reset project' 125 8 112 36
foreach ($button in @($stopButton, $resetProjectButton)) {
    $button.Font = New-Object System.Drawing.Font('Segoe UI', [single]9.25, [System.Drawing.FontStyle]::Bold)
}
$stopButton.Enabled = $false
$runPanel.Controls.AddRange(@($stopButton, $resetProjectButton))

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(12, 54)
$progress.Size = New-Object System.Drawing.Size(590, 22)
$progress.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$runPanel.Controls.Add($progress)
$runStepStatus = New-Label 'Workflow steps will appear when the run starts.' 12 82 590 24 -Bold
$runStepStatus.ForeColor = $blue
$runStepStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$runPanel.Controls.Add($runStepStatus)

$runStepGrid = New-Object System.Windows.Forms.DataGridView
$runStepGrid.Location = New-Object System.Drawing.Point(12, 108)
$runStepGrid.Size = New-Object System.Drawing.Size(590, 254)
$runStepGrid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$runStepGrid.ReadOnly = $true
$runStepGrid.AllowUserToAddRows = $false
$runStepGrid.AllowUserToDeleteRows = $false
$runStepGrid.AllowUserToResizeRows = $false
$runStepGrid.RowHeadersVisible = $false
$runStepGrid.MultiSelect = $false
$runStepGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$runStepGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
$runStepGrid.BackgroundColor = $surface
$runStepGrid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$runStepGrid.GridColor = [System.Drawing.Color]::Black
$runStepGrid.ColumnHeadersHeight = 26
$runStepGrid.EnableHeadersVisualStyles = $false
$runStepGrid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::Single
$runStepGrid.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::Single
$runStepGrid.RowTemplate.Height = 20
$runStepGrid.ScrollBars = [System.Windows.Forms.ScrollBars]::None
$runStepGrid.EnableHeadersVisualStyles = $false
$runStepGrid.ColumnHeadersDefaultCellStyle.BackColor = $background
$runStepGrid.ColumnHeadersDefaultCellStyle.ForeColor = $ink
$runStepGrid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$runNumberColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$runNumberColumn.Name = 'step_number'; $runNumberColumn.HeaderText = 'No.'; $runNumberColumn.Width = 45
$runNameColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$runNameColumn.Name = 'step_name'; $runNameColumn.HeaderText = 'Workflow step'; $runNameColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
$runStateColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$runStateColumn.Name = 'step_status'; $runStateColumn.HeaderText = 'Status'; $runStateColumn.Width = 105
[void]$runStepGrid.Columns.Add($runNumberColumn)
[void]$runStepGrid.Columns.Add($runNameColumn)
[void]$runStepGrid.Columns.Add($runStateColumn)
$runPanel.Controls.Add($runStepGrid)
$runPanel.Controls.Add($processedSamplesGroup)

function Layout-RunReviewPanel {
    if (-not $runPanel -or $runPanel.IsDisposed) { return }
    $contentWidth = [Math]::Max(360, ($runPanel.ClientSize.Width - 24))
    $progress.Width = $contentWidth
    $runStepStatus.Width = $contentWidth
    $runStepGrid.Width = $contentWidth

    # Fit the grid to its real row count. This keeps the enclosing border
    # complete and avoids an empty pseudo-row area for nine-step modes, while
    # still fitting all eleven rows used by a combined-read project.
    $displayRowCount = [Math]::Max(1, $runStepGrid.Rows.Count)
    $desiredGridHeight = $runStepGrid.ColumnHeadersHeight + ($displayRowCount * $runStepGrid.RowTemplate.Height) + 3
    $maximumGridHeight = [Math]::Max(70, ($runPanel.ClientSize.Height - 178))
    $runStepGrid.Height = [Math]::Min($desiredGridHeight, $maximumGridHeight)

    $processedTop = $runStepGrid.Bottom + 8
    $processedHeight = [Math]::Max(58, ($runPanel.ClientSize.Height - $processedTop - 8))
    $processedSamplesGroup.SetBounds(12, $processedTop, $contentWidth, $processedHeight)
}
$runPanel.Add_Resize({ Layout-RunReviewPanel })
Layout-RunReviewPanel

$consoleGroup = New-Object System.Windows.Forms.GroupBox
$consoleGroup.Text = 'Live console'
$consoleGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$consoleGroup.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$consoleGroup.Font = New-Object System.Drawing.Font('Segoe UI', [single]10, [System.Drawing.FontStyle]::Bold)
$consoleGroup.BackColor = $surface
$runDashboard.Controls.Add($consoleGroup, 0, 1)
$runDashboard.SetColumnSpan($consoleGroup, 2)

$runStatus = New-Label 'Ready to validate' 14 20 760 26 -Bold
$runStatus.ForeColor = $greenDark
$runStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$openRunLogFileButton = New-Button 'Open log file' 900 17 120 28
$openRunLogFolderButton = New-Button 'Open log folder' 1028 17 128 28
foreach ($button in @($openRunLogFileButton, $openRunLogFolderButton)) {
    $button.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $button.Font = New-Object System.Drawing.Font('Segoe UI', [single]8.75, [System.Drawing.FontStyle]::Bold)
}
$openRunLogFileButton.Enabled = $false
$openRunLogFolderButton.Enabled = $false
$consoleGroup.Controls.AddRange(@($runStatus, $openRunLogFileButton, $openRunLogFolderButton))
$runLog = New-Object System.Windows.Forms.RichTextBox
$runLog.Location = New-Object System.Drawing.Point(14, 49)
$runLog.Size = New-Object System.Drawing.Size(1100, 190)
$runLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$runLog.ReadOnly = $true
$runLog.WordWrap = $false
$runLog.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
$runLog.BackColor = [System.Drawing.Color]::FromArgb(25, 31, 27)
$runLog.ForeColor = [System.Drawing.Color]::FromArgb(215, 232, 219)
$runLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$consoleGroup.Controls.Add($runLog)
$consoleGroup.Add_Resize({
    $openRunLogFolderButton.Left = [Math]::Max(280, ($consoleGroup.ClientSize.Width - $openRunLogFolderButton.Width - 14))
    $openRunLogFileButton.Left = [Math]::Max(150, ($openRunLogFolderButton.Left - $openRunLogFileButton.Width - 8))
    $runStatus.Width = [Math]::Max(120, ($openRunLogFileButton.Left - 24))
    $runLog.SetBounds(14, 49, [Math]::Max(300, ($consoleGroup.ClientSize.Width - 28)), [Math]::Max(70, ($consoleGroup.ClientSize.Height - 63)))
})

function Get-RnaSeqPipelineLogPath {
    if (-not [string]::IsNullOrWhiteSpace([string]$script:RunOutput)) {
        $publishedLog = Join-Path $script:RunOutput 'intermediate\Complete pipeline log.txt'
        if (Test-Path -LiteralPath $publishedLog -PathType Leaf) { return $publishedLog }
        $legacyFinalLog = Join-Path $script:RunOutput 'analysis_ready\Intermediate files\Complete pipeline log.txt'
        if (Test-Path -LiteralPath $legacyFinalLog -PathType Leaf) { return $legacyFinalLog }
        return (Join-Path $script:RunOutput '00_project\logs\pipeline.log')
    }
    return $null
}
function Read-RnaSeqLogTail([string]$Path, [int64]$MaximumBytes = 524288) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
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
            return "[Live console is limited to the most recent 512 KiB. Open the log file for the complete audit trail.]`r`n" + $text
        }
        return $text
    }
    catch { return '' }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}
function Open-RnaSeqPipelineLog {
    $path = Get-RnaSeqPipelineLogPath
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { Start-Process -FilePath $path; return }
    Show-Info 'The pipeline log has not been created yet. Start the analysis first.'
}
function Open-RnaSeqPipelineLogFolder {
    $path = Get-RnaSeqPipelineLogPath
    $folder = if ($path) { Split-Path -Parent $path } else { $null }
    if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) { Start-Process explorer.exe $folder; return }
    Show-Info 'The run log folder has not been created yet. Start the analysis first.'
}
$openRunLogFileButton.Add_Click({ Open-RnaSeqPipelineLog })
$openRunLogFolderButton.Add_Click({ Open-RnaSeqPipelineLogFolder })

$script:CurrentRunStagePlan = @()
$script:CurrentRunStep = 0
$script:CurrentRunTotal = 0
$script:CompletedProjectCount = 0
$script:ProcessedBiologicalSamples = 0
$script:ActiveRunSummary = $null
$script:RunCompletionRecorded = $false
$script:PostProcessingChoiceShown = $false

function Get-IncludedSampleStatistics([object]$Config) {
    $technicalRows = 0
    $uniqueIds = @{}
    foreach ($sample in @($Config.samples)) {
        if (-not [bool]$sample.include) { continue }
        $technicalRows++
        $sampleId = [string]$sample.sample_id
        if (-not [string]::IsNullOrWhiteSpace($sampleId)) { $uniqueIds[$sampleId] = $true }
    }
    return [pscustomobject]@{
        BiologicalSamples = $uniqueIds.Count
        InputRows = $technicalRows
    }
}

function Register-CompletedRun {
    if ($script:RunCompletionRecorded -or -not $script:ActiveRunSummary) { return }
    $script:RunCompletionRecorded = $true
    if ([bool]$script:ActiveRunSummary.DryRun) { return }

    $script:CompletedProjectCount++
    $script:ProcessedBiologicalSamples += [int]$script:ActiveRunSummary.BiologicalSamples
    if ($processedSamplesList.Items.Count -eq 1 -and [string]$processedSamplesList.Items[0] -eq 'No completed projects yet.') {
        $processedSamplesList.Items.Clear()
    }
    $entry = '{0} | {1} | {2} | {3} biological sample(s), {4} input row(s)' -f `
        ([DateTime]::Now.ToString('HH:mm')), `
        [string]$script:ActiveRunSummary.Project, `
        [string]$script:ActiveRunSummary.ReadType, `
        [int]$script:ActiveRunSummary.BiologicalSamples, `
        [int]$script:ActiveRunSummary.InputRows
    [void]$processedSamplesList.Items.Add($entry)
    $processedSamplesList.TopIndex = [Math]::Max(0, ($processedSamplesList.Items.Count - 1))
    $processedSamplesGroup.Text = "Processed this session - $($script:CompletedProjectCount) project(s), $($script:ProcessedBiologicalSamples) biological sample(s)"
}

function Add-BlankStarterSampleRow {
    $starterIndex = $sampleGrid.Rows.Add()
    $sampleGrid.Rows[$starterIndex].Cells['include'].Value = $true
    $sampleGrid.Rows[$starterIndex].Cells['replicate'].Value = '1'
}

function Reset-RnaSeqProject {
    if ($script:PipelineProcess -and -not $script:PipelineProcess.HasExited) {
        Show-Info 'The pipeline is still running. Stop it safely before resetting the project.'
        return
    }
    Hide-HelpPopup
    if ($runTimer) { $runTimer.Stop() }
    if ($script:PipelineProcess) { try { $script:PipelineProcess.Dispose() } catch { } }
    $script:PipelineProcess = $null
    $script:RunOutput = ''
    $script:CurrentConfigPath = ''
    $script:LastLogLength = 0
    $script:ActiveRunSummary = $null
    $script:RunCompletionRecorded = $false
    $script:PostProcessingChoiceShown = $false

    foreach ($radio in $script:TypeRadios) { $radio.Checked = $false }
    $script:AnalysisType = ''
    $projectName.Clear()
    $outputFolder.Clear()
    $referenceFasta.Clear()
    $annotationFile.Clear()
    $threadsBox.Value = [decimal][Math]::Min([int]$threadsBox.Maximum, [int]$cpuTopology.Recommended)
    $mapqBox.Value = 10
    $featureType.SelectedItem = 'auto'
    $idAttribute.SelectedItem = 'auto'
    $strandCombo.SelectedItem = 'reverse'
    $longStrandCombo.SelectedItem = 'auto'
    $strictStrand.Checked = $true
    $filterLong.Checked = $false
    $adapterR1.Clear()
    $adapterR2.Clear()
    $doradoModel.Text = 'sup'
    $doradoPath.Text = 'dorado'
    $script:Bowtie2Preset = 'sensitive'
    $script:Bowtie2Mode = 'end-to-end'
    foreach ($definition in $script:ToolArgumentDefinitions) {
        $script:AdvancedToolArguments[[string]$definition.Key] = ''
    }
    $script:AdvancedToolOptionValues = @{}

    Set-MethodValue 'short_qc' 'fastqc_fastp_multiqc'
    Set-MethodValue 'short_alignment' 'dual_bowtie2_bwa'
    Set-MethodValue 'long_basecalling' 'already_basecalled'
    Set-MethodValue 'long_qc' 'nanoplot_longqc'
    Set-MethodValue 'long_alignment' 'dual_minimap2_winnowmap'
    Set-MethodValue 'quantification' 'featurecounts'
    Set-MethodValue 'coverage' 'cpm_bigwig_stranded'

    $sampleGrid.Rows.Clear()
    Add-BlankStarterSampleRow
    $progress.Value = 0
    $runLog.Clear()
    $runStatus.Text = 'Ready for a new project. The verified environment was preserved.'
    $runStepStatus.Text = 'Choose a read type to create the new workflow step list.'
    $runStepGrid.Rows.Clear()
    Layout-RunReviewPanel
    $runButton.Enabled = $true
    $dryRunButton.Enabled = $true
    $stopButton.Enabled = $false
    $openOutput.Enabled = $false
    $openRunLogFileButton.Enabled = $false
    $openRunLogFolderButton.Enabled = $false
    $nextButton.Text = 'Next'
    $nextButton.Enabled = $true

    $script:MaxUnlockedStep = 0
    $script:AllowForwardTabNavigation = $true
    try { $tabs.SelectedIndex = 0 }
    finally { $script:AllowForwardTabNavigation = $false }
    Update-AnalysisVisibility
    Update-ModeSelectionDisplay
    Update-RequiredInputInstructions
    Update-MethodSectionLayout
    $tabs.Invalidate()
    Show-Info 'The project was reset. Package and Linux readiness results were kept, and completed-session sample totals were preserved.'
}

function Get-RunStagePlan {
    $plan = New-Object System.Collections.Generic.List[object]
    if ($script:AnalysisType -notin @('short','long','both')) { return [object[]]$plan.ToArray() }
    [void]$plan.Add([pscustomobject]@{ Id = 'initialize'; Name = 'Initialize project and record inputs' })
    [void]$plan.Add([pscustomobject]@{ Id = 'reference'; Name = 'Normalize and index bacterial reference' })
    if ($script:AnalysisType -in @('short','both')) {
        [void]$plan.Add([pscustomobject]@{ Id = 'short_qc'; Name = 'Short-read QC and cleaning' })
        [void]$plan.Add([pscustomobject]@{ Id = 'short_alignment'; Name = 'Short-read bacterial alignment' })
    }
    if ($script:AnalysisType -in @('long','both')) {
        [void]$plan.Add([pscustomobject]@{ Id = 'long_qc'; Name = 'Long-read basecalling, QC, and filtering' })
        [void]$plan.Add([pscustomobject]@{ Id = 'long_alignment'; Name = 'Long-read bacterial alignment' })
    }
    [void]$plan.Add([pscustomobject]@{ Id = 'bam_qc'; Name = 'Validate coordinate-sorted BAM and BAI' })
    [void]$plan.Add([pscustomobject]@{ Id = 'counts'; Name = 'Audit strand and export raw gene counts' })
    [void]$plan.Add([pscustomobject]@{ Id = 'coverage'; Name = 'Create analysis-ready coverage tracks' })
    [void]$plan.Add([pscustomobject]@{ Id = 'multiqc'; Name = 'Combine quality-control reports' })
    [void]$plan.Add([pscustomobject]@{ Id = 'export'; Name = 'Finalize export, provenance, and checksums' })
    return [object[]]$plan.ToArray()
}

function Set-RunStepRowStatus([System.Windows.Forms.DataGridViewRow]$Row, [string]$State) {
    $Row.Cells['step_status'].Value = $State
    $backColor = $surface
    $foreColor = $ink
    switch ($State) {
        'Running' { $backColor = $blueSoft; $foreColor = $blue }
        'Finished' { $backColor = $greenSoft; $foreColor = $greenDark }
        'Error' { $backColor = [System.Drawing.Color]::MistyRose; $foreColor = [System.Drawing.Color]::DarkRed }
        'Stopped' { $backColor = [System.Drawing.Color]::LightYellow; $foreColor = [System.Drawing.Color]::DarkGoldenrod }
        default { $backColor = $surface; $foreColor = $muted }
    }
    $Row.DefaultCellStyle.BackColor = $backColor
    $Row.DefaultCellStyle.ForeColor = $foreColor
    $Row.Cells['step_status'].Style.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
}

function Initialize-RunStepGrid {
    $runStepGrid.Rows.Clear()
    $script:CurrentRunStagePlan = @()
    $stagePlanResult = Get-RunStagePlan
    if ($null -ne $stagePlanResult) { $script:CurrentRunStagePlan = [object[]]$stagePlanResult }
    $script:CurrentRunStep = 0
    $script:CurrentRunTotal = $script:CurrentRunStagePlan.Count
    if ($script:CurrentRunTotal -eq 0) {
        $runStepStatus.Text = 'Choose Short reads, Long reads, or Both to display the workflow steps.'
        $runStatus.Text = 'Waiting for a read type'
        Layout-RunReviewPanel
        return
    }
    for ($index = 0; $index -lt $script:CurrentRunStagePlan.Count; $index++) {
        $rowIndex = $runStepGrid.Rows.Add()
        $row = $runStepGrid.Rows[$rowIndex]
        $row.Cells['step_number'].Value = [string]($index + 1)
        $row.Cells['step_name'].Value = [string]$script:CurrentRunStagePlan[$index].Name
        $row.Height = 20
        Set-RunStepRowStatus $row 'Pending'
    }
    $runStepGrid.ClearSelection()
    $runStepStatus.Text = "$($script:CurrentRunTotal) planned steps | $($script:CurrentRunTotal) pending"
    $runStatus.Text = 'Ready to validate and run'
    Layout-RunReviewPanel
}

function Update-RunStepGrid([int]$Current, [int]$Total, [string]$OverallStatus) {
    if ($runStepGrid.Rows.Count -eq 0 -or $runStepGrid.Rows.Count -ne $Total) { Initialize-RunStepGrid }
    if ($runStepGrid.Rows.Count -eq 0) { return }
    $script:CurrentRunStep = [Math]::Max(0, [Math]::Min($Current, $runStepGrid.Rows.Count))
    $script:CurrentRunTotal = $runStepGrid.Rows.Count
    for ($index = 0; $index -lt $runStepGrid.Rows.Count; $index++) {
        $stepNumber = $index + 1
        $rowState = 'Pending'
        if ($OverallStatus -eq 'complete') { $rowState = 'Finished' }
        elseif ($stepNumber -lt $script:CurrentRunStep) { $rowState = 'Finished' }
        elseif ($stepNumber -eq $script:CurrentRunStep) {
            if ($OverallStatus -eq 'error') { $rowState = 'Error' }
            elseif ($OverallStatus -eq 'stopped') { $rowState = 'Stopped' }
            else { $rowState = 'Running' }
        }
        Set-RunStepRowStatus $runStepGrid.Rows[$index] $rowState
    }
    $runStepGrid.ClearSelection()
    if ($runStepGrid.Rows.Count -gt 0) { $runStepGrid.FirstDisplayedScrollingRowIndex = 0 }
}

function Get-SampleRows {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($row in $sampleGrid.Rows) {
        if ($row.IsNewRow) { continue }
        $sampleId = [string]$row.Cells['sample_id'].Value
        if ([string]::IsNullOrWhiteSpace($sampleId) -and [string]::IsNullOrWhiteSpace([string]$row.Cells['short_r1'].Value) -and [string]::IsNullOrWhiteSpace([string]$row.Cells['long_reads'].Value) -and [string]::IsNullOrWhiteSpace([string]$row.Cells['pod5_dir'].Value)) { continue }
        $includeValue = $row.Cells['include'].Value
        $include = $true
        if ($null -ne $includeValue) { $include = [bool]$includeValue }
        $item = [ordered]@{ include = $include }
        foreach ($name in @('sample_id','condition','replicate','batch','short_r1','short_r2','long_reads','pod5_dir','long_platform')) {
            $item[$name] = ([string]$row.Cells[$name].Value).Trim()
        }
        $rows.Add([pscustomobject]$item)
    }
    return [object[]]$rows.ToArray()
}

function New-ProjectConfig {
    $methods = [ordered]@{}
    foreach ($name in $stageOrder) { $methods[$name] = Get-MethodValue $name }
    $methods['adapter_r1'] = $adapterR1.Text.Trim()
    $methods['adapter_r2'] = $adapterR2.Text.Trim()
    $toolArguments = [ordered]@{}
    $toolCustomArguments = [ordered]@{}
    $toolOptionValues = [ordered]@{}
    foreach ($definition in $script:ToolArgumentDefinitions) {
        $key = [string]$definition.Key
        $toolArguments[$key] = Get-EffectiveToolArgumentString $key
        $toolCustomArguments[$key] = ([string]$script:AdvancedToolArguments[$key]).Trim()
        $selectedValues = [ordered]@{}
        if ($script:AdvancedToolOptionValues.ContainsKey($key)) {
            $toolMatches = @($script:ToolOptionCatalog | Where-Object { [string]$_.key -eq $key } | Select-Object -First 1)
            if ($toolMatches.Count) {
                foreach ($option in @($toolMatches[0].options)) {
                    $optionId = [string]$option.id
                    if ($script:AdvancedToolOptionValues[$key].ContainsKey($optionId)) {
                        $selectedValues[$optionId] = $script:AdvancedToolOptionValues[$key][$optionId]
                    }
                }
            }
        }
        $toolOptionValues[$key] = $selectedValues
    }
    $sampleRows = [object[]](Get-SampleRows)
    return [ordered]@{
        schema_version = 2
        project = [ordered]@{
            name = $projectName.Text.Trim()
            analysis_type = $script:AnalysisType
            output_dir = $outputFolder.Text.Trim()
            threads = [int]$threadsBox.Value
            min_mapq = [int]$mapqBox.Value
            resume = $true
            strict_strand_audit = [bool]$strictStrand.Checked
        }
        reference = [ordered]@{
            fasta = $referenceFasta.Text.Trim()
            annotation = $annotationFile.Text.Trim()
            feature_type = $featureType.Text.Trim()
            id_attribute = $idAttribute.Text.Trim()
        }
        library = [ordered]@{
            strand = [string]$strandCombo.SelectedItem
            short_strand = [string]$strandCombo.SelectedItem
            long_strand = [string]$longStrandCombo.SelectedItem
            protocol = 'user_declared_or_auto_audited'
        }
        methods = $methods
        options = [ordered]@{
            short_quality = 20
            short_unqualified_percent = 40
            short_min_length = 30
            filter_long_reads = [bool]$filterLong.Checked
            long_min_quality = 10
            long_min_length = 200
            strand_audit_min_assigned = 1000
            strand_audit_dominance = 0.80
            dorado_model = $doradoModel.Text.Trim()
            dorado_path = $doradoPath.Text.Trim()
            bowtie2_preset = $script:Bowtie2Preset
            bowtie2_mode = $script:Bowtie2Mode
            tool_arguments = $toolArguments
            tool_option_values = $toolOptionValues
            tool_custom_arguments = $toolCustomArguments
        }
        samples = $sampleRows
    }
}

function Test-GuiConfig([object]$Config) {
    $errors = New-Object System.Collections.Generic.List[string]
    $includedSamples = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $Config.samples) {
        if ([bool]$candidate.include) { $includedSamples.Add($candidate) }
    }
    if (-not $Config.project.analysis_type) { $errors.Add('Choose Short reads, Long reads, or Both on page 1.') }
    if (-not $Config.project.name) { $errors.Add('Project name is required.') }
    if (-not $Config.project.output_dir) { $errors.Add('Output folder is required.') }
    if (-not $Config.reference.fasta -or -not (Test-Path -LiteralPath $Config.reference.fasta -PathType Leaf)) { $errors.Add('A readable reference FASTA is required.') }
    if (-not $Config.reference.annotation -or -not (Test-Path -LiteralPath $Config.reference.annotation -PathType Leaf)) { $errors.Add('A readable GFF3 or GTF annotation is required.') }
    if ($includedSamples.Count -eq 0) { $errors.Add('At least one included sample row is required.') }
    $conditionBySampleId = @{}
    foreach ($sample in $includedSamples) {
        if ($sample.sample_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { $errors.Add("Invalid Sample ID: '$($sample.sample_id)'.") }
        if ([string]::IsNullOrWhiteSpace([string]$sample.condition)) { $errors.Add("Sample $($sample.sample_id) needs a biological condition, for example Control or Treatment.") }
        if ([string]::IsNullOrWhiteSpace([string]$sample.replicate)) { $errors.Add("Sample $($sample.sample_id) needs a biological replicate identifier.") }
        if ($sample.sample_id) {
            if ($conditionBySampleId.ContainsKey([string]$sample.sample_id) -and -not [string]::Equals([string]$conditionBySampleId[[string]$sample.sample_id], [string]$sample.condition, [System.StringComparison]::OrdinalIgnoreCase)) {
                $errors.Add("Technical rows sharing Sample ID $($sample.sample_id) must use the same condition.")
            }
            else { $conditionBySampleId[[string]$sample.sample_id] = [string]$sample.condition }
        }
        if ($Config.project.analysis_type -in @('short','both') -and -not $sample.short_r1 -and $Config.project.analysis_type -eq 'short') { $errors.Add("Sample $($sample.sample_id) needs Short R1.") }
        if ($Config.project.analysis_type -in @('long','both') -and -not $sample.long_reads -and -not $sample.pod5_dir -and $Config.project.analysis_type -eq 'long') { $errors.Add("Sample $($sample.sample_id) needs long reads or POD5.") }
        foreach ($field in @('short_r1','short_r2','long_reads')) {
            $value = [string]$sample.$field
            if ($value -and -not (Test-Path -LiteralPath $value -PathType Leaf)) { $errors.Add("File not found for $($sample.sample_id): $value") }
        }
        if ($sample.pod5_dir -and -not (Test-Path -LiteralPath $sample.pod5_dir -PathType Container)) { $errors.Add("POD5 folder not found for $($sample.sample_id): $($sample.pod5_dir)") }
        if (($sample.long_reads -or $sample.pod5_dir) -and -not $sample.long_platform) { $errors.Add("Choose a long-read platform for $($sample.sample_id).") }
        if ($sample.pod5_dir -and $Config.methods.long_basecalling -eq 'already_basecalled') { $errors.Add("POD5 for $($sample.sample_id) requires Dorado SUP or HAC.") }
    }
    if ($Config.methods.short_qc -eq 'fastqc_cutadapt_multiqc' -and -not $Config.methods.adapter_r1) { $errors.Add('Cutadapt requires the R1 adapter sequence.') }
    if ($errors.Count -gt 0) { Show-Error ($errors -join "`r`n"); return $false }
    return $true
}

function Write-Config([object]$Config, [string]$Path) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    $json = $Config | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Update-Review {
    $config = New-ProjectConfig
    $technical = 0
    $uniqueIds = @{}
    foreach ($sample in $config.samples) {
        if ([bool]$sample.include) {
            $technical++
            $uniqueIds[[string]$sample.sample_id] = $true
        }
    }
    $unique = $uniqueIds.Count
    $customToolCount = 0
    foreach ($property in $config.options.tool_arguments.GetEnumerator()) {
        if (-not [string]::IsNullOrWhiteSpace([string]$property.Value)) { $customToolCount++ }
    }
    $advancedSummary = "BOWTIE2 SETTINGS`r`nMode: $($config.options.bowtie2_mode)`r`nPreset: $($config.options.bowtie2_preset)`r`nTools with additional expert arguments: $customToolCount"
    $conditionIds = @{}
    foreach ($sample in $config.samples) {
        if (-not [bool]$sample.include) { continue }
        $condition = ([string]$sample.condition).Trim()
        if (-not $condition) { $condition = 'Unassigned' }
        if (-not $conditionIds.ContainsKey($condition)) { $conditionIds[$condition] = @{} }
        $conditionIds[$condition][[string]$sample.sample_id] = $true
    }
    $conditionLines = New-Object System.Collections.Generic.List[string]
    foreach ($condition in ($conditionIds.Keys | Sort-Object)) { $conditionLines.Add("${condition}: $($conditionIds[$condition].Count) biological sample(s)") }
    $conditionSummary = $(if ($conditionLines.Count -gt 0) { $conditionLines -join "`r`n" } else { 'No conditions assigned' })
    $deReady = $false
    if ($conditionIds.Count -ge 2) {
        $deReady = $true
        foreach ($condition in $conditionIds.Keys) { if ($conditionIds[$condition].Count -lt 3) { $deReady = $false } }
    }
    $deReadiness = $(if ($deReady) { 'At least two conditions with at least three biological samples each.' } else { 'Processing is allowed, but differential expression requires at least two conditions with three biological samples each.' })
    $methodSummary = ''
    $strandSummary = ''
    switch ($config.project.analysis_type) {
        'short' {
            $methodSummary = "SHORT METHODS`r`nQC: $($config.methods.short_qc)`r`nAlignment: $($config.methods.short_alignment)"
            $strandSummary = "STRAND SETTING`r`nShort: $($config.library.short_strand)"
        }
        'long' {
            $methodSummary = "LONG METHODS`r`nBasecalling: $($config.methods.long_basecalling)`r`nQC: $($config.methods.long_qc)`r`nAlignment: $($config.methods.long_alignment)"
            $strandSummary = "STRAND SETTING`r`nLong: $($config.library.long_strand)"
        }
        default {
            $methodSummary = "SHORT METHODS`r`nQC: $($config.methods.short_qc)`r`nAlignment: $($config.methods.short_alignment)`r`n`r`nLONG METHODS`r`nBasecalling: $($config.methods.long_basecalling)`r`nQC: $($config.methods.long_qc)`r`nAlignment: $($config.methods.long_alignment)"
            $strandSummary = "STRAND SETTINGS`r`nShort: $($config.library.short_strand)`r`nLong: $($config.library.long_strand)"
        }
    }
    $reviewText = @"
PROJECT
$($config.project.name)

READ TYPE
$($config.project.analysis_type)

SAMPLES
$unique biological sample IDs across $technical input rows

CONDITIONS
$conditionSummary

DIFFERENTIAL-EXPRESSION READINESS
$deReadiness

REFERENCE
$($config.reference.fasta)
$($config.reference.annotation)

FINAL RESULTS FOLDER
$($config.project.output_dir)

$methodSummary

$strandSummary

$advancedSummary

VISIBLE FINAL RESULTS
Counts & Annotation.xlsx
BAM-BAI-IGV folder
QC Analysis.html
intermediate folder containing reference, coverage, metadata, detailed QC and provenance

NOT RUN IN THIS RNA-SEQ PROCESSING RUN
Differential expression, GO/enrichment, network inference, operon prediction, variants, PPI, and transcript discovery. Use the module chooser for the integrated downstream and operon workflows.
"@
    Set-DescriptionPanelText -Box $reviewBox -Text $reviewText
}

function Invoke-EnvironmentCheck {
    if ($script:AnalysisType -notin @('short','long','both')) {
        Show-Error 'Choose Short reads, Long reads, or Both on page 1 before checking the environment.'
        return
    }
    $distro = Get-WslDistro
    if (-not $distro) {
        $envStatus.Text = 'No runnable WSL Linux distribution was found. Select Install or repair core. The installer will reuse any valid Ubuntu or Debian distribution and ignore stale saved names.'
        $envStatus.BackColor = [System.Drawing.Color]::MistyRose
        return
    }
    $reportPath = ''
    try {
        $linuxApp = Convert-ToWslPath $script:AppRoot $distro
        $reportPath = [System.IO.Path]::GetTempFileName()
        $linuxReportPath = Convert-ToWslPath $reportPath $distro
        $modeLabel = switch ($script:AnalysisType) { 'short' { 'short-read' } 'long' { 'long-read' } default { 'combined short- and long-read' } }
        $envStatus.Text = "Checking the $modeLabel tool family. No sample files are required for this check..."
        $envStatus.BackColor = $blueSoft
        $form.Refresh()
        $check = Invoke-WslCapture @(
            '-d', (Normalize-WslName $distro),
            '-u', 'root',
            '--', '/bin/bash',
            "$linuxApp/environment/check_environment.sh",
            '--analysis-type', $script:AnalysisType,
            '--report-file', $linuxReportPath
        ) 300000
        $exitCode = [int]$check.ExitCode
        $capturedParts = New-Object System.Collections.Generic.List[string]
        $reportText = ''
        if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
            try { $reportText = [System.IO.File]::ReadAllText($reportPath, [System.Text.Encoding]::UTF8) }
            catch { $reportText = '' }
        }
        $reportText = Normalize-NativeOutputText $reportText
        if (-not [string]::IsNullOrWhiteSpace($reportText)) {
            [void]$capturedParts.Add($reportText)
        }
        else {
            foreach ($value in @($check.StandardOutput, $check.StandardError)) {
                $piece = Normalize-NativeOutputText ([string]$value)
                if (-not [string]::IsNullOrWhiteSpace($piece)) { [void]$capturedParts.Add($piece) }
            }
        }
        $captured = Normalize-NativeOutputText ($capturedParts -join "`r`n")
        if ([string]::IsNullOrWhiteSpace($captured) -or $captured.Trim().Length -le 1) {
            $captured = if ($exitCode -eq 0) {
                'The checker completed without returning a detailed tool report.'
            }
            else {
                'The checker returned no readable output. Select Install or repair core, let the installer finish, and check again.'
            }
        }
        $missingItems = @(
            [System.Text.RegularExpressions.Regex]::Matches(
                $captured,
                '(?im)^\[MISSING\]\s+(\S+)'
            ) | ForEach-Object { [string]$_.Groups[1].Value }
        )
        $onlyOpenPyxlMissing = (
            $exitCode -ne 0 -and
            $missingItems.Count -eq 1 -and
            $missingItems[0] -eq 'python:openpyxl'
        )
        if ($onlyOpenPyxlMissing) {
            $envStatus.Text = @"
ENVIRONMENT CHECK  SMALL UPDATE REQUIRED
Read type: $modeLabel
WSL distribution: $distro
Exit code: $exitCode

$captured

Your existing RNA-seq programs are still installed. Only the Excel-workbook dependency added by this software update is missing.
"@
            $envStatus.BackColor = [System.Drawing.Color]::MistyRose
            $envStatus.SelectionStart = 0
            $envStatus.SelectionLength = 0
            $envStatus.ScrollToCaret()
            $form.Refresh()
            $repairAnswer = [System.Windows.Forms.MessageBox]::Show(
                $form,
                "The existing RNA-seq environment is intact. This update added organized Excel result workbooks and needs OpenPyXL 3.1 or newer.`r`n`r`nRepair only this Python package now? WSL and the other analysis tools will not be reinstalled.",
                'Repair update dependency',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            if ($repairAnswer -eq [System.Windows.Forms.DialogResult]::Yes) {
                [void](Start-CoreEnvironmentInstaller -RepairPythonPackages)
                return
            }
        }
        $resultLabel = if ($exitCode -eq 0) { 'READY' } else { 'ACTION REQUIRED' }
        $envStatus.Text = @"
ENVIRONMENT CHECK  $resultLabel
Read type: $modeLabel
WSL distribution: $distro
Exit code: $exitCode

$captured
"@
        $envStatus.SelectionStart = 0
        $envStatus.SelectionLength = 0
        $envStatus.ScrollToCaret()
        if ($exitCode -eq 0) { $envStatus.BackColor = $greenSoft } else { $envStatus.BackColor = [System.Drawing.Color]::MistyRose }
    }
    catch {
        $message = Normalize-NativeOutputText $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($message)) { $message = 'An unknown error prevented the environment check from starting.' }
        $envStatus.Text = "ENVIRONMENT CHECK  FAILED`r`nRead type: $($script:AnalysisType)`r`nWSL distribution: $distro`r`n`r`n$message"
        $envStatus.BackColor = [System.Drawing.Color]::MistyRose
    }
    finally {
        if ($reportPath -and (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
            Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
        }
    }
}
$checkEnv.Add_Click({ Invoke-EnvironmentCheck })

function Save-ProjectAs {
    $config = New-ProjectConfig
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'RNA-seq project JSON (*.json)|*.json'
    $dialog.FileName = 'rnaseq_project.json'
    if ($dialog.ShowDialog() -eq 'OK') { Write-Config $config $dialog.FileName; Show-Info 'Project saved.' }
}
$saveButton.Add_Click({ Save-ProjectAs })

function Load-ProjectFile([string]$Path) {
    $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:AnalysisType = [string]$config.project.analysis_type
    foreach ($panel in @($shortCard, $longCard, $bothCard)) {
        $radio = [System.Windows.Forms.RadioButton]$panel.Tag
        $radio.Checked = ([string]$radio.Tag -eq $script:AnalysisType)
    }
    $projectName.Text = [string]$config.project.name
    $outputFolder.Text = [string]$config.project.output_dir
    $referenceFasta.Text = [string]$config.reference.fasta
    $annotationFile.Text = [string]$config.reference.annotation
    if ($config.project.threads) { $threadsBox.Value = [decimal]$config.project.threads }
    if ($null -ne $config.project.min_mapq) { $mapqBox.Value = [decimal]$config.project.min_mapq }
    if ($config.reference.feature_type) {
        $loadedFeatureType = ([string]$config.reference.feature_type).Trim()
        if ($loadedFeatureType -and -not $featureType.Items.Contains($loadedFeatureType)) {
            $customIndex = $featureType.Items.IndexOf('Custom...')
            if ($customIndex -lt 0) { [void]$featureType.Items.Add($loadedFeatureType) } else { $featureType.Items.Insert($customIndex, $loadedFeatureType) }
        }
        if ($loadedFeatureType) { $featureType.SelectedItem = $loadedFeatureType }
    }
    if ($config.reference.id_attribute) {
        $loadedIdAttribute = ([string]$config.reference.id_attribute).Trim()
        if ($loadedIdAttribute -and -not $idAttribute.Items.Contains($loadedIdAttribute)) {
            $customIndex = $idAttribute.Items.IndexOf('Custom...')
            if ($customIndex -lt 0) { [void]$idAttribute.Items.Add($loadedIdAttribute) } else { $idAttribute.Items.Insert($customIndex, $loadedIdAttribute) }
        }
        if ($loadedIdAttribute) { $idAttribute.SelectedItem = $loadedIdAttribute }
    }
    if ($config.library.short_strand) { $strandCombo.SelectedItem = [string]$config.library.short_strand }
    elseif ($config.library.strand) { $strandCombo.SelectedItem = [string]$config.library.strand }
    if ($config.library.long_strand) { $longStrandCombo.SelectedItem = [string]$config.library.long_strand }
    elseif ($config.library.strand) { $longStrandCombo.SelectedItem = [string]$config.library.strand }
    foreach ($name in $stageOrder) { if ($config.methods.$name) { Set-MethodValue $name ([string]$config.methods.$name) } }
    $adapterR1.Text = [string]$config.methods.adapter_r1
    $adapterR2.Text = [string]$config.methods.adapter_r2
    $script:Bowtie2Preset = 'sensitive'
    $script:Bowtie2Mode = 'end-to-end'
    foreach ($definition in $script:ToolArgumentDefinitions) { $script:AdvancedToolArguments[[string]$definition.Key] = '' }
    $script:AdvancedToolOptionValues = @{}
    if ($config.options) {
        $filterLong.Checked = [bool]$config.options.filter_long_reads
        if ($config.options.dorado_model) { $doradoModel.Text = [string]$config.options.dorado_model }
        if ($config.options.dorado_path) { $doradoPath.Text = [string]$config.options.dorado_path }
        if ($config.options.bowtie2_preset) { $script:Bowtie2Preset = [string]$config.options.bowtie2_preset }
        if ($config.options.bowtie2_mode) { $script:Bowtie2Mode = [string]$config.options.bowtie2_mode }
        $structuredProperty = $config.options.PSObject.Properties['tool_option_values']
        if ($null -ne $structuredProperty -and $null -ne $structuredProperty.Value) {
            $script:AdvancedToolOptionValues = Copy-ToolSelectionMap $structuredProperty.Value
        }
        # Legacy free-form tool arguments are intentionally ignored by the guided-only interface.
        foreach ($definition in $script:ToolArgumentDefinitions) { $script:AdvancedToolArguments[[string]$definition.Key] = '' }
    }
    $sampleGrid.Rows.Clear()
    foreach ($sample in @($config.samples)) {
        $index = $sampleGrid.Rows.Add()
        foreach ($name in @('include','sample_id','condition','replicate','batch','short_r1','short_r2','long_reads','pod5_dir','long_platform')) {
            if ($null -ne $sample.$name) {
                $cellValue = $sample.$name
                if ($name -eq 'long_platform') { $cellValue = Convert-ToLongPlatformCode ([string]$cellValue) }
                $sampleGrid.Rows[$index].Cells[$name].Value = $cellValue
            }
        }
    }
    Update-AnalysisVisibility
    Update-ConditionDesignSummary
    Update-Review
}

$loadButton.Add_Click({
    $path = Select-File 'RNA-seq project JSON (*.json)|*.json'
    if ($path) { try { Load-ProjectFile $path } catch { Show-Error ("Could not load project.`r`n`r`n" + $_.Exception.Message) } }
})
$helpButton.Add_Click({
    $guide = Join-Path $script:SuiteRoot 'Documentation\RNA-seq Processing Guide.html'
    if (Test-Path -LiteralPath $guide) { Start-Process $guide } else { Show-Error 'The RNA-seq processing guide is missing from the Documentation folder.' }
})

function Show-PostRnaSeqDestinationDialog {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'RNA-seq processing completed'
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(760, 390)
    $dialog.BackColor = $surface
    $dialog.Tag = 'stay'

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'RNA-seq processing completed successfully'
    $title.SetBounds(28, 22, 704, 34)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', [single]16, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $greenDark
    $dialog.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = 'Choose the next analysis step. Differential expression should be completed before GO/enrichment. Your analysis-ready export and pipeline log have already been saved.'
    $subtitle.SetBounds(30, 64, 700, 46)
    $subtitle.Font = New-Object System.Drawing.Font('Segoe UI', [single]10.25, [System.Drawing.FontStyle]::Regular)
    $subtitle.ForeColor = $ink
    $dialog.Controls.Add($subtitle)

    function Add-DestinationButton {
        param(
            [string]$Key,
            [string]$Title,
            [string]$Description,
            [int]$Top,
            [bool]$Primary = $false
        )
        $button = New-Button "$Title`r`n$Description" 30 $Top 700 72
        $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $button.Padding = New-Object System.Windows.Forms.Padding(16, 2, 12, 2)
        $button.Font = New-Object System.Drawing.Font('Segoe UI', [single]10, [System.Drawing.FontStyle]::Regular)
        if ($Primary) {
            $button.BackColor = $greenSoft
            $button.ForeColor = $greenDark
            $button.FlatAppearance.BorderColor = $green
            $button.FlatAppearance.BorderSize = 2
        }
        # Store the route on the real WinForms control.  A script-block closure
        # created inside this nested helper can lose the outer Form reference in
        # Windows PowerShell 5.1 and then attempt to set Tag on a non-Control
        # object.  Resolving the owner from the click sender is deterministic for
        # every destination card (DE, network, and stay).
        $button.Tag = $Key
        $button.Add_Click({
            param($sender, $eventArgs)
            $owner = ([System.Windows.Forms.Control]$sender).FindForm()
            if ($null -eq $owner) { return }
            $owner.Tag = [string]$sender.Tag
            $owner.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $owner.Close()
        })
        $dialog.Controls.Add($button)
        return $button
    }

    $deButton = Add-DestinationButton 'de' 'Differential expression' 'Recommended next step. Load the latest raw counts, sample metadata, and gene coordinates automatically.' 120 $true
    [void](Add-DestinationButton 'network' 'Functional enrichment and biological networks' 'Open the one-run GO, co-expression, KEGG, and STRING workspace. Complete Differential Expression first, or provide an existing DE result with normalized expression and metadata.' 200 $false)
    $stayButton = Add-DestinationButton 'stay' 'Stay in RNA-seq processing' 'Keep this completed project open to review the live console, workflow status, and output folder.' 280 $false

    $dialog.AcceptButton = $stayButton
    $dialog.CancelButton = $stayButton
    $stayButton.Select()
    [void]$dialog.ShowDialog($form)
    $choice = [string]$dialog.Tag
    $dialog.Dispose()
    return $choice
}

function Invoke-PostRnaSeqDestinationChoice {
    $choice = Show-PostRnaSeqDestinationDialog
    switch ($choice) {
        'de' { Open-EmbeddedDownstreamModule -Module 'de' -AutoLoadLatestRnaSeq }
        'network' { Open-EmbeddedDownstreamModule 'enrichment' }
        default { }
    }
}

function Start-Pipeline([switch]$DryRun) {
    if ($script:PipelineProcess -and -not $script:PipelineProcess.HasExited) { Show-Info 'A pipeline is already running.'; return }
    $config = New-ProjectConfig
    if (-not (Test-GuiConfig $config)) { return }
    $distro = Get-WslDistro
    if (-not $distro) { Show-Error 'No runnable WSL Linux distribution was found. Use Install or repair core on page 2.'; return }
    $sampleStats = Get-IncludedSampleStatistics $config
    $script:ActiveRunSummary = [pscustomobject]@{
        Project = [string]$config.project.name
        ReadType = [string]$config.project.analysis_type
        BiologicalSamples = [int]$sampleStats.BiologicalSamples
        InputRows = [int]$sampleStats.InputRows
        DryRun = [bool]$DryRun
    }
    $script:RunCompletionRecorded = $false
    $script:PostProcessingChoiceShown = $false
    try {
        [void][System.IO.Directory]::CreateDirectory([string]$config.project.output_dir)
        $logFolder = Join-Path ([string]$config.project.output_dir) '00_project\logs'
        [void][System.IO.Directory]::CreateDirectory($logFolder)
        # Keep this as a real collection under Set-StrictMode. PowerShell
        # otherwise unwraps a one-item pipeline result to a scalar String, and
        # `$previousLogs.Count` then raises "The property 'Count' cannot be found".
        # That prevented a new run whenever exactly one old log file existed.
        $previousLogs = New-Object System.Collections.Generic.List[string]
        foreach ($logName in @(
            'pipeline.log',
            'windows_pipeline_launcher.log',
            'commands.sh',
            'command_plan.json'
        )) {
            $candidateLog = Join-Path $logFolder $logName
            if (Test-Path -LiteralPath $candidateLog -PathType Leaf) {
                [void]$previousLogs.Add([string]$candidateLog)
            }
        }
        if ($previousLogs.Count -gt 0) {
            $archiveFolder = Join-Path $logFolder ('Previous run ' + [DateTime]::Now.ToString('yyyyMMdd HHmmss fff'))
            [void][System.IO.Directory]::CreateDirectory($archiveFolder)
            foreach ($previousLog in $previousLogs) {
                Move-Item -LiteralPath $previousLog -Destination (Join-Path $archiveFolder (Split-Path -Leaf $previousLog)) -Force
            }
        }
        $bootstrapLog = Join-Path $logFolder 'pipeline.log'
        [System.IO.File]::AppendAllText(
            $bootstrapLog,
            "`r`n[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] GUI requested a new RNA-seq processing run.`r`n",
            (New-Object System.Text.UTF8Encoding($false))
        )
        $stateFile = Join-Path ([string]$config.project.output_dir) '.rnaseq_suite\state.json'
        if (Test-Path -LiteralPath $stateFile -PathType Leaf) { Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue }
        $configPath = Join-Path ([string]$config.project.output_dir) 'rnaseq_project.json'
        Write-Config $config $configPath
        $linuxApp = Convert-ToWslPath $script:AppRoot $distro
        $linuxConfig = Convert-ToWslPath $configPath $distro

        # Launch through a dedicated Windows-side runner. PowerShell 5.1 and
        # ProcessStartInfo.Arguments can silently corrupt quoted WSL arguments
        # when the application/configuration paths contain spaces. The request
        # file keeps every value separate, and the runner invokes wsl.exe with
        # native argument splatting so the Linux command receives exact paths.
        $stateDirectory = Join-Path ([string]$config.project.output_dir) '.rnaseq_suite'
        [void][System.IO.Directory]::CreateDirectory($stateDirectory)
        $launcherLog = Join-Path $logFolder 'windows_pipeline_launcher.log'
        $requestPath = Join-Path $stateDirectory 'windows_pipeline_request.json'
        $runnerPath = Join-Path $script:AppRoot 'environment\run_pipeline_windows.ps1'
        if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
            throw "The Windows pipeline runner is missing: $runnerPath"
        }
        $script:PipelineJobToken = [Guid]::NewGuid().ToString('N')
        $script:PipelineDistro = [string]$distro
        $script:PipelineLinuxPidFile = "/tmp/bra_job_$($script:PipelineJobToken).pid"
        $runnerRequest = [ordered]@{
            distro = [string]$distro
            linux_supervisor = "$linuxApp/environment/run_supervised_job.sh"
            job_token = [string]$script:PipelineJobToken
            linux_script = "$linuxApp/environment/run_in_environment.sh"
            linux_config = [string]$linuxConfig
            dry_run = [bool]$DryRun
            pipeline_log = [string]$bootstrapLog
            launcher_log = [string]$launcherLog
        }
        [System.IO.File]::WriteAllText(
            $requestPath,
            ($runnerRequest | ConvertTo-Json -Depth 4),
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::AppendAllText(
            $bootstrapLog,
            "WSL distribution: $distro`r`nLinux runner: $linuxApp/environment/run_in_environment.sh`r`nLinux config: $linuxConfig`r`nWindows launcher log: $launcherLog`r`n",
            (New-Object System.Text.UTF8Encoding($false))
        )

        $escapedRunner = $runnerPath.Replace("'", "''")
        $escapedRequest = $requestPath.Replace("'", "''")
        $encodedText = "& '$escapedRunner' -RequestPath '$escapedRequest'"
        $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($encodedText))
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
        $start.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
        $start.WorkingDirectory = $script:SuiteRoot
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $script:PipelineProcess = New-Object System.Diagnostics.Process
        $script:PipelineProcess.StartInfo = $start
        if (-not $script:PipelineProcess.Start()) { throw 'The Windows pipeline runner could not start.' }
        $script:RunOutput = [string]$config.project.output_dir
        $script:CurrentConfigPath = $configPath
        $script:LastLogLength = 0
        $runLog.Clear()
        $progress.Value = 0
        Initialize-RunStepGrid
        $runStepStatus.Text = 'Preparing the workflow step list...'
        $runStatus.Text = $(if ($DryRun) { 'Creating command plan...' } else { 'Pipeline started...' })
        $runButton.Enabled = $false; $dryRunButton.Enabled = $false; $stopButton.Enabled = $true; $openOutput.Enabled = $false; $resetProjectButton.Enabled = $false
        $openRunLogFileButton.Enabled = $true; $openRunLogFolderButton.Enabled = $true
        $nextButton.Text = 'Running...'
        $nextButton.Enabled = $false
        $runTimer.Start()
    }
    catch {
        $resetProjectButton.Enabled = $true
        $script:ActiveRunSummary = $null
        $nextButton.Text = 'Run analysis'
        $nextButton.Enabled = $true
        $currentLogPath = Get-RnaSeqPipelineLogPath
        $openRunLogFileButton.Enabled = [bool]($currentLogPath -and (Test-Path -LiteralPath $currentLogPath -PathType Leaf))
        $openRunLogFolderButton.Enabled = -not [string]::IsNullOrWhiteSpace([string]$script:RunOutput)
        Show-Error ("Could not start pipeline.`r`n`r`n" + $_.Exception.Message)
    }
}
$runButton.Add_Click({ Start-Pipeline })
$dryRunButton.Add_Click({ Start-Pipeline -DryRun })
$resetProjectButton.Add_Click({
    if ($script:PipelineProcess -and -not $script:PipelineProcess.HasExited) {
        Show-Info 'The pipeline is still running. Stop it safely before resetting the project.'
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $form,
        'Clear the current project and return to Read type? The verified package environment and completed-session sample totals will be kept.',
        'Reset RNA-seq project',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { Reset-RnaSeqProject }
})
function Stop-RnaSeqManagedProcessTree {
    if (-not $script:PipelineProcess -or $script:PipelineProcess.HasExited) { return $true }
    if ($script:PipelineDistro -and $script:PipelineJobToken) {
        try {
            $stopScriptWindows = Join-Path $script:AppRoot 'environment\stop_supervised_job.sh'
            $stopScriptWsl = Convert-ToWslPath $stopScriptWindows $script:PipelineDistro
            $savedPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { & wsl.exe -d $script:PipelineDistro -u root -- /bin/bash $stopScriptWsl $script:PipelineJobToken 2>&1 | Out-Null } finally { $ErrorActionPreference = $savedPreference }
        } catch { }
    }
    try {
        for ($i = 0; $i -lt 50 -and $script:PipelineProcess -and -not $script:PipelineProcess.HasExited; $i++) {
            Start-Sleep -Milliseconds 100
            [System.Windows.Forms.Application]::DoEvents()
        }
    } catch { }
    if ($script:PipelineProcess -and -not $script:PipelineProcess.HasExited) {
        try { & taskkill.exe /PID $script:PipelineProcess.Id /T /F 2>$null | Out-Null } catch { }
        try { $script:PipelineProcess.WaitForExit(3000) | Out-Null } catch { }
    }
    return (-not $script:PipelineProcess -or $script:PipelineProcess.HasExited)
}

function Request-RnaSeqSafeStop {
    if (-not $script:RunOutput) { return $false }
    try {
        $stopDir = Join-Path $script:RunOutput '.rnaseq_suite'
        [void][System.IO.Directory]::CreateDirectory($stopDir)
        [System.IO.File]::WriteAllText((Join-Path $stopDir 'STOP_REQUESTED'), 'Stop requested from GUI.')
        $runStatus.Text = 'Safe stop requested. Stopping the complete Linux process tree and preserving completed checkpoints...'
        $stopButton.Enabled = $false
        [System.Windows.Forms.Application]::DoEvents()
        $stopped = Stop-RnaSeqManagedProcessTree
        if ($stopped) {
            $runStatus.Text = 'Pipeline stopped safely. No managed Linux analysis process remains.'
            return $true
        }
        $runStatus.Text = 'Stop was requested, but the Windows launcher is still exiting. Please wait before closing or deleting the result folder.'
        return $false
    }
    catch { Show-Error $_.Exception.Message; return $false }
}
$stopButton.Add_Click({
    [void](Request-RnaSeqSafeStop)
})
$openOutput.Add_Click({
    if (-not $script:RunOutput) { return }
    $publishedWorkbook = Join-Path $script:RunOutput 'Counts & Annotation.xlsx'
    if (Test-Path -LiteralPath $publishedWorkbook -PathType Leaf) {
        Start-Process explorer.exe $script:RunOutput
        return
    }
    $ready = Join-Path $script:RunOutput 'analysis_ready'
    if (Test-Path -LiteralPath $ready -PathType Container) { Start-Process explorer.exe $ready }
})

$runTimer = New-Object System.Windows.Forms.Timer
$runTimer.Interval = 900
$runTimer.Add_Tick({
    if (-not $script:RunOutput) { return }
    $statePath = Join-Path $script:RunOutput '.rnaseq_suite\state.json'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $progress.Value = [Math]::Max(0, [Math]::Min(100, [int]$state.percent))
            $runStatus.Text = [string]$state.message
            if ($state.PSObject.Properties.Name -contains 'step_total' -and [int]$state.step_total -gt 0) {
                $stageName = ([string]$state.stage -replace '_', ' ')
                $runStepStatus.Text = "Step $([int]$state.step_current) of $([int]$state.step_total) | $([int]$state.steps_remaining) remaining | $stageName"
                Update-RunStepGrid ([int]$state.step_current) ([int]$state.step_total) ([string]$state.status)
            }
        }
        catch { }
    }
    $logPath = Get-RnaSeqPipelineLogPath
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        try {
            $info = Get-Item -LiteralPath $logPath
            if ($info.Length -ne $script:LastLogLength) {
                $text = Read-RnaSeqLogTail $logPath
                $runLog.Text = $text
                $runLog.SelectionStart = $runLog.TextLength
                $runLog.ScrollToCaret()
                $script:LastLogLength = $info.Length
            }
        }
        catch { }
    }
    if ($script:PipelineProcess -and $script:PipelineProcess.HasExited) {
        $exitCode = $script:PipelineProcess.ExitCode
        $runTimer.Stop()
        $runButton.Enabled = $true; $dryRunButton.Enabled = $true; $stopButton.Enabled = $false; $resetProjectButton.Enabled = $true
        $nextButton.Text = 'Run analysis'
        $nextButton.Enabled = $true
        $openRunLogFileButton.Enabled = [bool](Test-Path -LiteralPath (Get-RnaSeqPipelineLogPath) -PathType Leaf)
        $openRunLogFolderButton.Enabled = $true
        $publishedWorkbook = Join-Path $script:RunOutput 'Counts & Annotation.xlsx'
        $ready = Join-Path $script:RunOutput 'analysis_ready'
        $publishedRootReady = Test-Path -LiteralPath $publishedWorkbook -PathType Leaf
        $openOutput.Enabled = $publishedRootReady -or (Test-Path -LiteralPath $ready -PathType Container)
        if ($exitCode -eq 0) {
            $progress.Value = 100
            $runStepStatus.Text = 'All workflow steps completed | 0 remaining'
            $runStatus.Text = 'RNA-seq processing completed. Final results were published to the selected Results folder.'
            Update-RunStepGrid $script:CurrentRunTotal $script:CurrentRunTotal 'complete'
            if ($publishedRootReady) { Save-LatestRnaSeqAnalysisReady $script:RunOutput }
            elseif (Test-Path -LiteralPath $ready -PathType Container) { Save-LatestRnaSeqAnalysisReady $ready }
            Register-CompletedRun
            if (-not [bool]$script:ActiveRunSummary.DryRun -and -not $script:PostProcessingChoiceShown) {
                $script:PostProcessingChoiceShown = $true
                Invoke-PostRnaSeqDestinationChoice
            }
        }
        elseif ($exitCode -eq 130) {
            $runStatus.Text = 'Pipeline stopped safely. Completed checkpoints were preserved.'
            Update-RunStepGrid ([Math]::Max(1, $script:CurrentRunStep)) $script:CurrentRunTotal 'stopped'
        }
        else {
            $runStatus.Text = "Pipeline stopped with exit code $exitCode. The pipeline and Windows launcher details are in the log folder."
            Update-RunStepGrid ([Math]::Max(1, $script:CurrentRunStep)) $script:CurrentRunTotal 'error'
        }
    }
})

$tabs.Add_Selecting({
    param($sender, $eventArgs)
    if (-not $script:AllowForwardTabNavigation -and $eventArgs.TabPageIndex -gt $script:MaxUnlockedStep) {
        $eventArgs.Cancel = $true
    }
})
$tabs.Add_SelectedIndexChanged({
    $backButton.Enabled = $true
    if ($tabs.SelectedTab -eq $pageRun) {
        $nextButton.Text = $(if ($script:PipelineProcess -and -not $script:PipelineProcess.HasExited) { 'Running...' } else { 'Run analysis' })
        $nextButton.Enabled = -not ($script:PipelineProcess -and -not $script:PipelineProcess.HasExited)
        Update-Review
    }
    else {
        $nextButton.Text = 'Next'
        $nextButton.Enabled = $tabs.SelectedIndex -lt ($tabs.TabPages.Count - 1)
    }
    $tabs.Invalidate()
})
$backButton.Add_Click({
    if ($tabs.SelectedIndex -gt 0) { $tabs.SelectedIndex-- }
    else { Show-HomeScreen }
})
$nextButton.Add_Click({
    if ($tabs.SelectedTab -eq $pageRun) { Start-Pipeline; return }
    if ($tabs.SelectedTab -eq $pageType -and -not $script:AnalysisType) { Show-Error 'Choose Short reads, Long reads, or Both before continuing.'; return }
    if ($tabs.SelectedIndex -lt ($tabs.TabPages.Count - 1)) {
        $targetStep = $tabs.SelectedIndex + 1
        if ($targetStep -gt $script:MaxUnlockedStep) {
            $script:MaxUnlockedStep = $targetStep
            $tabs.Invalidate()
        }
        $script:AllowForwardTabNavigation = $true
        try { $tabs.SelectedIndex = $targetStep }
        finally { $script:AllowForwardTabNavigation = $false }
    }
})
$backButton.Enabled = $true

$form.Add_FormClosing({
    param($sender, $eventArgs)

    # Use the event sender rather than the variable named $form. Embedded
    # rSeqTU and OpDetect scripts also define $form, and Windows PowerShell 5.1
    # can execute this callback while their script scope is current.
    $mainState = $sender.Tag
    if (-not $mainState) { return }
    $mainState.MainSuiteClosing = $true

    if ($mainState.EmbeddedModuleActive -and $mainState.ModuleOverlay) {
        foreach ($embeddedControl in @($mainState.ModuleOverlay.Controls)) {
            if ($embeddedControl -is [System.Windows.Forms.Form] -and -not $embeddedControl.IsDisposed) {
                try { $embeddedControl.Close() } catch { }
                if (-not $embeddedControl.IsDisposed -and $embeddedControl.Visible) {
                    # The embedded module refused to close, normally because a
                    # running job still needs confirmation from the user.
                    $eventArgs.Cancel = $true
                    $mainState.MainSuiteClosing = $false
                    return
                }
            }
        }
    }

    $standaloneActive = $false
    try {
        $standaloneActive = [bool](Get-Variable -Name StandaloneAnalysisActive -Scope Script -ValueOnly -ErrorAction Stop)
    } catch { }
    if ($standaloneActive) {
        Close-StandaloneAnalysisForSuiteExit
    }

    $pipelineProcessForClose = $null
    try {
        $pipelineProcessForClose = Get-Variable -Name PipelineProcess -Scope Script -ValueOnly -ErrorAction Stop
    } catch { }
    if ($pipelineProcessForClose -and -not $pipelineProcessForClose.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $sender,
            "The pipeline is still running.`r`n`r`nYes = stop the complete Linux analysis process tree, wait for it to exit, then close the GUI.`r`n`r`nNo = close the GUI and leave the Linux pipeline running.`r`n`r`nCancel = keep this window open.",
            'Pipeline still running',
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            if (-not (Request-RnaSeqSafeStop)) {
                $eventArgs.Cancel = $true
                $mainState.MainSuiteClosing = $false
            }
        }
        elseif ($answer -eq [System.Windows.Forms.DialogResult]::Cancel) {
            $eventArgs.Cancel = $true
            $mainState.MainSuiteClosing = $false
        }
    }
})

# One starter row. No read type is preselected so page 1 remains an explicit decision.
# Defer expensive nested layout until the interface state has been initialized.
# The previous sequence performed several full layout passes before the final
# PerformLayout call, which made the EXE feel slower as the suite grew.
$tabs.ResumeLayout($false)
$rootLayout.ResumeLayout($false)
$form.ResumeLayout($false)
$starter = $sampleGrid.Rows.Add()
$sampleGrid.Rows[$starter].Cells['include'].Value = $true
$sampleGrid.Rows[$starter].Cells['replicate'].Value = '1'
Update-ConditionDesignSummary
Update-AnalysisVisibility
Update-ModeSelectionDisplay
Update-RequiredInputInstructions
Show-HomeScreen
$form.PerformLayout()
try { Add-Content -LiteralPath $script:StartupLog -Value ("[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] GUI controls initialized") -Encoding UTF8 } catch { }

$form.Add_Shown({
    try {
        if ($script:StartupSplash) {
            $script:StartupSplash.Close()
            $script:StartupSplash.Dispose()
            $script:StartupSplash = $null
        }
    } catch { }
    try {
        [System.IO.File]::WriteAllText($script:VisibilityMarker, "Visible $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))")
    }
    catch { }
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
    $form.BringToFront()
    # Prevent Windows from displaying the initial 'auto' values as selected
    # blue edit text. These ComboBoxes remain editable for custom GFF/GTF fields.
    foreach ($editableCombo in @($featureType, $idAttribute)) {
        try {
            $editableCombo.SelectionStart = $editableCombo.Text.Length
            $editableCombo.SelectionLength = 0
            if ($editableCombo.IsHandleCreated -and -not $editableCombo.IsDisposed) {
                $comboRef = $editableCombo
                $collapseInitialSelection = [System.Windows.Forms.MethodInvoker]{
                    try {
                        $comboRef.SelectionStart = $comboRef.Text.Length
                        $comboRef.SelectionLength = 0
                    } catch { }
                }.GetNewClosure()
                [void]$editableCombo.BeginInvoke($collapseInitialSelection)
            }
        } catch { }
    }
})

Apply-NeutralSelectionTheme $form
[System.Windows.Forms.Application]::Run($form)
try { Add-Content -LiteralPath $script:StartupLog -Value "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] GUI closed normally" -Encoding UTF8 } catch { }
}
catch {
    $details = @(
        "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] GUI startup failed"
        $_.Exception.ToString()
        ($_ | Out-String)
        ($_.ScriptStackTrace | Out-String)
    ) -join "`r`n"
    try { Add-Content -LiteralPath $script:StartupLog -Value $details -Encoding UTF8 } catch { }
    try {
        if ($script:StartupSplash) {
            $script:StartupSplash.Close()
            $script:StartupSplash.Dispose()
            $script:StartupSplash = $null
        }
    } catch { }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [void][System.Windows.Forms.MessageBox]::Show(
            "The GUI could not start.`r`n`r`n$($_.Exception.Message)`r`n`r`nDiagnostic log:`r`n$script:StartupLog",
            'Bacterial RNA Analysis startup error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
    catch { }
    exit 1
}
