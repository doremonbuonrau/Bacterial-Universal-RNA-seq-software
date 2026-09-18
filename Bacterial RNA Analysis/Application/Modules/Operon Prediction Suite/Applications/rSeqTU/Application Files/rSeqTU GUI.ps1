# rSeqTU Transcription Unit Predictor
# Advanced white-mode Windows desktop interface

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('RSeqTUNative' -as [type])) {
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class RSeqTUNative
{
    public const int EM_SETCUEBANNER = 0x1501;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(
        IntPtr hWnd,
        int msg,
        IntPtr wParam,
        string lParam
    );
}
"@
}

[System.Windows.Forms.Application]::EnableVisualStyles()

# =============================================================================
# APPLICATION STATE
# =============================================================================

$script:AppDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RootDirectory = Split-Path -Parent $script:AppDirectory
$script:BackendScript = Join-Path $script:AppDirectory "rSeqTU backend.R"

$script:RscriptPath = $null
$script:RunningProcess = $null
$script:RunConfig = $null
$script:RunLog = $null
$script:RunErrorLog = $null
$script:FullConsoleLogPath = $null
$script:RunWrapperScript = $null
$script:RunStartedAt = $null
$script:StatusFile = $null
$script:StopRequested = $false
$script:OutputSnapshot = @{}
$script:BaiSnapshot = @{}
$script:CurrentPercent = 0
$script:CurrentWorkflowStep = 1
$script:BackendState = "NotStarted"
$script:BackendMessage = ""
$script:WorkflowItems = @{}
$script:SessionRuns = @()
$script:CurrentRunSample = $null
$script:CurrentRunBamPath = $null
$script:CurrentRunRecorded = $false
$script:SuiteManaged = $false
$script:SuiteSignalTimer = $null
$script:SuiteShutdownRequested = $false
$script:EmbeddedHost = $null
try {
    $script:EmbeddedHost = Get-Variable -Name BacterialRNAAnalysisEmbeddedHost -Scope Global -ValueOnly -ErrorAction Stop
}
catch { }
$script:EmbeddedMode = $null -ne $script:EmbeddedHost

function Get-SuiteSessionDirectory {
    param([string]$Root)

    $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/')).ToLowerInvariant()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalizedRoot))
    }
    finally {
        $sha256.Dispose()
    }

    $suiteKey = ([System.BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 16)
    $sessionBase = Join-Path $env:LOCALAPPDATA 'Operon Prediction Suite\Session'
    return Join-Path $sessionBase $suiteKey
}

function Initialize-SuiteIntegration {
    $script:SuiteRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $script:SuiteLauncherPath = Join-Path $script:SuiteRoot 'Operon Prediction Suite.exe'
    $script:SuiteManaged = Test-Path -LiteralPath $script:SuiteLauncherPath -PathType Leaf

    if (-not $script:SuiteManaged) {
        return
    }

    $script:SuiteSessionDirectory = Get-SuiteSessionDirectory -Root $script:SuiteRoot
    [void][System.IO.Directory]::CreateDirectory($script:SuiteSessionDirectory)
    $script:SuiteMarkerPath = Join-Path $script:SuiteSessionDirectory 'rSeqTU.json'
    $script:SuiteShowSignalPath = Join-Path $script:SuiteSessionDirectory 'rSeqTU.show'
    $script:SuiteHideSignalPath = Join-Path $script:SuiteSessionDirectory 'rSeqTU.hide'
    $script:SuiteShutdownSignalPath = Join-Path $script:SuiteSessionDirectory 'rSeqTU.shutdown'
}

function Write-SuiteApplicationMarker {
    param([bool]$Hidden)

    if (-not $script:SuiteManaged) {
        return
    }

    $currentProcess = Get-Process -Id $PID -ErrorAction Stop
    $metadata = [ordered]@{
        App = 'rSeqTU'
        ProcessId = $PID
        StartTimeUtcTicks = [string]$currentProcess.StartTime.ToUniversalTime().Ticks
        SuiteRoot = $script:SuiteRoot
        Hidden = $Hidden
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($script:SuiteMarkerPath, ($metadata | ConvertTo-Json -Compress), $encoding)
}

function Remove-SuiteApplicationArtifacts {
    if (-not $script:SuiteManaged) {
        return
    }

    foreach ($path in @($script:SuiteMarkerPath, $script:SuiteShowSignalPath, $script:SuiteHideSignalPath, $script:SuiteShutdownSignalPath)) {
        try {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                [System.IO.File]::Delete($path)
            }
        }
        catch { }
    }
}

function Return-ToPredictionSuite {
    if ($script:RunningProcess -and -not $script:RunningProcess.HasExited) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            'rSeqTU is still running. Stop the pipeline and wait for it to finish stopping before returning to the Prediction Suite.',
            'rSeqTU is running',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    try {
        if ($script:EmbeddedMode) {
            $form.Hide()
            return
        }
        if (-not $script:SuiteManaged) {
            throw 'Operon Prediction Suite.exe was not found. This button is available in the complete extracted Prediction Suite.'
        }

        Write-SuiteApplicationMarker -Hidden $true

        try {
            Start-Process -FilePath $script:SuiteLauncherPath -WorkingDirectory $script:SuiteRoot | Out-Null
        }
        catch {
            Write-SuiteApplicationMarker -Hidden $false
            $form.ShowInTaskbar = $true
            $form.Show()
            $form.Activate()
            throw
        }
    }
    catch {
        $lineBreak = [Environment]::NewLine
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            ('Windows could not return to the Prediction Suite.' + $lineBreak + $lineBreak + $_.Exception.Message),
            'Cannot open Prediction Suite',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}


function Return-ToAnalysisModules {
    if ($script:RunningProcess -and -not $script:RunningProcess.HasExited) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            'rSeqTU is still running. Stop the pipeline before returning to the analysis modules.',
            'rSeqTU is running',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }
    if ($script:EmbeddedMode) {
        $global:BacterialRNAAnalysisReturnTarget = 'home'
        $form.Hide()
        return
    }
    [System.Windows.Forms.MessageBox]::Show(
        $form,
        'Open rSeqTU from Bacterial RNA Analysis to use the direct analysis-module return button.',
        'Analysis modules',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Start-SuiteSignalMonitor {
    if (-not $script:SuiteManaged) {
        return
    }

    $script:SuiteSignalTimer = New-Object System.Windows.Forms.Timer
    $script:SuiteSignalTimer.Interval = 100
    $script:SuiteSignalTimer.Add_Tick({
        if (Test-Path -LiteralPath $script:SuiteShutdownSignalPath -PathType Leaf) {
            try { [System.IO.File]::Delete($script:SuiteShutdownSignalPath) } catch { }
            $script:SuiteShutdownRequested = $true
            $form.Close()
            return
        }

        if (Test-Path -LiteralPath $script:SuiteHideSignalPath -PathType Leaf) {
            $form.ShowInTaskbar = $false
            $form.Hide()
            try { [System.IO.File]::Delete($script:SuiteHideSignalPath) } catch { }
            return
        }

        if (Test-Path -LiteralPath $script:SuiteShowSignalPath -PathType Leaf) {
            try { [System.IO.File]::Delete($script:SuiteShowSignalPath) } catch { }
            Write-SuiteApplicationMarker -Hidden $false
            $form.ShowInTaskbar = $true
            $form.Show()
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $form.TopMost = $true
            $form.Activate()
            $form.BringToFront()
            $form.TopMost = $false
        }
    })
    $script:SuiteSignalTimer.Start()
}

Initialize-SuiteIntegration

# =============================================================================
# WHITE THEME
# =============================================================================

function Get-ThemeColor {
    param([string]$Hex)

    [System.Drawing.ColorTranslator]::FromHtml($Hex)
}

$ColorWindow       = Get-ThemeColor "#F3F6F9"
$ColorHeader       = Get-ThemeColor "#FFFFFF"
$ColorSidebar      = Get-ThemeColor "#F8FAFC"
$ColorWorkspace    = Get-ThemeColor "#EEF2F6"
$ColorPanel        = Get-ThemeColor "#FFFFFF"
$ColorPanelAlt     = Get-ThemeColor "#F4F7FA"
$ColorBorder       = Get-ThemeColor "#D6DDE5"
$ColorGrid         = Get-ThemeColor "#E4EAF0"
$ColorAccent       = Get-ThemeColor "#2F80ED"
$ColorAccentHover  = Get-ThemeColor "#4A92F0"
$ColorSuccess      = Get-ThemeColor "#2FA866"
$ColorWarning      = Get-ThemeColor "#D89A28"
$ColorError        = Get-ThemeColor "#D84A4A"
$ColorText         = Get-ThemeColor "#1F2937"
$ColorTextMuted    = Get-ThemeColor "#5F6B7A"
$ColorTextDim      = Get-ThemeColor "#8793A1"
$ColorInput        = Get-ThemeColor "#FFFFFF"
$ColorProgressBack = Get-ThemeColor "#E7ECEF"


$ColorNeutralSelection = Get-ThemeColor "#EAF2EC"

function Enable-NeutralListBox {
    param([System.Windows.Forms.ListBox]$List)
    if (-not $List) { return }
    if ($List.DrawMode -ne [System.Windows.Forms.DrawMode]::OwnerDrawFixed) {
        $List.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
        $List.ItemHeight = 22
        $List.BackColor = $ColorInput
        $List.ForeColor = $ColorText
        $List.Add_DrawItem({
            param($sender, $e)
            if ($e.Index -lt 0) { return }
            $selected = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
            $back = if ($selected) { $ColorNeutralSelection } else { $ColorInput }
            $brush = New-Object System.Drawing.SolidBrush($back)
            try { $e.Graphics.FillRectangle($brush, $e.Bounds) } finally { $brush.Dispose() }
            $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$sender.Items[$e.Index], $sender.Font, $e.Bounds, $ColorText, $back, $flags)
        })
    }
}

function Apply-NeutralSelectionTheme {
    param([System.Windows.Forms.Control]$RootControl)
    if (-not $RootControl) { return }
    if ($RootControl -is [System.Windows.Forms.ListBox]) { Enable-NeutralListBox ([System.Windows.Forms.ListBox]$RootControl) }
    foreach ($child in $RootControl.Controls) { Apply-NeutralSelectionTheme $child }
}

$FontUI = New-Object System.Drawing.Font("Segoe UI", 9)
$FontSmall = New-Object System.Drawing.Font("Segoe UI", 8)
$FontMedium = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$FontSection = New-Object System.Drawing.Font("Segoe UI Semibold", 11)
$FontTitle = New-Object System.Drawing.Font("Segoe UI Semibold", 16)
$FontMono = New-Object System.Drawing.Font("Consolas", 9)

function Set-LightTextBox {
    param([System.Windows.Forms.TextBox]$TextBox)

    $TextBox.BackColor = $ColorInput
    $TextBox.ForeColor = $ColorText
    $TextBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $TextBox.Font = $FontUI
}

function Set-FlatButton {
    param(
        [System.Windows.Forms.Button]$Button,
        [System.Drawing.Color]$Background = $ColorPanelAlt,
        [System.Drawing.Color]$Foreground = $ColorText
    )

    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 1
    $Button.FlatAppearance.BorderColor = $ColorBorder
    $Button.FlatAppearance.MouseOverBackColor = $ColorAccentHover
    $Button.FlatAppearance.MouseDownBackColor = $ColorAccent
    $Button.BackColor = $Background
    $Button.ForeColor = $Foreground
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.Font = $FontUI
}

function New-SectionTitle {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, 25)
    $label.Font = $FontSection
    $label.ForeColor = $ColorText
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label
}

# =============================================================================
# R DETECTION AND INSTALLATION
# =============================================================================

function Find-Rscript {
    $candidates = New-Object System.Collections.Generic.List[string]

    try {
        $command = Get-Command Rscript.exe -ErrorAction Stop

        if ($command.Source) {
            $candidates.Add($command.Source)
        }
    } catch {}

    $registryPaths = @(
        "HKLM:\SOFTWARE\R-core\R",
        "HKCU:\SOFTWARE\R-core\R",
        "HKLM:\SOFTWARE\WOW6432Node\R-core\R"
    )

    foreach ($registryPath in $registryPaths) {
        try {
            $installPath = (
                Get-ItemProperty `
                    -Path $registryPath `
                    -ErrorAction Stop
            ).InstallPath

            if ($installPath) {
                $candidates.Add(
                    (Join-Path $installPath "bin\Rscript.exe")
                )

                $candidates.Add(
                    (Join-Path $installPath "bin\x64\Rscript.exe")
                )
            }
        } catch {}
    }

    $searchRoots = @(
        (Join-Path $env:ProgramFiles "R"),
        (Join-Path $env:LOCALAPPDATA "Programs\R")
    )

    foreach ($root in $searchRoots) {
        if (Test-Path $root) {
            Get-ChildItem `
                -Path $root `
                -Directory `
                -Filter "R-*" `
                -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object {
                    $candidates.Add(
                        (Join-Path $_.FullName "bin\Rscript.exe")
                    )

                    $candidates.Add(
                        (Join-Path $_.FullName "bin\x64\Rscript.exe")
                    )
                }
        }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path $candidate)) {
            return (Resolve-Path $candidate).Path
        }
    }

    $null
}

function Update-RStatus {
    $script:RscriptPath = Find-Rscript

    if ($script:RscriptPath) {
        $rStatusDot.ForeColor = $ColorSuccess
        $rStatusLabel.Text = "R detected"
        $rPathLabel.Text = $script:RscriptPath
        $rPathLabel.ForeColor = $ColorTextMuted
        $headerEnvironmentLabel.Text = "Environment ready"
        $headerEnvironmentLabel.ForeColor = $ColorSuccess
        $installRButton.Enabled = $false
        return $true
    }

    $rStatusDot.ForeColor = $ColorError
    $rStatusLabel.Text = "R is not installed"
    $rPathLabel.Text = "Install R before running the pipeline."
    $rPathLabel.ForeColor = $ColorTextMuted
    $headerEnvironmentLabel.Text = "R required"
    $headerEnvironmentLabel.ForeColor = $ColorError
    $installRButton.Enabled = $true
    $false
}

function Install-R {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $form,
        "R was not detected.`r`n`r`nDownload the official Windows installer from CRAN and start installation?",
        "Install R",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {
        $installRButton.Enabled = $false
        $runButton.Enabled = $false
        $rPathLabel.Text = "Downloading the official R installer..."
        $rPathLabel.ForeColor = $ColorWarning
        [System.Windows.Forms.Application]::DoEvents()

        $installer = Join-Path $env:TEMP "R-current-win.exe"
        $downloadUrl = "https://cran.r-project.org/bin/windows/base/release.html"

        Invoke-WebRequest `
            -Uri $downloadUrl `
            -OutFile $installer `
            -UseBasicParsing `
            -ErrorAction Stop

        if (-not (Test-Path $installer)) {
            throw "The R installer was not downloaded."
        }

        $rPathLabel.Text = "Complete the R installation wizard."
        $rPathLabel.ForeColor = $ColorWarning
        [System.Windows.Forms.Application]::DoEvents()

        Start-Process `
            -FilePath $installer `
            -ArgumentList "/CURRENTUSER" `
            -Wait

        Update-RStatus | Out-Null

        if (-not $script:RscriptPath) {
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "R is still not detected. Finish the installer, then click Check R.",
                "R not detected",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Could not download or start the R installer.`r`n`r`n$($_.Exception.Message)",
            "R installation error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    } finally {
        $runButton.Enabled = $true
        Update-RStatus | Out-Null
    }
}

# =============================================================================
# FILE SELECTION AND VALIDATION
# =============================================================================

function Select-InputFile {
    param(
        [string]$Filter,
        [System.Windows.Forms.TextBox]$Target
    )

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = $Filter
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false
    $dialog.Title = "Select input file"

    if ($Target.Text -and (Test-Path $Target.Text)) {
        $dialog.InitialDirectory = Split-Path -Parent $Target.Text
    }

    if (
        $dialog.ShowDialog($form) -eq
        [System.Windows.Forms.DialogResult]::OK
    ) {
        $Target.Text = $dialog.FileName
    }
}

function Select-OutputFolder {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Choose the folder for rSeqTU results"
    $dialog.ShowNewFolderButton = $true

    if ($outputTextBox.Text -and (Test-Path $outputTextBox.Text)) {
        $dialog.SelectedPath = $outputTextBox.Text
    }

    if (
        $dialog.ShowDialog($form) -eq
        [System.Windows.Forms.DialogResult]::OK
    ) {
        $outputTextBox.Text = $dialog.SelectedPath
    }
}

function Open-ResultFolder {
    param(
        [System.Windows.Forms.Button]$SourceButton = $null
    )

    $folderPath = $outputTextBox.Text.Trim()

    if (-not $folderPath) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Select a result folder first.",
            "Result folder not selected",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        return
    }

    if (-not (Test-Path -LiteralPath $folderPath -PathType Container)) {
        try {
            New-Item `
                -ItemType Directory `
                -Path $folderPath `
                -Force `
                -ErrorAction Stop |
                Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "The result folder could not be opened or created:`r`n`r`n$folderPath",
                "Cannot open result folder",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )

            return
        }
    }

    try {
        if ($SourceButton) {
            $SourceButton.Enabled = $false
        }

        # Use the Windows shell directly. This works with spaces and non-ASCII
        # paths and does not tie the button state to an Explorer process.
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $folderPath
        $processInfo.UseShellExecute = $true

        [System.Diagnostics.Process]::Start(
            $processInfo
        ) | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Windows could not open the result folder:`r`n`r`n$folderPath`r`n`r`n$($_.Exception.Message)",
            "Cannot open result folder",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    } finally {
        if ($SourceButton) {
            $SourceButton.Enabled = $true
            $SourceButton.Invalidate()
            $SourceButton.Refresh()
        }

        $form.Activate()
    }
}

function Validate-Inputs {
    $checks = @(
        @{ Label = "BAM"; Path = $bamTextBox.Text },
        @{ Label = "GFF/GFF3/GTF"; Path = $gffTextBox.Text },
        @{ Label = "FASTA"; Path = $fastaTextBox.Text }
    )

    foreach ($check in $checks) {
        if (
            -not $check.Path -or
            -not (Test-Path $check.Path -PathType Leaf)
        ) {
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Select a valid $($check.Label) file.",
                "Missing input",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )

            return $false
        }
    }

    if (-not $outputTextBox.Text) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Select a result folder.",
            "Missing result folder",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        return $false
    }

    try {
        New-Item `
            -ItemType Directory `
            -Path $outputTextBox.Text `
            -Force |
            Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "The result folder could not be created or written.",
            "Invalid result folder",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )

        return $false
    }

    $true
}

# =============================================================================
# WORKFLOW STATUS AND ESTIMATED PROGRESS
# =============================================================================

function Set-WorkflowState {
    param(
        [int]$Step,
        [string]$State,
        [string]$Detail = ""
    )

    if (-not $script:WorkflowItems.ContainsKey($Step)) {
        return
    }

    $item = $script:WorkflowItems[$Step]

    switch ($State) {
        "Finished" {
            $item.Icon.Text = "✓"
            $item.Icon.BackColor = $ColorSuccess
            $item.Status.Text = "Finished"
            $item.Status.ForeColor = $ColorSuccess
            $item.Panel.BackColor = $ColorPanel
        }

        "Running" {
            $item.Icon.Text = "●"
            $item.Icon.BackColor = $ColorAccent
            $item.Status.Text = "Running"
            $item.Status.ForeColor = $ColorAccent
            $item.Panel.BackColor = Get-ThemeColor "#EAF3FF"
        }

        "Error" {
            $item.Icon.Text = "!"
            $item.Icon.BackColor = $ColorError
            $item.Status.Text = "Error"
            $item.Status.ForeColor = $ColorError
            $item.Panel.BackColor = Get-ThemeColor "#FFF0F0"
        }

        "Stopped" {
            $item.Icon.Text = "■"
            $item.Icon.BackColor = $ColorWarning
            $item.Status.Text = "Stopped"
            $item.Status.ForeColor = $ColorWarning
            $item.Panel.BackColor = Get-ThemeColor "#FFF8E8"
        }

        default {
            $item.Icon.Text = [string]$Step
            $item.Icon.BackColor = $ColorPanelAlt
            $item.Status.Text = "Not started"
            $item.Status.ForeColor = $ColorTextDim
            $item.Panel.BackColor = $ColorSidebar
        }
    }

    if ($Detail) {
        $item.Detail.Text = $Detail
    }
}

function Reset-Workflow {
    $defaultDetails = @{
        1 = "BAM, annotation and FASTA"
        2 = "R and required packages"
        3 = "QC, features and SVM"
        4 = "Table, bedGraph and GFF"
    }

    for ($i = 1; $i -le 4; $i++) {
        Set-WorkflowState $i "NotStarted"

        if (
            $script:WorkflowItems.ContainsKey($i) -and
            $defaultDetails.ContainsKey($i)
        ) {
            $script:WorkflowItems[$i].Detail.Text = $defaultDetails[$i]
        }
    }

    $script:CurrentWorkflowStep = 1
}

function Apply-WorkflowProgress {
    param(
        [int]$CurrentStep,
        [string]$State,
        [string]$Message
    )

    $script:CurrentWorkflowStep = $CurrentStep

    for ($i = 1; $i -le 4; $i++) {
        if ($i -lt $CurrentStep) {
            Set-WorkflowState $i "Finished"
        } elseif ($i -eq $CurrentStep) {
            Set-WorkflowState $i $State $Message
        } else {
            Set-WorkflowState $i "NotStarted"
        }
    }

    if ($State -eq "Finished" -and $CurrentStep -eq 4) {
        for ($i = 1; $i -le 4; $i++) {
            Set-WorkflowState $i "Finished"
        }
    }
}

function Update-EstimatedProgress {
    param(
        [int]$Percent,
        [string]$Message,
        [string]$State = "Running"
    )

    if ($Percent -lt 0) {
        $Percent = 0
    }

    if ($Percent -gt 100) {
        $Percent = 100
    }

    $script:CurrentPercent = $Percent

    $trackWidth = $progressTrack.ClientSize.Width
    $fillWidth = [Math]::Floor(
        $trackWidth * ($Percent / 100.0)
    )

    if ($fillWidth -lt 0) {
        $fillWidth = 0
    }

    $progressFill.Width = $fillWidth
    $progressPercentLabel.Text = "$Percent%"
    $progressMessageLabel.Text = $Message

    switch ($State) {
        "Finished" {
            $progressDot.ForeColor = $ColorSuccess
            $progressStateLabel.Text = "Completed"
            $progressStateLabel.ForeColor = $ColorSuccess
        }

        "Error" {
            $progressDot.ForeColor = $ColorError
            $progressStateLabel.Text = "Error"
            $progressStateLabel.ForeColor = $ColorError
        }

        "Stopped" {
            $progressDot.ForeColor = $ColorWarning
            $progressStateLabel.Text = "Stopped"
            $progressStateLabel.ForeColor = $ColorWarning
        }

        "Ready" {
            $progressDot.ForeColor = $ColorTextDim
            $progressStateLabel.Text = "Ready"
            $progressStateLabel.ForeColor = $ColorTextMuted
        }

        default {
            $progressDot.ForeColor = $ColorSuccess
            $progressStateLabel.Text = "Running"
            $progressStateLabel.ForeColor = $ColorSuccess
        }
    }
}

function Read-BackendStatus {
    if (
        -not $script:StatusFile -or
        -not (Test-Path $script:StatusFile)
    ) {
        return
    }

    try {
        $status = @{}

        foreach ($line in Get-Content -Path $script:StatusFile -ErrorAction Stop) {
            $parts = $line -split "`t", 2

            if ($parts.Count -eq 2) {
                $status[$parts[0]] = $parts[1]
            }
        }

        if (
            -not $status.ContainsKey("workflow_step") -or
            -not $status.ContainsKey("percent")
        ) {
            return
        }

        $step = [int]$status["workflow_step"]
        $percent = [int]$status["percent"]
        $state = [string]$status["state"]
        $message = [string]$status["message"]

        $script:BackendState = $state
        $script:BackendMessage = $message
        $script:CurrentPercent = $percent
        $script:CurrentWorkflowStep = $step

        Apply-WorkflowProgress $step $state $message
        Update-EstimatedProgress $percent $message $state
        $runStatusLabel.Text = $message
    } catch {}
}

function Test-RunCompletedSuccessfully {
    $statusFinished = (
        $script:BackendState -eq "Finished" -and
        $script:CurrentPercent -ge 100
    )

    $logFinished = $false

    if (
        $script:RunLog -and
        (Test-Path $script:RunLog)
    ) {
        try {
            $logText = Get-Content `
                -LiteralPath $script:RunLog `
                -Raw `
                -ErrorAction Stop

            $logFinished = (
                $logText.Contains(
                    "[GUI_STATUS] step=4 percent=100 state=Finished"
                ) -or
                $logText.Contains(
                    "PIPELINE COMPLETED"
                )
            )
        } catch {}
    }

    $prefix = Get-OutputSampleName

    $coreOutputs = @(
        (Join-Path `
            $outputTextBox.Text `
            "${prefix} QuasR QC report.pdf"
        ),
        (Join-Path `
            $outputTextBox.Text `
            "${prefix} Final TU Table.xlsx"
        )
    )

    $coreOutputsValid = $true

    foreach ($outputFile in $coreOutputs) {
        if (
            -not (Test-Path $outputFile -PathType Leaf) -or
            (Get-Item $outputFile).Length -le 0
        ) {
            $coreOutputsValid = $false
            break
        }
    }

    $svmGffValid = $false

    if (Test-Path $outputTextBox.Text) {
        try {
            $svmGffValid = (
                Get-ChildItem `
                    -LiteralPath $outputTextBox.Text `
                    -File `
                    -Filter "* rSeqTU clean for SVM.gff" `
                    -ErrorAction Stop |
                Where-Object {
                    $_.Length -gt 0
                } |
                Select-Object -First 1
            ) -ne $null
        } catch {}
    }

    $igvFolder = Join-Path `
        $outputTextBox.Text `
        "IGV Results"

    $igvBundleValid = $false

    if (Test-Path -LiteralPath $igvFolder -PathType Container) {
        try {
            $igvFiles = Get-ChildItem `
                -LiteralPath $igvFolder `
                -File `
                -ErrorAction Stop |
                Where-Object {
                    $_.Length -gt 0
                }

            $bamValid = (
                $igvFiles |
                Where-Object {
                    $_.Extension -ieq ".bam"
                } |
                Select-Object -First 1
            ) -ne $null

            $baiValid = (
                $igvFiles |
                Where-Object {
                    $_.Extension -ieq ".bai"
                } |
                Select-Object -First 1
            ) -ne $null

            $bedgraphValid = Test-Path `
                -LiteralPath (Join-Path `
                    $igvFolder `
                    "${prefix} result.bedgraph"
                ) `
                -PathType Leaf

            if ($bedgraphValid) {
                $bedgraphValid = (
                    Get-Item `
                        -LiteralPath (Join-Path `
                            $igvFolder `
                            "${prefix} result.bedgraph"
                        )
                ).Length -gt 0
            }

            $annotationValid = (
                $igvFiles |
                Where-Object {
                    $_.Extension.ToLowerInvariant() -in @(
                        ".gff",
                        ".gff3",
                        ".gtf"
                    )
                } |
                Select-Object -First 1
            ) -ne $null

            $fastaValid = (
                $igvFiles |
                Where-Object {
                    $_.Extension.ToLowerInvariant() -in @(
                        ".fa",
                        ".fasta",
                        ".fna",
                        ".fas"
                    )
                } |
                Select-Object -First 1
            ) -ne $null

            $bamAndIndexValid = if ($copyBamBaiToIgvCheckBox.Checked) {
                $bamValid -and $baiValid
            } else {
                $true
            }

            $igvBundleValid = (
                $bamAndIndexValid -and
                $bedgraphValid -and
                $annotationValid -and
                $fastaValid
            )
        } catch {}
    }

    return (
        ($statusFinished -or $logFinished) -and
        $coreOutputsValid -and
        $svmGffValid -and
        $igvBundleValid
    )
}


# =============================================================================
# CANCELLATION SNAPSHOT AND CLEANUP
# =============================================================================

function Get-BaiCandidates {
    param([string]$BamPath)

    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add("$BamPath.bai")

    try {
        $directory = Split-Path -Parent $BamPath
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($BamPath)
        $candidates.Add(
            (Join-Path $directory "$baseName.bai")
        )
    } catch {}

    $candidates | Select-Object -Unique
}

function Capture-PreRunSnapshot {
    $script:OutputSnapshot = @{}
    $script:BaiSnapshot = @{}

    if (Test-Path $outputTextBox.Text) {
        Get-ChildItem `
            -Path $outputTextBox.Text `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
            ForEach-Object {
                $script:OutputSnapshot[
                    $_.FullName.ToLowerInvariant()
                ] = $true
            }
    }

    foreach ($candidate in (Get-BaiCandidates $bamTextBox.Text)) {
        $script:BaiSnapshot[
            $candidate.ToLowerInvariant()
        ] = Test-Path $candidate
    }
}

function Cleanup-CancelledRun {
    $protected = @(
        $bamTextBox.Text,
        $gffTextBox.Text,
        $fastaTextBox.Text
    ) |
        Where-Object { $_ } |
        ForEach-Object {
            try {
                [System.IO.Path]::GetFullPath($_).ToLowerInvariant()
            } catch {
                $_.ToLowerInvariant()
            }
        }

    if (Test-Path $outputTextBox.Text) {
        $currentFiles = Get-ChildItem `
            -Path $outputTextBox.Text `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue

        foreach ($file in $currentFiles) {
            $key = $file.FullName.ToLowerInvariant()

            if (
                -not $script:OutputSnapshot.ContainsKey($key) -and
                $protected -notcontains $key
            ) {
                Remove-Item `
                    -LiteralPath $file.FullName `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }

        Get-ChildItem `
            -Path $outputTextBox.Text `
            -Directory `
            -Recurse `
            -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            ForEach-Object {
                try {
                    if (
                        (Get-ChildItem `
                            -LiteralPath $_.FullName `
                            -Force `
                            -ErrorAction Stop
                        ).Count -eq 0
                    ) {
                        Remove-Item `
                            -LiteralPath $_.FullName `
                            -Force `
                            -ErrorAction SilentlyContinue
                    }
                } catch {}
            }
    }

    foreach ($candidate in (Get-BaiCandidates $bamTextBox.Text)) {
        $key = $candidate.ToLowerInvariant()
        $existedBefore = $false

        if ($script:BaiSnapshot.ContainsKey($key)) {
            $existedBefore = [bool]$script:BaiSnapshot[$key]
        }

        if (
            -not $existedBefore -and
            (Test-Path $candidate)
        ) {
            Remove-Item `
                -LiteralPath $candidate `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    foreach (
        $temporaryFile in
        @(
            $script:RunConfig,
            $script:RunLog,
            $script:RunErrorLog,
            $script:StatusFile,
            $script:RunWrapperScript
        )
    ) {
        if (
            $temporaryFile -and
            (Test-Path $temporaryFile)
        ) {
            Remove-Item `
                -LiteralPath $temporaryFile `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

# =============================================================================
# SESSION RUN HISTORY
# =============================================================================

function Get-NormalizedRunPath {
    param([string]$Path)

    if (-not $Path) {
        return ""
    }

    try {
        [System.IO.Path]::GetFullPath($Path).ToLowerInvariant()
    } catch {
        $Path.ToLowerInvariant()
    }
}

function Update-SessionRunPanel {
    if (-not $sessionRunListBox) {
        return
    }

    $sessionRunListBox.BeginUpdate()
    $sessionRunListBox.Items.Clear()

    foreach ($entry in $script:SessionRuns) {
        $displayLine = "{0:HH:mm}  {1}  [{2}]" -f `
            $entry.Time,
            $entry.Sample,
            $entry.State

        [void]$sessionRunListBox.Items.Add($displayLine)
    }

    $sessionRunListBox.EndUpdate()

    $sessionCountLabel.Text = "{0} run{1}" -f `
        $script:SessionRuns.Count,
        $(if ($script:SessionRuns.Count -eq 1) { "" } else { "s" })

    if ($script:SessionRuns.Count -eq 0) {
        $sessionEmptyLabel.Visible = $true
        $sessionRunListBox.Visible = $false
    } else {
        $sessionEmptyLabel.Visible = $false
        $sessionRunListBox.Visible = $true
        $sessionRunListBox.TopIndex = $sessionRunListBox.Items.Count - 1
    }
}

function Add-SessionRun {
    param(
        [ValidateSet("Completed", "Error", "Stopped")]
        [string]$State
    )

    if ($script:CurrentRunRecorded) {
        return
    }

    $sample = $script:CurrentRunSample

    if (-not $sample) {
        $sample = Get-OutputSampleName
    }

    $bamPath = $script:CurrentRunBamPath

    if (-not $bamPath) {
        $bamPath = Get-NormalizedRunPath $bamTextBox.Text
    }

    $script:SessionRuns += [PSCustomObject]@{
        Sample = $sample
        BamPath = $bamPath
        State = $State
        Time = Get-Date
    }

    $script:CurrentRunRecorded = $true
    Update-SessionRunPanel
}

function Confirm-SessionDuplicateRun {
    $candidatePath = Get-NormalizedRunPath $bamTextBox.Text

    $previousRun = @(
        $script:SessionRuns |
        Where-Object {
            $_.State -eq "Completed" -and
            $_.BamPath -eq $candidatePath
        }
    ) |
        Select-Object -Last 1

    if (-not $previousRun) {
        return $true
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        $form,
        "This BAM already completed successfully in the current session:`r`n`r`nSample: $($previousRun.Sample)`r`nCompleted: $($previousRun.Time.ToString('HH:mm:ss'))`r`n`r`nRun the same BAM again?",
        "Sample already completed this session",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )

    $answer -eq [System.Windows.Forms.DialogResult]::Yes
}

# =============================================================================
# RUN, STOP, LOG AND COMPLETION DIALOG
# =============================================================================

function Set-RunningState {
    param([bool]$Running)

    $bamBrowseButton.Enabled = -not $Running
    $gffBrowseButton.Enabled = -not $Running
    $fastaBrowseButton.Enabled = -not $Running
    $outputBrowseButton.Enabled = -not $Running
    $chromosomeTextBox.Enabled = -not $Running
    $minMapqInput.Enabled = -not $Running
    $minBaseQualityInput.Enabled = -not $Running
    if ($copyBamBaiToIgvCheckBox) {
        $copyBamBaiToIgvCheckBox.Enabled = -not $Running
    }
    $runButton.Enabled = -not $Running
    $stopButton.Enabled = $Running
    $resetButton.Enabled = -not $Running
    $installRButton.Enabled = (-not $Running) -and (-not $script:RscriptPath)
    $checkRButton.Enabled = -not $Running
    # The result folder may be opened repeatedly, including during a run.
    $openOutputButton.Enabled = $true
    $clearLogButton.Enabled = -not $Running

    if ($Running) {
        $headerRunStateLabel.Text = "Pipeline running"
        $headerRunStateLabel.ForeColor = $ColorAccent
    }
}

function Reset-ForNextSample {
    if (
        $script:RunningProcess -and
        -not $script:RunningProcess.HasExited
    ) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "The pipeline is still running. Stop it before resetting the interface.",
            "Pipeline running",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        return
    }

    $hasCurrentContent = (
        $bamTextBox.Text -or
        $gffTextBox.Text -or
        $fastaTextBox.Text -or
        $outputTextBox.Text -or
        $chromosomeTextBox.Text -or
        $logTextBox.Text
    )

    if ($hasCurrentContent) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Reset the interface for another sample?`r`n`r`nThis clears the current selections, progress display and on-screen log. Completed result files will not be deleted. The session sample list will remain until you close the software.",
            "Reset for new sample",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if (
            $answer -ne
            [System.Windows.Forms.DialogResult]::Yes
        ) {
            return
        }
    }

    $timer.Stop()

    foreach (
        $temporaryFile in
        @(
            $script:RunConfig,
            $script:RunLog,
            $script:RunErrorLog,
            $script:StatusFile,
            $script:RunWrapperScript
        )
    ) {
        if (
            $temporaryFile -and
            (Test-Path -LiteralPath $temporaryFile)
        ) {
            Remove-Item `
                -LiteralPath $temporaryFile `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    $bamTextBox.Clear()
    $gffTextBox.Clear()
    $fastaTextBox.Clear()
    $outputTextBox.Clear()
    $chromosomeTextBox.Clear()

    $minMapqInput.Value = 15
    $minBaseQualityInput.Value = 10
    if ($copyBamBaiToIgvCheckBox) {
        $copyBamBaiToIgvCheckBox.Checked = $false
    }

    $logTextBox.Clear()

    $script:RunningProcess = $null
    $script:RunConfig = $null
    $script:RunLog = $null
    $script:RunErrorLog = $null
    $script:FullConsoleLogPath = $null
    $script:RunWrapperScript = $null
        $script:RunStartedAt = $null
    $script:StatusFile = $null
    $script:StopRequested = $false
    $script:OutputSnapshot = @{}
    $script:BaiSnapshot = @{}
    $script:CurrentPercent = 0
    $script:CurrentWorkflowStep = 1
    $script:BackendState = "NotStarted"
    $script:BackendMessage = ""
    $script:CurrentRunSample = $null
    $script:CurrentRunBamPath = $null
    $script:CurrentRunRecorded = $false

    # SessionRuns and the session panel are intentionally not cleared here.
    # They exist only for the lifetime of this application process.
    Reset-Workflow

    Update-EstimatedProgress `
        0 `
        "Estimated completion will appear here." `
        "Ready"

    $runStatusLabel.Text = "Ready to start"
    $runStatusLabel.ForeColor = $ColorTextMuted
    $headerRunStateLabel.Text = "Ready"
    $headerRunStateLabel.ForeColor = $ColorTextMuted

    Set-RunningState $false

    $bamTextBox.Focus()
}

function Start-Pipeline {
    if (-not (Validate-Inputs)) {
        return
    }

    if (-not (Confirm-SessionDuplicateRun)) {
        return
    }

    if (-not (Update-RStatus)) {
        Install-R

        if (-not (Update-RStatus)) {
            return
        }
    }

    if (-not (Test-Path $script:BackendScript)) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "The backend file is missing:`r`n$script:BackendScript",
            "Application error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )

        return
    }

    $script:CurrentRunSample = Get-OutputSampleName
    $script:CurrentRunBamPath = Get-NormalizedRunPath $bamTextBox.Text
    $script:CurrentRunRecorded = $false

    Capture-PreRunSnapshot

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:RunStartedAt = Get-Date
    $script:FullConsoleLogPath = $null

    $script:RunConfig = Join-Path `
        $env:TEMP `
        "rSeqTU_GUI_$timestamp.tsv"

    $script:RunLog = Join-Path `
        $env:TEMP `
        "rSeqTU_run_$timestamp.log"

    $script:RunErrorLog = Join-Path `
        $env:TEMP `
        "rSeqTU_run_$timestamp.error.log"

    $script:StatusFile = Join-Path `
        $env:TEMP `
        "rSeqTU_status_$timestamp.tsv"

    $configLines = @(
        "BAM`t$($bamTextBox.Text)",
        "GFF`t$($gffTextBox.Text)",
        "FASTA`t$($fastaTextBox.Text)",
        "OUTPUT`t$($outputTextBox.Text)",
        "CHROMOSOME`t$($chromosomeTextBox.Text.Trim())",
        "MIN_MAPQ`t$([int]$minMapqInput.Value)",
        "MIN_BASE_QUALITY`t$([int]$minBaseQualityInput.Value)",
        "COPY_BAM_BAI_TO_IGV`t$($copyBamBaiToIgvCheckBox.Checked.ToString().ToLowerInvariant())",
        "STATUS_FILE`t$($script:StatusFile)"
    )

    [System.IO.File]::WriteAllLines(
        $script:RunConfig,
        $configLines,
        [System.Text.UTF8Encoding]::new($false)
    )

    foreach (
        $temporaryLog in
        @(
            $script:RunLog,
            $script:RunErrorLog,
            $script:StatusFile,
            $script:RunWrapperScript
        )
    ) {
        if (
            $temporaryLog -and
            (Test-Path $temporaryLog)
        ) {
            Remove-Item `
                -LiteralPath $temporaryLog `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    try {
        $script:StopRequested = $false
        $script:BackendState = "Starting"
        $script:BackendMessage = "Starting pipeline"
        $script:CurrentPercent = 0
        $script:CurrentWorkflowStep = 1

                $backendSnapshot = $script:BackendScript
        $configSnapshot = $script:RunConfig
        $script:RunWrapperScript = Join-Path $env:TEMP "rSeqTU_execute_$timestamp.ps1"
        $wrapperText = @"
`$ErrorActionPreference = 'Stop'
`$rscript = '$($script:RscriptPath.Replace("'", "''"))'
`$backend = '$($backendSnapshot.Replace("'", "''"))'
`$config = '$($configSnapshot.Replace("'", "''"))'

function Write-SourceFile([string]`$Language, [string]`$Path) {
    Write-Output ''
    Write-Output ('=' * 96)
    Write-Output (`$Language + ' CODE TRACE - EXACT SOURCE USED FOR THIS RUN')
    Write-Output ('FILE: ' + `$Path)
    Write-Output ('=' * 96)
    `$lineNumber = 1
    Get-Content -LiteralPath `$Path -Encoding UTF8 | ForEach-Object {
        Write-Output ('{0:D5} | {1}' -f `$lineNumber, `$_)
        `$lineNumber++
    }
    Write-Output ('END ' + `$Language + ' CODE TRACE')
}

Write-Output 'rSeqTU executable code and command trace'
Write-Output ('Rscript: ' + `$rscript)
Write-Output ('Configuration: ' + `$config)
Write-SourceFile -Language 'R' -Path `$backend
Write-SourceFile -Language 'TSV CONFIGURATION' -Path `$config
Write-Output ''
Write-Output ('=' * 96)
Write-Output 'THIRD-PARTY SOFTWARE AND PACKAGE PROVENANCE'
Write-Output 'Compiled third-party programs cannot expose their original source at runtime; exact executable hashes and package metadata follow.'
`$rscriptItem = Get-Item -LiteralPath `$rscript
Write-Output ('RSCRIPT PATH: ' + `$rscriptItem.FullName)
Write-Output ('RSCRIPT SHA256: ' + (Get-FileHash -LiteralPath `$rscriptItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant())
& `$rscript --vanilla -e "cat(R.version.string, '\n'); sessionInfo(); ip <- as.data.frame(installed.packages(), stringsAsFactors=FALSE); keep <- intersect(c('Package','Version','License','Built','LibPath'), colnames(ip)); write.table(ip[,keep,drop=FALSE], row.names=FALSE, sep='\t', quote=FALSE)"
Write-Output 'END THIRD-PARTY SOFTWARE AND PACKAGE PROVENANCE'
Write-Output ''
Write-Output ('EXECUTION COMMAND: "' + `$rscript + '" --vanilla "' + `$backend + '" "' + `$config + '"')
& `$rscript --vanilla `$backend `$config
exit `$LASTEXITCODE
"@
        [System.IO.File]::WriteAllText(
            $script:RunWrapperScript,
            $wrapperText,
            [System.Text.UTF8Encoding]::new($false)
        )

        $script:RunningProcess = Start-Process `
            -FilePath 'powershell.exe' `
            -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                ('"' + $script:RunWrapperScript + '"')
            ) `
            -RedirectStandardOutput $script:RunLog `
            -RedirectStandardError $script:RunErrorLog `
            -WindowStyle Hidden `
            -PassThru

        Reset-Workflow
        Set-WorkflowState 1 "Finished" "Input files selected"
        Set-WorkflowState 2 "Running" "Checking environment"

        Update-EstimatedProgress `
            2 `
            "Validating selected input files" `
            "Running"

        Set-RunningState $true
        $runStatusLabel.Text = "Starting the complete rSeqTU workflow..."
        $logTextBox.Clear()
        $timer.Start()
    } catch {
        Set-RunningState $false
        $script:CurrentRunSample = $null
        $script:CurrentRunBamPath = $null
        $script:CurrentRunRecorded = $false

        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Could not start the pipeline.`r`n`r`n$($_.Exception.Message)",
            "Start error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

function Stop-Pipeline {
    if (
        -not $script:RunningProcess -or
        $script:RunningProcess.HasExited
    ) {
        return
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        $form,
        "Stop the current pipeline?`r`n`r`nAll files created by this run will be deleted. Original BAM, annotation and FASTA files will not be deleted.",
        "Stop pipeline",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    $script:StopRequested = $true
    $timer.Stop()
    $runStatusLabel.Text = "Stopping pipeline and deleting files created by this run..."
    Update-EstimatedProgress `
        $script:CurrentPercent `
        "Stopping and cleaning generated files" `
        "Stopped"

    try {
        $processId = $script:RunningProcess.Id

        Start-Process `
            -FilePath "taskkill.exe" `
            -ArgumentList @(
                "/PID",
                [string]$processId,
                "/T",
                "/F"
            ) `
            -WindowStyle Hidden `
            -Wait `
            -ErrorAction SilentlyContinue |
            Out-Null

        if (-not $script:RunningProcess.HasExited) {
            Stop-Process `
                -Id $processId `
                -Force `
                -ErrorAction SilentlyContinue
        }

        $script:RunningProcess.WaitForExit(5000)
    } catch {}

    try {
        $script:RunningProcess.Dispose()
    } catch {}

    $script:RunningProcess = $null

    Cleanup-CancelledRun
    Set-WorkflowState $script:CurrentWorkflowStep "Stopped" "Stopped by user"
    Set-RunningState $false

    $headerRunStateLabel.Text = "Stopped"
    $headerRunStateLabel.ForeColor = $ColorWarning
    $runStatusLabel.Text = "Pipeline stopped. Files created by this run were deleted."

    Add-SessionRun -State "Stopped"

    [System.Media.SystemSounds]::Exclamation.Play()

    [System.Windows.Forms.MessageBox]::Show(
        $form,
        "The pipeline was stopped.`r`n`r`nFiles created by this run were deleted. Original input files were preserved.",
        "Pipeline stopped",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

function Get-OutputSampleName {
    $prefix = [System.IO.Path]::GetFileNameWithoutExtension(
        $bamTextBox.Text
    )

    $prefix = [System.Text.RegularExpressions.Regex]::Replace(
        $prefix,
        "_+",
        " "
    )

    $prefix = [System.Text.RegularExpressions.Regex]::Replace(
        $prefix,
        '[<>:"/\\|?*\x00-\x1F]',
        " "
    )

    $prefix = [System.Text.RegularExpressions.Regex]::Replace(
        $prefix,
        "\s+",
        " "
    ).Trim()

    if (-not $prefix) {
        $prefix = "rSeqTU sample"
    }

    $prefix
}

function Export-FullConsoleLog {
    param(
        [string]$FinalState,
        [int]$ExitCode
    )

    try {
        $prefix = Get-OutputSampleName
        $finalLogPath = Join-Path `
            $outputTextBox.Text `
            "${prefix} rSeqTU full console log.txt"

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("rSeqTU Transcription Unit Predictor - Full Console Log")
        $lines.Add(("=" * 78))
        $lines.Add("Final state: $FinalState")
        $lines.Add("Windows process exit code: $ExitCode")
        $lines.Add("Started: $($script:RunStartedAt)")
        $lines.Add("Exported: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $lines.Add("BAM: $($bamTextBox.Text)")
        $lines.Add("Annotation: $($gffTextBox.Text)")
        $lines.Add("FASTA: $($fastaTextBox.Text)")
        $lines.Add("Result folder: $($outputTextBox.Text)")
        $lines.Add("Code retention: this full console log contains the exact R source, configuration and command; no duplicate code folder was created.")
        $lines.Add("Chromosome: $($chromosomeTextBox.Text.Trim())")
        $lines.Add("Minimum mapping quality: $([int]$minMapqInput.Value)")
        $lines.Add("Minimum base quality: $([int]$minBaseQualityInput.Value)")
        $lines.Add("")
        $lines.Add("STANDARD OUTPUT")
        $lines.Add(("-" * 78))

        if ($script:RunLog -and (Test-Path -LiteralPath $script:RunLog)) {
            $standardOutput = Get-Content `
                -LiteralPath $script:RunLog `
                -ErrorAction SilentlyContinue

            if ($standardOutput) {
                $lines.AddRange([string[]]$standardOutput)
            } else {
                $lines.Add("(No standard output was recorded.)")
            }
        } else {
            $lines.Add("(Standard-output log file was not found.)")
        }

        $lines.Add("")
        $lines.Add("WARNINGS AND ERRORS")
        $lines.Add(("-" * 78))

        if (
            $script:RunErrorLog -and
            (Test-Path -LiteralPath $script:RunErrorLog)
        ) {
            $errorOutput = Get-Content `
                -LiteralPath $script:RunErrorLog `
                -ErrorAction SilentlyContinue

            if ($errorOutput) {
                $lines.AddRange([string[]]$errorOutput)
            } else {
                $lines.Add("(No warnings or errors were recorded.)")
            }
        } else {
            $lines.Add("(No warnings or errors were recorded.)")
        }

        [System.IO.File]::WriteAllLines(
            $finalLogPath,
            [string[]]$lines,
            [System.Text.UTF8Encoding]::new($false)
        )

        $script:FullConsoleLogPath = $finalLogPath
        return $finalLogPath
    } catch {
        $script:FullConsoleLogPath = $null
        return $null
    }
}

function Refresh-Log {
    $sections = New-Object System.Collections.Generic.List[string]

    if ($script:RunLog -and (Test-Path $script:RunLog)) {
        try {
            $sections.AddRange(
                [string[]](
                    Get-Content `
                        -Path $script:RunLog `
                        -ErrorAction Stop
                )
            )
        } catch {}
    }

    if (
        $script:RunErrorLog -and
        (Test-Path $script:RunErrorLog)
    ) {
        try {
            $errorTail = Get-Content `
                -Path $script:RunErrorLog `
                -Tail 120 `
                -ErrorAction Stop

            $visibleErrorTail = @(
                $errorTail |
                Where-Object {
                    $_ -notmatch "replacing previous import" -and
                    $_ -notmatch "'sed' not found" -and
                    $_ -notmatch "'mv' not found" -and
                    $_ -notmatch "^Loading required package:"
                }
            )

            if ($visibleErrorTail.Count -gt 0) {
                $sections.Add("")
                $sections.Add("---- warnings/errors ----")
                $sections.AddRange(
                    [string[]]$visibleErrorTail
                )
            }
        } catch {}
    }

    $logTextBox.Text = (
        $sections -join [Environment]::NewLine
    )

    $logTextBox.SelectionStart = $logTextBox.TextLength
    $logTextBox.ScrollToCaret()
}

function Show-CompletionDialog {
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Show()
    $form.Activate()
    $form.BringToFront()

    [System.Media.SystemSounds]::Asterisk.Play()

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "rSeqTU analysis completed"
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Size = New-Object System.Drawing.Size(560, 330)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.TopMost = $true
    $dialog.BackColor = $ColorPanel
    $dialog.ForeColor = $ColorText
    $dialog.Font = $FontUI

    $check = New-Object System.Windows.Forms.Label
    $check.Text = "✓"
    $check.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $check.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 28)
    $check.ForeColor = $ColorSuccess
    $check.BackColor = Get-ThemeColor "#EAF8F0"
    $check.Location = New-Object System.Drawing.Point(26, 24)
    $check.Size = New-Object System.Drawing.Size(72, 72)
    $dialog.Controls.Add($check)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Analysis completed successfully"
    $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 15)
    $title.ForeColor = $ColorText
    $title.Location = New-Object System.Drawing.Point(118, 25)
    $title.Size = New-Object System.Drawing.Size(400, 32)
    $dialog.Controls.Add($title)

    $message = New-Object System.Windows.Forms.Label
    $igvCompletionDescription = if ($copyBamBaiToIgvCheckBox.Checked) {
        "the IGV Results folder including BAM and BAI"
    } else {
        "the IGV Results folder without an additional BAM/BAI copy"
    }
    $message.Text = "All pipeline stages finished. The QC report, TU Excel workbook, cleaned SVM GFF, full console log and $igvCompletionDescription are ready."
    $message.ForeColor = $ColorTextMuted
    $message.Location = New-Object System.Drawing.Point(120, 63)
    $message.Size = New-Object System.Drawing.Size(390, 50)
    $dialog.Controls.Add($message)

    $folderTitle = New-Object System.Windows.Forms.Label
    $folderTitle.Text = "Result folder"
    $folderTitle.Font = $FontMedium
    $folderTitle.Location = New-Object System.Drawing.Point(28, 130)
    $folderTitle.Size = New-Object System.Drawing.Size(120, 24)
    $dialog.Controls.Add($folderTitle)

    $folderBox = New-Object System.Windows.Forms.TextBox
    $folderBox.Text = $outputTextBox.Text
    $folderBox.ReadOnly = $true
    $folderBox.Location = New-Object System.Drawing.Point(28, 157)
    $folderBox.Size = New-Object System.Drawing.Size(490, 28)
    Set-LightTextBox $folderBox
    $dialog.Controls.Add($folderBox)

    $note = New-Object System.Windows.Forms.Label
    $note.Text = if ($copyBamBaiToIgvCheckBox.Checked) {
        "Open IGV Results for the BAM, BAI, bedGraph, annotation and FASTA files."
    } else {
        "Open IGV Results for the bedGraph, annotation and FASTA files; the original BAM was not copied."
    }
    $note.ForeColor = $ColorTextMuted
    $note.Location = New-Object System.Drawing.Point(28, 197)
    $note.Size = New-Object System.Drawing.Size(490, 24)
    $dialog.Controls.Add($note)

    $openButton = New-Object System.Windows.Forms.Button
    $openButton.Text = "Open result folder"
    $openButton.Location = New-Object System.Drawing.Point(248, 242)
    $openButton.Size = New-Object System.Drawing.Size(145, 38)
    Set-FlatButton $openButton $ColorAccent ([System.Drawing.Color]::White)
    $openButton.Add_Click({
        Open-ResultFolder `
            -SourceButton $openButton
    })
    $dialog.Controls.Add($openButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.Location = New-Object System.Drawing.Point(405, 242)
    $closeButton.Size = New-Object System.Drawing.Size(113, 38)
    Set-FlatButton $closeButton
    $closeButton.Add_Click({
        $dialog.Close()
    })
    $dialog.Controls.Add($closeButton)

    [void]$dialog.ShowDialog($form)
}

# =============================================================================
# MAIN WINDOW
# =============================================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = "rSeqTU Transcription Unit Predictor"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1480, 900)
$form.MinimumSize = New-Object System.Drawing.Size(1180, 760)
$form.BackColor = $ColorWindow
$form.ForeColor = $ColorText
$form.Font = $FontUI
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

# Header
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$headerPanel.Height = 68
$headerPanel.BackColor = $ColorHeader
$headerPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($headerPanel)

$appMark = New-Object System.Windows.Forms.Label
$appMark.Text = "TU"
$appMark.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$appMark.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
$appMark.ForeColor = [System.Drawing.Color]::White
$appMark.BackColor = $ColorAccent
$appMark.Location = New-Object System.Drawing.Point(14, 12)
$appMark.Size = New-Object System.Drawing.Size(38, 36)
$headerPanel.Controls.Add($appMark)

$appTitle = New-Object System.Windows.Forms.Label
$appTitle.Text = "rSeqTU Transcription Unit Predictor"
$appTitle.Font = $FontTitle
$appTitle.ForeColor = $ColorText
$appTitle.Location = New-Object System.Drawing.Point(64, 6)
$appTitle.Size = New-Object System.Drawing.Size(520, 30)
$headerPanel.Controls.Add($appTitle)

$appSubtitle = New-Object System.Windows.Forms.Label
$appSubtitle.Text = "Bacterial RNA-seq Transcription Unit analysis"
$appSubtitle.Font = $FontSmall
$appSubtitle.ForeColor = $ColorTextMuted
$appSubtitle.Location = New-Object System.Drawing.Point(66, 40)
$appSubtitle.Size = New-Object System.Drawing.Size(440, 20)
$headerPanel.Controls.Add($appSubtitle)

$headerEnvironmentLabel = New-Object System.Windows.Forms.Label
$headerEnvironmentLabel.Text = "Checking R..."
$headerEnvironmentLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$headerEnvironmentLabel.Font = $FontSmall
$headerEnvironmentLabel.ForeColor = $ColorWarning
$headerEnvironmentLabel.Anchor = "Top,Right"
$headerEnvironmentLabel.Location = New-Object System.Drawing.Point(1080, 8)
$headerEnvironmentLabel.Size = New-Object System.Drawing.Size(170, 20)
$headerEnvironmentLabel.Visible = $false

$headerRunStateLabel = New-Object System.Windows.Forms.Label
$headerRunStateLabel.Text = "Ready"
$headerRunStateLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$headerRunStateLabel.Font = $FontMedium
$headerRunStateLabel.ForeColor = $ColorTextMuted
$headerRunStateLabel.Anchor = "Top,Right"
$headerRunStateLabel.Location = New-Object System.Drawing.Point(1260, 8)
$headerRunStateLabel.Size = New-Object System.Drawing.Size(195, 24)
$headerRunStateLabel.Visible = $false

# Main body with a full-height inspector on the right
$bodyTable = New-Object System.Windows.Forms.TableLayoutPanel
$bodyTable.Dock = [System.Windows.Forms.DockStyle]::Fill
$bodyTable.ColumnCount = 2
$bodyTable.RowCount = 1
$bodyTable.Margin = New-Object System.Windows.Forms.Padding(0)
$bodyTable.Padding = New-Object System.Windows.Forms.Padding(0)
$bodyTable.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
)
$bodyTable.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        340
    ))
)
$form.Controls.Add($bodyTable)
$bodyTable.BringToFront()

# Main horizontal split for workflow, analysis and live log
$mainSplit = New-Object System.Windows.Forms.SplitContainer
$mainSplit.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainSplit.Orientation = [System.Windows.Forms.Orientation]::Horizontal
$mainSplit.SplitterWidth = 5
$mainSplit.SplitterDistance = 515
$mainSplit.Panel1MinSize = 500
$mainSplit.Panel2MinSize = 145
$mainSplit.IsSplitterFixed = $true
$mainSplit.BackColor = $ColorBorder
$bodyTable.Controls.Add($mainSplit, 0, 0)

$workspaceTable = New-Object System.Windows.Forms.TableLayoutPanel
$workspaceTable.Dock = [System.Windows.Forms.DockStyle]::Fill
$workspaceTable.ColumnCount = 2
$workspaceTable.RowCount = 1
$workspaceTable.Margin = New-Object System.Windows.Forms.Padding(0)
$workspaceTable.Padding = New-Object System.Windows.Forms.Padding(0)

$workspaceTable.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        280
    ))
)

$workspaceTable.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
)

$mainSplit.Panel1.Controls.Add($workspaceTable)

# Left workflow panel
$leftPanel = New-Object System.Windows.Forms.Panel
$leftPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$leftPanel.AutoScroll = $true
$leftPanel.BackColor = $ColorSidebar
$leftPanel.Padding = New-Object System.Windows.Forms.Padding(14)
$workspaceTable.Controls.Add($leftPanel, 0, 0)

$workflowTitle = New-SectionTitle "WORKFLOW STATUS" 15 16 235
$workflowTitle.Font = $FontSmall
$workflowTitle.ForeColor = $ColorTextDim
$leftPanel.Controls.Add($workflowTitle)

function Add-WorkflowItem {
    param(
        [int]$Number,
        [string]$Title,
        [string]$Description,
        [int]$Y
    )

    $itemPanel = New-Object System.Windows.Forms.Panel
    $itemPanel.Location = New-Object System.Drawing.Point(10, $Y)
    $itemPanel.Size = New-Object System.Drawing.Size(245, 58)
    $itemPanel.BackColor = $ColorSidebar
    $itemPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    $iconLabel = New-Object System.Windows.Forms.Label
    $iconLabel.Text = [string]$Number
    $iconLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $iconLabel.Location = New-Object System.Drawing.Point(8, 17)
    $iconLabel.Size = New-Object System.Drawing.Size(30, 30)
    $iconLabel.Font = $FontMedium
    $iconLabel.ForeColor = $ColorText
    $iconLabel.BackColor = $ColorPanelAlt
    $itemPanel.Controls.Add($iconLabel)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Location = New-Object System.Drawing.Point(48, 6)
    $titleLabel.Size = New-Object System.Drawing.Size(185, 22)
    $titleLabel.Font = $FontMedium
    $titleLabel.ForeColor = $ColorText
    $itemPanel.Controls.Add($titleLabel)

    $descriptionLabel = New-Object System.Windows.Forms.Label
    $descriptionLabel.Text = $Description
    $descriptionLabel.Location = New-Object System.Drawing.Point(48, 25)
    $descriptionLabel.Size = New-Object System.Drawing.Size(187, 18)
    $descriptionLabel.Font = New-Object System.Drawing.Font(
        "Segoe UI",
        7.5,
        [System.Drawing.FontStyle]::Regular,
        [System.Drawing.GraphicsUnit]::Point
    )
    $descriptionLabel.ForeColor = $ColorTextMuted
    $descriptionLabel.AutoEllipsis = $false
    $descriptionLabel.UseCompatibleTextRendering = $false
    $itemPanel.Controls.Add($descriptionLabel)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "Not started"
    $statusLabel.Location = New-Object System.Drawing.Point(48, 40)
    $statusLabel.Size = New-Object System.Drawing.Size(187, 17)
    $statusLabel.Font = New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        8,
        [System.Drawing.FontStyle]::Regular,
        [System.Drawing.GraphicsUnit]::Point
    )
    $statusLabel.AutoEllipsis = $false
    $statusLabel.UseCompatibleTextRendering = $false
    $statusLabel.ForeColor = $ColorTextDim
    $itemPanel.Controls.Add($statusLabel)

    $leftPanel.Controls.Add($itemPanel)

    $script:WorkflowItems[$Number] = [PSCustomObject]@{
        Panel = $itemPanel
        Icon = $iconLabel
        Title = $titleLabel
        Detail = $descriptionLabel
        Status = $statusLabel
    }
}

Add-WorkflowItem 1 "Select inputs" "BAM, annotation and FASTA" 50
Add-WorkflowItem 2 "Check environment" "R and required packages" 110
Add-WorkflowItem 3 "Run analysis" "QC, features and SVM" 170
Add-WorkflowItem 4 "Review outputs" "Table, bedGraph and GFF" 230

$leftDivider = New-Object System.Windows.Forms.Panel
$leftDivider.Location = New-Object System.Drawing.Point(14, 298)
$leftDivider.Size = New-Object System.Drawing.Size(238, 1)
$leftDivider.BackColor = $ColorBorder
$leftPanel.Controls.Add($leftDivider)

$leftActionsTitle = New-SectionTitle "ACTIONS" 15 308 235
$leftActionsTitle.Font = $FontSmall
$leftActionsTitle.ForeColor = $ColorTextDim
$leftPanel.Controls.Add($leftActionsTitle)

$openOutputButton = New-Object System.Windows.Forms.Button
$openOutputButton.Text = "Open result folder"
$openOutputButton.Location = New-Object System.Drawing.Point(14, 334)
$openOutputButton.Size = New-Object System.Drawing.Size(238, 32)
Set-FlatButton $openOutputButton
$openOutputButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
$openOutputButton.Add_Click({
    Open-ResultFolder `
        -SourceButton $openOutputButton
})
$leftPanel.Controls.Add($openOutputButton)

$readmeButton = New-Object System.Windows.Forms.Button
$readmeButton.Text = "Open Instructions"
$readmeButton.Location = New-Object System.Drawing.Point(14, 372)
$readmeButton.Size = New-Object System.Drawing.Size(238, 32)
Set-FlatButton $readmeButton
$readmeButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
$readmeButton.Add_Click({
    $instructionsPath = Join-Path `
        $script:RootDirectory `
        "Instructions.html"

    if (-not (Test-Path -LiteralPath $instructionsPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "The HTML instruction guide was not found:`r`n`r`n$instructionsPath",
            "Instructions not found",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    try {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $instructionsPath
        $processInfo.UseShellExecute = $true
        [System.Diagnostics.Process]::Start($processInfo) | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Windows could not open the HTML instruction guide.`r`n`r`n$($_.Exception.Message)",
            "Cannot open Instructions",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
})
$leftPanel.Controls.Add($readmeButton)

$returnToSuiteButton = New-Object System.Windows.Forms.Button
$returnToSuiteButton.Text = "< Return to Prediction Suite"
$returnToSuiteButton.Location = New-Object System.Drawing.Point(1190, 14)
$returnToSuiteButton.Size = New-Object System.Drawing.Size(265, 34)
$returnToSuiteButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$returnToSuiteButton.Enabled = ($script:SuiteManaged -or $script:EmbeddedMode)
if ($script:EmbeddedMode) { $returnToSuiteButton.Text = "< Back to operon methods" }
Set-FlatButton $returnToSuiteButton
$returnToSuiteButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$returnToSuiteButton.Add_Click({
    Return-ToPredictionSuite
})
$headerPanel.Controls.Add($returnToSuiteButton)

$returnToAnalysisButton = New-Object System.Windows.Forms.Button
$returnToAnalysisButton.Text = "< Back to analysis modules"
$returnToAnalysisButton.Location = New-Object System.Drawing.Point(980, 14)
$returnToAnalysisButton.Size = New-Object System.Drawing.Size(200, 34)
$returnToAnalysisButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$returnToAnalysisButton.Visible = $script:EmbeddedMode
Set-FlatButton $returnToAnalysisButton
$returnToAnalysisButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$returnToAnalysisButton.Add_Click({ Return-ToAnalysisModules })
$headerPanel.Controls.Add($returnToAnalysisButton)

# Center workspace
$centerHost = New-Object System.Windows.Forms.Panel
$centerHost.Dock = [System.Windows.Forms.DockStyle]::Fill
$centerHost.BackColor = $ColorWorkspace
$centerHost.Padding = New-Object System.Windows.Forms.Padding(24)
$workspaceTable.Controls.Add($centerHost, 1, 0)

$centerHost.Add_Paint({
    param($sender, $eventArgs)

    $pen = New-Object System.Drawing.Pen($ColorGrid, 1)

    try {
        for ($x = 0; $x -lt $sender.ClientSize.Width; $x += 24) {
            $eventArgs.Graphics.DrawLine(
                $pen,
                $x,
                0,
                $x,
                $sender.ClientSize.Height
            )
        }

        for ($y = 0; $y -lt $sender.ClientSize.Height; $y += 24) {
            $eventArgs.Graphics.DrawLine(
                $pen,
                0,
                $y,
                $sender.ClientSize.Width,
                $y
            )
        }
    } finally {
        $pen.Dispose()
    }
})

$centerScroll = New-Object System.Windows.Forms.Panel
$centerScroll.Dock = [System.Windows.Forms.DockStyle]::Fill
$centerScroll.AutoScroll = $true
$centerScroll.AutoScrollMinSize = New-Object System.Drawing.Size(690, 440)
$centerScroll.BackColor = [System.Drawing.Color]::Transparent
$centerHost.Controls.Add($centerScroll)

$analysisCard = New-Object System.Windows.Forms.Panel
$analysisCard.Location = New-Object System.Drawing.Point(10, 8)
$analysisCard.Size = New-Object System.Drawing.Size(800, 430)
$analysisCard.Anchor = "Top,Left,Right"
$analysisCard.BackColor = $ColorPanel
$analysisCard.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$centerScroll.Controls.Add($analysisCard)

function Layout-RSeqTUAnalysisWorkspace {
    if (-not $centerScroll -or $centerScroll.IsDisposed -or -not $analysisCard -or $analysisCard.IsDisposed) { return }
    $targetWidth = [Math]::Max(690, ($centerScroll.ClientSize.Width - 20))
    $analysisCard.SetBounds(10, 8, $targetWidth, 430)
}
$centerScroll.Add_Resize({ Layout-RSeqTUAnalysisWorkspace })

$accentStrip = New-Object System.Windows.Forms.Panel
$accentStrip.Location = New-Object System.Drawing.Point(0, 0)
$accentStrip.Size = New-Object System.Drawing.Size(5, 430)
$accentStrip.BackColor = $ColorAccent
$analysisCard.Controls.Add($accentStrip)

$analysisTitle = New-Object System.Windows.Forms.Label
$analysisTitle.Text = "New Transcription Unit analysis"
$analysisTitle.Font = $FontSection
$analysisTitle.ForeColor = $ColorText
$analysisTitle.Location = New-Object System.Drawing.Point(24, 11)
$analysisTitle.Size = New-Object System.Drawing.Size(500, 26)
$analysisCard.Controls.Add($analysisTitle)

$analysisSubtitle = New-Object System.Windows.Forms.Label
$analysisSubtitle.Text = "Select BAM, GFF/GFF3/GTF, genomic FASTA and a result folder. Leave chromosome blank to use the first chromosome in the files."
$analysisSubtitle.Font = $FontSmall
$analysisSubtitle.ForeColor = $ColorTextMuted
$analysisSubtitle.Location = New-Object System.Drawing.Point(25, 38)
$analysisSubtitle.Size = New-Object System.Drawing.Size(740, 27)
$analysisCard.Controls.Add($analysisSubtitle)

$inputDivider = New-Object System.Windows.Forms.Panel
$inputDivider.Location = New-Object System.Drawing.Point(24, 70)
$inputDivider.Size = New-Object System.Drawing.Size(748, 1)
$inputDivider.Anchor = "Top,Left,Right"
$inputDivider.BackColor = $ColorBorder
$analysisCard.Controls.Add($inputDivider)

$inputTable = New-Object System.Windows.Forms.TableLayoutPanel
$inputTable.Location = New-Object System.Drawing.Point(24, 75)
$inputTable.Size = New-Object System.Drawing.Size(748, 180)
$inputTable.Anchor = "Top,Left,Right"
$inputTable.ColumnCount = 3
$inputTable.RowCount = 5
$inputTable.BackColor = $ColorPanel
$inputTable.Margin = New-Object System.Windows.Forms.Padding(0)
$inputTable.Padding = New-Object System.Windows.Forms.Padding(0)

$inputTable.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        145
    ))
)

$inputTable.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent,
        100
    ))
)

$inputTable.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        110
    ))
)

for ($i = 0; $i -lt 4; $i++) {
    $inputTable.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle(
            [System.Windows.Forms.SizeType]::Absolute,
            34
        ))
    )
}

$inputTable.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle(
        [System.Windows.Forms.SizeType]::Absolute,
        44
    ))
)

$analysisCard.Controls.Add($inputTable)

function Add-InputRow {
    param(
        [int]$Row,
        [string]$LabelText,
        [System.Windows.Forms.TextBox]$TextBox,
        [System.Windows.Forms.Button]$BrowseButton,
        [scriptblock]$BrowseAction,
        [bool]$ShowBrowse = $true
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $LabelText
    $label.Dock = [System.Windows.Forms.DockStyle]::Fill
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $label.ForeColor = $ColorText
    $label.Font = $FontMedium
    $label.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
    $inputTable.Controls.Add($label, 0, $Row)

    Set-LightTextBox $TextBox
    $TextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $TextBox.Margin = New-Object System.Windows.Forms.Padding(0, 7, 10, 7)
    $inputTable.Controls.Add($TextBox, 1, $Row)

    if ($ShowBrowse) {
        $BrowseButton.Text = "Browse..."
        Set-FlatButton $BrowseButton
        $BrowseButton.Dock = [System.Windows.Forms.DockStyle]::Fill
        $BrowseButton.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
        $BrowseButton.Add_Click($BrowseAction)
        $inputTable.Controls.Add($BrowseButton, 2, $Row)
    } else {
        $optionalLabel = New-Object System.Windows.Forms.Label
        $optionalLabel.Text = "Optional"
        $optionalLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
        $optionalLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $optionalLabel.ForeColor = $ColorTextDim
        $optionalLabel.Font = $FontSmall
        $inputTable.Controls.Add($optionalLabel, 2, $Row)
    }
}

$bamTextBox = New-Object System.Windows.Forms.TextBox
$bamBrowseButton = New-Object System.Windows.Forms.Button
Add-InputRow `
    0 `
    "BAM file" `
    $bamTextBox `
    $bamBrowseButton `
    {
        Select-InputFile `
            "BAM files (*.bam)|*.bam|All files (*.*)|*.*" `
            $bamTextBox
    }

$gffTextBox = New-Object System.Windows.Forms.TextBox
$gffBrowseButton = New-Object System.Windows.Forms.Button
Add-InputRow `
    1 `
    "GFF/GFF3/GTF file" `
    $gffTextBox `
    $gffBrowseButton `
    {
        Select-InputFile `
            "Annotation files (*.gff;*.gff3;*.gtf)|*.gff;*.gff3;*.gtf|GFF files (*.gff)|*.gff|GFF3 files (*.gff3)|*.gff3|GTF files (*.gtf)|*.gtf|All files (*.*)|*.*" `
            $gffTextBox
    }

$fastaTextBox = New-Object System.Windows.Forms.TextBox
$fastaBrowseButton = New-Object System.Windows.Forms.Button
Add-InputRow `
    2 `
    "FASTA file" `
    $fastaTextBox `
    $fastaBrowseButton `
    {
        Select-InputFile `
            "FASTA files (*.fa;*.fasta;*.fna)|*.fa;*.fasta;*.fna|All files (*.*)|*.*" `
            $fastaTextBox
    }

$outputTextBox = New-Object System.Windows.Forms.TextBox
$outputBrowseButton = New-Object System.Windows.Forms.Button
Add-InputRow `
    3 `
    "Result folder" `
    $outputTextBox `
    $outputBrowseButton `
    {
        Select-OutputFolder
    }

$chromosomeTextBox = New-Object System.Windows.Forms.TextBox
$chromosomeTextBox.Font = New-Object System.Drawing.Font(
    "Segoe UI",
    9,
    [System.Drawing.FontStyle]::Regular
)

$chromosomeDummyButton = New-Object System.Windows.Forms.Button

Add-InputRow `
    4 `
    "Chromosome name" `
    $chromosomeTextBox `
    $chromosomeDummyButton `
    {} `
    $false

# Replace the chromosome textbox cell with a two-line container.
$inputTable.Controls.Remove($chromosomeTextBox)

$chromosomeCellPanel = New-Object System.Windows.Forms.Panel
$chromosomeCellPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$chromosomeCellPanel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
$chromosomeCellPanel.BackColor = $ColorPanel

$chromosomeTextBox.Dock = [System.Windows.Forms.DockStyle]::Top
$chromosomeTextBox.Height = 26
$chromosomeTextBox.Margin = New-Object System.Windows.Forms.Padding(0)
$chromosomeCellPanel.Controls.Add($chromosomeTextBox)

$chromosomeHelpLabel = New-Object System.Windows.Forms.Label
$chromosomeHelpLabel.Text = "Otherwise, the software will use the first chromosomes in the files."
$chromosomeHelpLabel.Dock = [System.Windows.Forms.DockStyle]::Bottom
$chromosomeHelpLabel.Height = 16
$chromosomeHelpLabel.Font = New-Object System.Drawing.Font(
    "Segoe UI",
    7.5,
    [System.Drawing.FontStyle]::Regular
)
$chromosomeHelpLabel.ForeColor = $ColorTextMuted
$chromosomeHelpLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$chromosomeHelpLabel.UseCompatibleTextRendering = $false
$chromosomeCellPanel.Controls.Add($chromosomeHelpLabel)

$inputTable.Controls.Add(
    $chromosomeCellPanel,
    1,
    4
)

$chromosomeNameLabel = $inputTable.GetControlFromPosition(0, 4)
$chromosomeOptionalLabel = $inputTable.GetControlFromPosition(2, 4)
if ($chromosomeNameLabel) {
    $chromosomeNameLabel.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    $chromosomeNameLabel.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $chromosomeNameLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
}
if ($chromosomeOptionalLabel) {
    $chromosomeOptionalLabel.TextAlign = [System.Drawing.ContentAlignment]::TopCenter
    $chromosomeOptionalLabel.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $chromosomeOptionalLabel.Margin = New-Object System.Windows.Forms.Padding(0)
}

$runDivider = New-Object System.Windows.Forms.Panel
$runDivider.Location = New-Object System.Drawing.Point(24, 263)
$runDivider.Size = New-Object System.Drawing.Size(748, 1)
$runDivider.Anchor = "Top,Left,Right"
$runDivider.BackColor = $ColorBorder
$analysisCard.Controls.Add($runDivider)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "▶  Run pipeline"
$runButton.Location = New-Object System.Drawing.Point(24, 278)
$runButton.Size = New-Object System.Drawing.Size(160, 40)
Set-FlatButton $runButton $ColorAccent ([System.Drawing.Color]::White)
$runButton.FlatAppearance.BorderColor = $ColorAccent
$runButton.Font = $FontMedium
$runButton.Add_Click({
    Start-Pipeline
})
$analysisCard.Controls.Add($runButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = "■  Stop pipeline"
$stopButton.Location = New-Object System.Drawing.Point(195, 278)
$stopButton.Size = New-Object System.Drawing.Size(140, 40)
Set-FlatButton $stopButton (Get-ThemeColor "#FFF4F4") $ColorError
$stopButton.FlatAppearance.BorderColor = $ColorError
$stopButton.Enabled = $false
$stopButton.Add_Click({
    Stop-Pipeline
})
$analysisCard.Controls.Add($stopButton)

$resetButton = New-Object System.Windows.Forms.Button
$resetButton.Text = "Reset"
$resetButton.Location = New-Object System.Drawing.Point(346, 278)
$resetButton.Size = New-Object System.Drawing.Size(120, 40)
Set-FlatButton $resetButton
$resetButton.FlatAppearance.BorderColor = $ColorBorder
$resetButton.Font = $FontMedium
$resetButton.Add_Click({
    Reset-ForNextSample
})
$analysisCard.Controls.Add($resetButton)

$runStatusLabel = New-Object System.Windows.Forms.Label
$runStatusLabel.Text = "Ready to start"
$runStatusLabel.Font = $FontUI
$runStatusLabel.ForeColor = $ColorTextMuted
$runStatusLabel.Location = New-Object System.Drawing.Point(481, 306)
$runStatusLabel.Size = New-Object System.Drawing.Size(279, 18)
$runStatusLabel.Anchor = "Top,Left,Right"
$analysisCard.Controls.Add($runStatusLabel)

$copyBamBaiToIgvCheckBox = New-Object System.Windows.Forms.CheckBox
$copyBamBaiToIgvCheckBox.Text = "Copy BAM and BAI to IGV Results"
$copyBamBaiToIgvCheckBox.Location = New-Object System.Drawing.Point(481, 280)
$copyBamBaiToIgvCheckBox.Size = New-Object System.Drawing.Size(279, 22)
$copyBamBaiToIgvCheckBox.Anchor = "Top,Left,Right"
$copyBamBaiToIgvCheckBox.Checked = $false
$copyBamBaiToIgvCheckBox.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$copyBamBaiToIgvCheckBox.ForeColor = $ColorText
$copyBamBaiToIgvCheckBox.UseCompatibleTextRendering = $false
$analysisCard.Controls.Add($copyBamBaiToIgvCheckBox)

$igvCopyToolTip = New-Object System.Windows.Forms.ToolTip
$igvCopyToolTip.AutoPopDelay = 30000
$igvCopyToolTip.InitialDelay = 250
$igvCopyToolTip.ReshowDelay = 100
$igvCopyToolTip.ShowAlways = $true
$igvCopyToolTip.SetToolTip(
    $copyBamBaiToIgvCheckBox,
    "Optional. When selected, rSeqTU copies the coordinate-sorted BAM and matching BAI into IGV Results. Leave it clear to avoid duplicating large alignment files; the bedGraph, annotation and FASTA are still exported."
)

$progressCard = New-Object System.Windows.Forms.Panel
$progressCard.Location = New-Object System.Drawing.Point(24, 326)
$progressCard.Size = New-Object System.Drawing.Size(748, 88)
$progressCard.Anchor = "Top,Left,Right"
$progressCard.BackColor = $ColorPanelAlt
$progressCard.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$analysisCard.Controls.Add($progressCard)

$progressDot = New-Object System.Windows.Forms.Label
$progressDot.Text = "●"
$progressDot.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$progressDot.ForeColor = $ColorTextDim
$progressDot.Location = New-Object System.Drawing.Point(14, 9)
$progressDot.Size = New-Object System.Drawing.Size(24, 24)
$progressCard.Controls.Add($progressDot)

$progressStateLabel = New-Object System.Windows.Forms.Label
$progressStateLabel.Text = "Ready"
$progressStateLabel.Font = $FontMedium
$progressStateLabel.ForeColor = $ColorTextMuted
$progressStateLabel.Location = New-Object System.Drawing.Point(40, 10)
$progressStateLabel.Size = New-Object System.Drawing.Size(120, 23)
$progressCard.Controls.Add($progressStateLabel)

$progressPercentLabel = New-Object System.Windows.Forms.Label
$progressPercentLabel.Text = "0%"
$progressPercentLabel.Font = $FontMedium
$progressPercentLabel.ForeColor = $ColorText
$progressPercentLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$progressPercentLabel.Anchor = "Top,Right"
$progressPercentLabel.Location = New-Object System.Drawing.Point(665, 9)
$progressPercentLabel.Size = New-Object System.Drawing.Size(60, 24)
$progressCard.Controls.Add($progressPercentLabel)

$progressMessageLabel = New-Object System.Windows.Forms.Label
$progressMessageLabel.Text = "Estimated completion will appear here."
$progressMessageLabel.Font = New-Object System.Drawing.Font(
    "Segoe UI",
    8.5,
    [System.Drawing.FontStyle]::Regular,
    [System.Drawing.GraphicsUnit]::Point
)
$progressMessageLabel.UseCompatibleTextRendering = $false
$progressMessageLabel.ForeColor = $ColorTextMuted
$progressMessageLabel.Location = New-Object System.Drawing.Point(17, 35)
$progressMessageLabel.Size = New-Object System.Drawing.Size(705, 20)
$progressCard.Controls.Add($progressMessageLabel)

$progressTrack = New-Object System.Windows.Forms.Panel
$progressTrack.Location = New-Object System.Drawing.Point(17, 63)
$progressTrack.Size = New-Object System.Drawing.Size(708, 13)
$progressTrack.Anchor = "Top,Left,Right"
$progressTrack.BackColor = $ColorProgressBack
$progressTrack.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$progressCard.Controls.Add($progressTrack)

$progressFill = New-Object System.Windows.Forms.Panel
$progressFill.Location = New-Object System.Drawing.Point(0, 0)
$progressFill.Size = New-Object System.Drawing.Size(0, 13)
$progressFill.BackColor = $ColorSuccess
$progressTrack.Controls.Add($progressFill)
Layout-RSeqTUAnalysisWorkspace

# Right inspector
$rightPanel = New-Object System.Windows.Forms.Panel
$rightPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$rightPanel.AutoScroll = $false
$rightPanel.BackColor = $ColorSidebar
$rightPanel.Padding = New-Object System.Windows.Forms.Padding(14)
$bodyTable.Controls.Add($rightPanel, 1, 0)

$inspectorTitle = New-SectionTitle "RUN INSPECTOR" 14 8 285
$inspectorTitle.Font = $FontSmall
$inspectorTitle.ForeColor = $ColorTextDim
$rightPanel.Controls.Add($inspectorTitle)

$environmentCard = New-Object System.Windows.Forms.Panel
$environmentCard.Location = New-Object System.Drawing.Point(14, 34)
$environmentCard.Size = New-Object System.Drawing.Size(310, 120)
$environmentCard.BackColor = $ColorPanel
$environmentCard.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$rightPanel.Controls.Add($environmentCard)

$environmentTitle = New-SectionTitle "Environment" 14 5 270
$environmentCard.Controls.Add($environmentTitle)

$rStatusDot = New-Object System.Windows.Forms.Label
$rStatusDot.Text = "●"
$rStatusDot.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$rStatusDot.ForeColor = $ColorWarning
$rStatusDot.Location = New-Object System.Drawing.Point(15, 31)
$rStatusDot.Size = New-Object System.Drawing.Size(22, 25)
$environmentCard.Controls.Add($rStatusDot)

$rStatusLabel = New-Object System.Windows.Forms.Label
$rStatusLabel.Text = "Checking R..."
$rStatusLabel.Font = $FontMedium
$rStatusLabel.ForeColor = $ColorText
$rStatusLabel.Location = New-Object System.Drawing.Point(40, 33)
$rStatusLabel.Size = New-Object System.Drawing.Size(245, 22)
$environmentCard.Controls.Add($rStatusLabel)

$rPathLabel = New-Object System.Windows.Forms.Label
$rPathLabel.Text = ""
$rPathLabel.Font = $FontSmall
$rPathLabel.ForeColor = $ColorTextMuted
$rPathLabel.Location = New-Object System.Drawing.Point(16, 56)
$rPathLabel.Size = New-Object System.Drawing.Size(275, 24)
$rPathLabel.AutoEllipsis = $true
$environmentCard.Controls.Add($rPathLabel)

$checkRButton = New-Object System.Windows.Forms.Button
$checkRButton.Text = "Check R"
$checkRButton.Location = New-Object System.Drawing.Point(15, 85)
$checkRButton.Size = New-Object System.Drawing.Size(125, 25)
Set-FlatButton $checkRButton
$checkRButton.Add_Click({
    Update-RStatus | Out-Null
})
$environmentCard.Controls.Add($checkRButton)

$installRButton = New-Object System.Windows.Forms.Button
$installRButton.Text = "Install R"
$installRButton.Location = New-Object System.Drawing.Point(154, 85)
$installRButton.Size = New-Object System.Drawing.Size(137, 25)
Set-FlatButton $installRButton
$installRButton.Add_Click({
    Install-R
})
$environmentCard.Controls.Add($installRButton)

$parametersCard = New-Object System.Windows.Forms.Panel
$parametersCard.Location = New-Object System.Drawing.Point(14, 165)
$parametersCard.Size = New-Object System.Drawing.Size(310, 150)
$parametersCard.BackColor = $ColorPanel
$parametersCard.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$rightPanel.Controls.Add($parametersCard)

$parametersTitle = New-SectionTitle "Analysis parameters" 14 5 270
$parametersCard.Controls.Add($parametersTitle)

$mapqLabel = New-Object System.Windows.Forms.Label
$mapqLabel.Text = "Minimum mapping quality"
$mapqLabel.Location = New-Object System.Drawing.Point(15, 35)
$mapqLabel.Size = New-Object System.Drawing.Size(155, 24)
$mapqLabel.ForeColor = $ColorText
$parametersCard.Controls.Add($mapqLabel)

$rSeqParameterToolTip = New-Object System.Windows.Forms.ToolTip
$rSeqParameterToolTip.AutoPopDelay = 16000
$rSeqParameterToolTip.InitialDelay = 400
$rSeqParameterToolTip.ReshowDelay = 120
$rSeqParameterToolTip.ShowAlways = $true

$rSeqParameterToolTip.SetToolTip($bamTextBox, 'Required coordinate-sorted BAM from the RNA Processing result. Use the BAM corresponding to the condition/replicates you want to analyze; a matching BAI is recommended for inspection.')
$rSeqParameterToolTip.SetToolTip($bamBrowseButton, 'Browse for the coordinate-sorted BAM file used for rSeqTU transcription-unit inference.')
$rSeqParameterToolTip.SetToolTip($gffTextBox, 'Required genome annotation matching the BAM reference. Accepted: .gff, .gff3, or .gtf. Contig names must match the BAM/reference FASTA.')
$rSeqParameterToolTip.SetToolTip($gffBrowseButton, 'Browse for the GFF/GFF3/GTF annotation corresponding to the BAM reference.')
$rSeqParameterToolTip.SetToolTip($fastaTextBox, 'Required genomic FASTA matching both BAM and annotation. Accepted: .fa, .fasta, or .fna.')
$rSeqParameterToolTip.SetToolTip($fastaBrowseButton, 'Browse for the genomic reference FASTA used to create the BAM.')
$rSeqParameterToolTip.SetToolTip($outputTextBox, 'Writable result folder for the rSeqTU analysis output.')
$rSeqParameterToolTip.SetToolTip($outputBrowseButton, 'Choose the folder where rSeqTU results should be saved.')
$rSeqParameterToolTip.SetToolTip($chromosomeTextBox, 'Optional contig/chromosome name. Leave blank to use the first chromosome/contig detected in the files.')

$script:ActiveRSeqParameterPopup = $null

function Hide-RSeqParameterPopup {
    if ($script:ActiveRSeqParameterPopup) {
        try { $script:ActiveRSeqParameterPopup.Close() } catch { }
        try { $script:ActiveRSeqParameterPopup.Dispose() } catch { }
        $script:ActiveRSeqParameterPopup = $null
    }
}

function Format-RSeqStructuredHelpText {
    param([System.Windows.Forms.RichTextBox]$Box, [string]$Title)
    if (-not $Box) { return }

    $regularFont = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    $boldFont = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $headingFont = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
    $titleFont = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
    $helpHeadingColor = [System.Drawing.Color]::FromArgb(42, 82, 52)
    $helpBodyColor = [System.Drawing.Color]::FromArgb(30, 42, 34)

    $Box.SelectAll()
    $Box.SelectionFont = $regularFont
    $Box.SelectionColor = $helpBodyColor

    if ($Title) {
        $titleIndex = $Box.Text.IndexOf($Title, [System.StringComparison]::Ordinal)
        if ($titleIndex -ge 0) {
            $Box.Select($titleIndex, $Title.Length)
            $Box.SelectionFont = $titleFont
            $Box.SelectionColor = $helpHeadingColor
        }
    }

    # Bold inline category prefixes when future parameter help uses the same
    # "Accepted range:" / "Recommended value:" convention as downstream modules.
    $prefixPattern = '(?m)^([A-Za-z][A-Za-z0-9 /+&().,_\-]{1,72}:)'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Box.Text, $prefixPattern)) {
        $Box.Select($match.Index, $match.Length)
        $Box.SelectionFont = $boldFont
        $Box.SelectionColor = $helpHeadingColor
    }

    # Standalone subsection names are rendered as real headings.
    $sectionPattern = '(?m)^([^\r\n:]{2,90})(?=\r?\n(?:What this setting controls:|Allowed range:|Recommended value:|When to change it:))'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Box.Text, $sectionPattern)) {
        $Box.Select($match.Index, $match.Length)
        $Box.SelectionFont = $headingFont
        $Box.SelectionColor = $helpHeadingColor
    }

    $Box.Select(0, 0)
}

function Show-RSeqParameterPopup {
    param([System.Windows.Forms.Control]$Anchor, [string]$Title, [string]$Message)

    Hide-RSeqParameterPopup
    $screen = [System.Windows.Forms.Screen]::FromControl($Anchor)
    $area = $screen.WorkingArea
    $popupWidth = [Math]::Min(520, [Math]::Max(350, ($area.Width - 30)))
    $fullText = "$Title`r`n`r`n$Message"
    $font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $measure = [System.Windows.Forms.TextRenderer]::MeasureText(
        $fullText,
        $font,
        ([System.Drawing.Size]::new(($popupWidth - 32), 2600)),
        ([System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix)
    )
    $popupHeight = [Math]::Min(560, [Math]::Max(190, ($measure.Height + 34)))

    $box = New-Object System.Windows.Forms.RichTextBox
    $box.Size = [System.Drawing.Size]::new(($popupWidth - 4), ($popupHeight - 4))
    $box.ReadOnly = $true
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $box.BackColor = [System.Drawing.Color]::White
    $box.ForeColor = $ColorText
    $box.Font = $font
    $box.WordWrap = $true
    $box.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
    $box.DetectUrls = $false
    $box.TabStop = $false
    $box.Text = $fullText
    Format-RSeqStructuredHelpText -Box $box -Title $Title

    # PowerShell variable names are case-insensitive; avoid "$host", which
    # conflicts with the built-in read-only $Host variable.
    $popupControlHost = New-Object System.Windows.Forms.ToolStripControlHost -ArgumentList $box
    $popupControlHost.AutoSize = $false
    $popupControlHost.Size = $box.Size
    $popupControlHost.Margin = New-Object System.Windows.Forms.Padding(0)

    $popup = New-Object System.Windows.Forms.ToolStripDropDown
    $popup.AutoSize = $false
    $popup.Padding = New-Object System.Windows.Forms.Padding(1)
    $popup.Size = [System.Drawing.Size]::new($popupWidth, $popupHeight)
    $popup.BackColor = $ColorBorder
    $popup.DropShadowEnabled = $true
    [void]$popup.Items.Add($popupControlHost)

    $point = $Anchor.PointToScreen([System.Drawing.Point]::new(($Anchor.Width + 6), 0))
    $x = $point.X
    if (($x + $popupWidth) -gt $area.Right) {
        $x = $Anchor.PointToScreen([System.Drawing.Point]::new((-1 * ($popupWidth + 6)), 0)).X
    }
    $x = [Math]::Max(($area.Left + 4), [Math]::Min($x, ($area.Right - $popupWidth - 4)))
    $y = [Math]::Max(($area.Top + 4), [Math]::Min($point.Y, ($area.Bottom - $popupHeight - 4)))

    $script:ActiveRSeqParameterPopup = $popup
    $popup.Show([System.Drawing.Point]::new($x, $y))
}

$mapqHelpButton = New-Object System.Windows.Forms.Button
$mapqHelpButton.Text = '?'
$mapqHelpButton.Location = New-Object System.Drawing.Point(174, 34)
$mapqHelpButton.Size = New-Object System.Drawing.Size(22, 22)
$mapqHelpButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$mapqHelpButton.FlatAppearance.BorderSize = 1
$mapqHelpButton.FlatAppearance.BorderColor = $ColorAccent
$mapqHelpButton.BackColor = $ColorPanelAlt
$mapqHelpButton.ForeColor = $ColorAccent
$mapqHelpButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$mapqHelpButton.TabStop = $false
$mapqHelpButton.Cursor = [System.Windows.Forms.Cursors]::Help
$mapqCirclePath = New-Object System.Drawing.Drawing2D.GraphicsPath
$mapqCirclePath.AddEllipse(0, 0, 21, 21)
$mapqHelpButton.Region = New-Object System.Drawing.Region($mapqCirclePath)
$mapqCirclePath.Dispose()
$mapqHelpText = @"
What this setting controls:
Minimum mapping quality is the lowest MAPQ accepted when rSeqTU builds coverage and feature summaries. Reads below the cutoff stay in the BAM but do not contribute to these derived signals.

Allowed range:
0 to 255. Practical bacterial RNA-seq range: 0 to 30.

Recommended value:
15 is the balanced default.

When to change it:
Use 0 to 5 for repeats, paralogs, divergent regions, or sensitivity. Use 10 to 15 for general work. Use 20 to 30 for strongly supported placements only.
"@
$mapqHelpButton.Tag = [pscustomobject]@{
    Title = 'Minimum mapping quality'
    Message = $mapqHelpText
}
$rSeqParameterToolTip.SetToolTip($mapqHelpButton, 'Hover to view the accepted range, recommended value, and when to change this setting.')
$mapqHelpButton.Add_MouseEnter({
    param($sender, $eventArgs)
    Show-RSeqParameterPopup -Anchor $sender -Title ([string]$sender.Tag.Title) -Message ([string]$sender.Tag.Message)
})
$mapqHelpButton.Add_MouseLeave({ Hide-RSeqParameterPopup })
$parametersCard.Controls.Add($mapqHelpButton)

$minMapqInput = New-Object System.Windows.Forms.NumericUpDown
$minMapqInput.Location = New-Object System.Drawing.Point(215, 32)
$minMapqInput.Size = New-Object System.Drawing.Size(75, 27)
$minMapqInput.Minimum = 0
$minMapqInput.Maximum = 255
$minMapqInput.Value = 15
$minMapqInput.BackColor = $ColorInput
$minMapqInput.ForeColor = $ColorText
$parametersCard.Controls.Add($minMapqInput)

$baseQualityLabel = New-Object System.Windows.Forms.Label
$baseQualityLabel.Text = "Minimum base quality"
$baseQualityLabel.Location = New-Object System.Drawing.Point(15, 68)
$baseQualityLabel.Size = New-Object System.Drawing.Size(155, 24)
$baseQualityLabel.ForeColor = $ColorText
$parametersCard.Controls.Add($baseQualityLabel)

$baseQualityHelpButton = New-Object System.Windows.Forms.Button
$baseQualityHelpButton.Text = '?'
$baseQualityHelpButton.Location = New-Object System.Drawing.Point(174, 67)
$baseQualityHelpButton.Size = New-Object System.Drawing.Size(22, 22)
$baseQualityHelpButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$baseQualityHelpButton.FlatAppearance.BorderSize = 1
$baseQualityHelpButton.FlatAppearance.BorderColor = $ColorAccent
$baseQualityHelpButton.BackColor = $ColorPanelAlt
$baseQualityHelpButton.ForeColor = $ColorAccent
$baseQualityHelpButton.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$baseQualityHelpButton.TabStop = $false
$baseQualityHelpButton.Cursor = [System.Windows.Forms.Cursors]::Help
$baseCirclePath = New-Object System.Drawing.Drawing2D.GraphicsPath
$baseCirclePath.AddEllipse(0, 0, 21, 21)
$baseQualityHelpButton.Region = New-Object System.Drawing.Region($baseCirclePath)
$baseCirclePath.Dispose()
$baseQualityHelpText = @"
What this setting controls:
Minimum base quality is the lowest per-base Phred score used when building coverage. Bases below the cutoff are ignored at that position.

Allowed range:
0 to 93. Practical range: 0 to 30.

Recommended value:
10 is the balanced default.

When to change it:
Use 0 to 5 for exploratory or lower-quality data. Use 10 for routine analysis. Use 20 to 30 for high-quality reads when specificity is more important than retaining every base.
"@
$baseQualityHelpButton.Tag = [pscustomobject]@{
    Title = 'Minimum base quality'
    Message = $baseQualityHelpText
}
$rSeqParameterToolTip.SetToolTip($baseQualityHelpButton, 'Hover to view the accepted range, recommended value, and when to change this setting.')
$baseQualityHelpButton.Add_MouseEnter({
    param($sender, $eventArgs)
    Show-RSeqParameterPopup -Anchor $sender -Title ([string]$sender.Tag.Title) -Message ([string]$sender.Tag.Message)
})
$baseQualityHelpButton.Add_MouseLeave({ Hide-RSeqParameterPopup })
$parametersCard.Controls.Add($baseQualityHelpButton)

$minBaseQualityInput = New-Object System.Windows.Forms.NumericUpDown
$minBaseQualityInput.Location = New-Object System.Drawing.Point(215, 65)
$minBaseQualityInput.Size = New-Object System.Drawing.Size(75, 27)
$minBaseQualityInput.Minimum = 0
$minBaseQualityInput.Maximum = 255
$minBaseQualityInput.Value = 10
$minBaseQualityInput.BackColor = $ColorInput
$minBaseQualityInput.ForeColor = $ColorText
$parametersCard.Controls.Add($minBaseQualityInput)

$parameterNote = New-Object System.Windows.Forms.Label
$parameterNote.Text = "Defaults: mapping quality 15; base quality 10. Change only when appropriate for your data."
$parameterNote.Font = $FontSmall
$parameterNote.ForeColor = $ColorTextMuted
$parameterNote.Location = New-Object System.Drawing.Point(15, 101)
$parameterNote.Size = New-Object System.Drawing.Size(275, 38)
$parametersCard.Controls.Add($parameterNote)

$outputCard = New-Object System.Windows.Forms.Panel
$outputCard.Location = New-Object System.Drawing.Point(14, 326)
$outputCard.Size = New-Object System.Drawing.Size(310, 132)
$outputCard.BackColor = $ColorPanel
$outputCard.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$rightPanel.Controls.Add($outputCard)

$outputTitle = New-SectionTitle "Retained outputs" 14 5 270
$outputCard.Controls.Add($outputTitle)

$outputText = New-Object System.Windows.Forms.Label
$outputText.Text = @"
✓ QC PDF and TU Excel workbook
✓ Cleaned SVM GFF and full log
✓ IGV Results: BAM, BAI, bedGraph,
  annotation and FASTA
Forward TUs: positive | Reverse TUs: negative
"@
$outputText.Font = $FontSmall
$outputText.ForeColor = $ColorTextMuted
$outputText.Location = New-Object System.Drawing.Point(15, 32)
$outputText.Size = New-Object System.Drawing.Size(275, 94)
$outputText.UseCompatibleTextRendering = $false
$outputCard.Controls.Add($outputText)

$sessionCard = New-Object System.Windows.Forms.Panel
$sessionCard.Size = New-Object System.Drawing.Size(324, 180)
$sessionCard.BackColor = $ColorPanel
$sessionCard.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$sessionTitle = New-SectionTitle "Samples run this session" 14 5 205
$sessionTitle.Font = $FontMedium
$sessionCard.Controls.Add($sessionTitle)

$sessionCountLabel = New-Object System.Windows.Forms.Label
$sessionCountLabel.Text = "0 runs"
$sessionCountLabel.Font = $FontSmall
$sessionCountLabel.ForeColor = $ColorTextDim
$sessionCountLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$sessionCountLabel.Location = New-Object System.Drawing.Point(220, 7)
$sessionCountLabel.Size = New-Object System.Drawing.Size(70, 20)
$sessionCard.Controls.Add($sessionCountLabel)

$sessionRunListBox = New-Object System.Windows.Forms.ListBox
$sessionRunListBox.Location = New-Object System.Drawing.Point(14, 31)
$sessionRunListBox.Size = New-Object System.Drawing.Size(294, 105)
$sessionRunListBox.Font = $FontSmall
$sessionRunListBox.ForeColor = $ColorText
$sessionRunListBox.BackColor = $ColorPanelAlt
$sessionRunListBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$sessionRunListBox.HorizontalScrollbar = $true
$sessionRunListBox.IntegralHeight = $false
$sessionRunListBox.Visible = $false
$sessionCard.Controls.Add($sessionRunListBox)

$sessionEmptyLabel = New-Object System.Windows.Forms.Label
$sessionEmptyLabel.Text = "No samples have been run yet."
$sessionEmptyLabel.Font = $FontSmall
$sessionEmptyLabel.ForeColor = $ColorTextMuted
$sessionEmptyLabel.Location = New-Object System.Drawing.Point(15, 43)
$sessionEmptyLabel.Size = New-Object System.Drawing.Size(290, 22)
$sessionCard.Controls.Add($sessionEmptyLabel)

$sessionNoteLabel = New-Object System.Windows.Forms.Label
$sessionNoteLabel.Text = "Return keeps this list; closing the Suite clears it."
$sessionNoteLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7.2)
$sessionNoteLabel.ForeColor = $ColorTextDim
$sessionNoteLabel.Location = New-Object System.Drawing.Point(14, 151)
$sessionNoteLabel.Size = New-Object System.Drawing.Size(294, 19)
$sessionNoteLabel.UseCompatibleTextRendering = $false
$sessionCard.Controls.Add($sessionNoteLabel)

# Bottom live log uses only the left and middle area
$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$logPanel.BackColor = $ColorPanel
$mainSplit.Panel2.Controls.Add($logPanel)

# Session history fills the inspector below Retained outputs
$sessionCard.Location = New-Object System.Drawing.Point(14, 470)
$sessionCard.Size = New-Object System.Drawing.Size(310, 300)
$sessionCard.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$rightPanel.Controls.Add($sessionCard)

$rightPanel.Add_Resize({
    $sessionCard.Left = 14
    $sessionCard.Top = 470
    $sessionCard.Width = [Math]::Max(180, $rightPanel.ClientSize.Width - 28)
    $sessionCard.Height = [Math]::Max(120, $rightPanel.ClientSize.Height - 484)
})

$sessionCard.Add_Resize({
    $sessionTitle.Width = [Math]::Max(130, $sessionCard.ClientSize.Width - 105)
    $sessionCountLabel.Left = $sessionCard.ClientSize.Width - 84
    $sessionRunListBox.Width = [Math]::Max(120, $sessionCard.ClientSize.Width - 28)
    $sessionRunListBox.Height = [Math]::Max(48, $sessionCard.ClientSize.Height - 75)
    $sessionEmptyLabel.Width = [Math]::Max(120, $sessionCard.ClientSize.Width - 30)
    $sessionNoteLabel.Top = $sessionCard.ClientSize.Height - 25
    $sessionNoteLabel.Width = [Math]::Max(120, $sessionCard.ClientSize.Width - 28)
})

$logHeader = New-Object System.Windows.Forms.Panel
$logHeader.Dock = [System.Windows.Forms.DockStyle]::Top
$logHeader.Height = 36
$logHeader.BackColor = $ColorSidebar
$logHeader.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$logPanel.Controls.Add($logHeader)

$logTitle = New-Object System.Windows.Forms.Label
$logTitle.Text = "Live R code and console"
$logTitle.Font = $FontMedium
$logTitle.ForeColor = $ColorText
$logTitle.Location = New-Object System.Drawing.Point(15, 8)
$logTitle.Size = New-Object System.Drawing.Size(120, 22)
$logHeader.Controls.Add($logTitle)

$clearLogButton = New-Object System.Windows.Forms.Button
$clearLogButton.Text = "Clear"
$clearLogButton.Dock = [System.Windows.Forms.DockStyle]::Right
$clearLogButton.Width = 82
Set-FlatButton $clearLogButton
$clearLogButton.Add_Click({ $logTextBox.Clear() })

$openLogFolderButton = New-Object System.Windows.Forms.Button
$openLogFolderButton.Text = "Open log folder"
$openLogFolderButton.Dock = [System.Windows.Forms.DockStyle]::Right
$openLogFolderButton.Width = 132
Set-FlatButton $openLogFolderButton
$openLogFolderButton.Add_Click({
    $candidate = if ($script:FullConsoleLogPath) { $script:FullConsoleLogPath } elseif ($script:RunLog) { $script:RunLog } else { $null }
    $folder = if ($candidate) { Split-Path -Parent $candidate } elseif ($outputTextBox.Text) { $outputTextBox.Text } else { $null }
    if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) { Start-Process explorer.exe $folder }
    else { [System.Windows.Forms.MessageBox]::Show($form, "No rSeqTU log folder exists yet.", "Log folder", 'OK', 'Information') | Out-Null }
})

$openLogFileButton = New-Object System.Windows.Forms.Button
$openLogFileButton.Text = "Open log file"
$openLogFileButton.Dock = [System.Windows.Forms.DockStyle]::Right
$openLogFileButton.Width = 118
Set-FlatButton $openLogFileButton
$openLogFileButton.Add_Click({
    $candidate = if ($script:FullConsoleLogPath -and (Test-Path -LiteralPath $script:FullConsoleLogPath -PathType Leaf)) { $script:FullConsoleLogPath } elseif ($script:RunLog -and (Test-Path -LiteralPath $script:RunLog -PathType Leaf)) { $script:RunLog } elseif ($script:RunErrorLog -and (Test-Path -LiteralPath $script:RunErrorLog -PathType Leaf)) { $script:RunErrorLog } else { $null }
    if ($candidate) { Start-Process -FilePath $candidate }
    else { [System.Windows.Forms.MessageBox]::Show($form, "No rSeqTU log file exists yet.", "Log file", 'OK', 'Information') | Out-Null }
})
$logHeader.Controls.AddRange(@($clearLogButton, $openLogFolderButton, $openLogFileButton))

$logTextBox = New-Object System.Windows.Forms.TextBox
$logTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$logTextBox.Multiline = $true
$logTextBox.ReadOnly = $true
$logTextBox.MaxLength = [int]::MaxValue
$logTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$logTextBox.WordWrap = $false
$logTextBox.BackColor = [System.Drawing.Color]::White
$logTextBox.ForeColor = $ColorText
$logTextBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$logTextBox.Font = $FontMono
$logPanel.Controls.Add($logTextBox)
$logTextBox.BringToFront()

# Timer
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 700

$timer.Add_Tick({
    Refresh-Log
    Read-BackendStatus

    if (
        $script:RunningProcess -and
        $script:RunningProcess.HasExited
    ) {
        $timer.Stop()

        $exitCode = $script:RunningProcess.ExitCode

        try {
            $script:RunningProcess.Dispose()
        } catch {}

        $script:RunningProcess = $null

        Refresh-Log
        Read-BackendStatus
        Set-RunningState $false

        foreach ($completedTemporaryFile in @($script:RunConfig, $script:RunWrapperScript)) {
            if ($completedTemporaryFile -and (Test-Path -LiteralPath $completedTemporaryFile)) {
                Remove-Item `
                    -LiteralPath $completedTemporaryFile `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }

        if ($script:StopRequested) {
            return
        }

        # The backend verifies all final outputs before writing its 100%
        # Finished marker. Windows can occasionally return a non-zero process
        # exit code after a successful R run, so use the verified backend
        # marker and retained files as the source of truth.
        $completedSuccessfully = Test-RunCompletedSuccessfully

        if ($completedSuccessfully) {
            Apply-WorkflowProgress `
                4 `
                "Finished" `
                "All outputs completed"

            Update-EstimatedProgress `
                100 `
                "All requested outputs were created successfully" `
                "Finished"

            $runStatusLabel.Text = "Pipeline completed successfully."
            $runStatusLabel.ForeColor = $ColorSuccess
            $headerRunStateLabel.Text = "Completed"
            $headerRunStateLabel.ForeColor = $ColorSuccess

            Add-SessionRun -State "Completed"

            $exportedConsoleLog = Export-FullConsoleLog `
                -FinalState "Completed" `
                -ExitCode $exitCode

            foreach (
                $temporaryLog in
                @(
                    $script:RunLog,
                    $script:RunErrorLog,
                    $script:StatusFile,
                    $script:RunWrapperScript
                )
            ) {
                if (
                    $temporaryLog -and
                    (Test-Path $temporaryLog)
                ) {
                    Remove-Item `
                        -LiteralPath $temporaryLog `
                        -Force `
                        -ErrorAction SilentlyContinue
                }
            }

            Show-CompletionDialog
        } else {
            Apply-WorkflowProgress `
                $script:CurrentWorkflowStep `
                "Error" `
                "Pipeline stopped with an error"

            Update-EstimatedProgress `
                $script:CurrentPercent `
                "Pipeline stopped with an error" `
                "Error"

            $runStatusLabel.Text = "Pipeline stopped. Review the log."
            $runStatusLabel.ForeColor = $ColorError
            $headerRunStateLabel.Text = "Error"
            $headerRunStateLabel.ForeColor = $ColorError

            Add-SessionRun -State "Error"

            $savedErrorLog = Export-FullConsoleLog `
                -FinalState "Error" `
                -ExitCode $exitCode

            if (-not $savedErrorLog) {
                $savedErrorLog = "The full console log could not be exported."
            }

            [System.Media.SystemSounds]::Hand.Play()

            $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $form.Activate()
            $form.BringToFront()

            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "The pipeline ended without a verified 100% completion marker or one or more required output files were missing.`r`n`r`nWindows process exit code: $exitCode`r`n`r`nA diagnostic log was saved as:`r`n$savedErrorLog",
                "Pipeline error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    }
})

$form.Add_FormClosing({
    if (
        $script:RunningProcess -and
        -not $script:RunningProcess.HasExited
    ) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $form,
            "The pipeline is still running. Stop it, delete files created by this run, and close the application?",
            "Pipeline running",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if (
            $answer -ne
            [System.Windows.Forms.DialogResult]::Yes
        ) {
            $_.Cancel = $true
            return
        }

        $script:StopRequested = $true
        $timer.Stop()

        try {
            $processId = $script:RunningProcess.Id

            Start-Process `
                -FilePath "taskkill.exe" `
                -ArgumentList @(
                    "/PID",
                    [string]$processId,
                    "/T",
                    "/F"
                ) `
                -WindowStyle Hidden `
                -Wait `
                -ErrorAction SilentlyContinue |
                Out-Null
        } catch {
            try {
                Stop-Process `
                    -Id $script:RunningProcess.Id `
                    -Force `
                    -ErrorAction SilentlyContinue
            } catch {}
        }

        Cleanup-CancelledRun
    }
})

$form.Add_FormClosed({
    if ($script:SuiteSignalTimer) {
        try { $script:SuiteSignalTimer.Dispose() } catch { }
    }
    Remove-SuiteApplicationArtifacts
})

$centerScroll.Add_Resize({
    $availableWidth = $centerScroll.ClientSize.Width - 20

    if ($availableWidth -lt 680) {
        $availableWidth = 680
    }

    $analysisCard.Width = $availableWidth
    $analysisCard.Left = 10
    $analysisCard.Top = 8
})

$progressTrack.Add_Resize({
    $trackWidth = $progressTrack.ClientSize.Width
    $fillWidth = [Math]::Floor(
        $trackWidth * ($script:CurrentPercent / 100.0)
    )

    if ($fillWidth -lt 0) {
        $fillWidth = 0
    }

    $progressFill.Width = $fillWidth
})

$form.Add_Shown({
    [RSeqTUNative]::SendMessage(
        $chromosomeTextBox.Handle,
        [RSeqTUNative]::EM_SETCUEBANNER,
        [IntPtr]1,
        "Optional, please input your chromosome name in FASTA and annotation files in the box"
    ) | Out-Null

    Update-RStatus | Out-Null
    Update-SessionRunPanel

    if (-not $script:RscriptPath) {
        Install-R
    }
})

Reset-Workflow
Update-EstimatedProgress 0 "Estimated completion will appear here." "Ready"

if ($script:SuiteManaged) {
    Write-SuiteApplicationMarker -Hidden $false
    Start-SuiteSignalMonitor
}

Apply-NeutralSelectionTheme $form

if ($script:EmbeddedMode) {
    $form.TopLevel = $false
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.MinimumSize = New-Object System.Drawing.Size(0, 0)
    $form.Dock = [System.Windows.Forms.DockStyle]::Fill
    $form.ShowInTaskbar = $false
    [void]$script:EmbeddedHost.Controls.Add($form)
    $form.Show()
    while (-not $form.IsDisposed -and $form.Visible) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 20
    }
    if (-not $form.IsDisposed) {
        $script:EmbeddedHost.Controls.Remove($form)
        $form.Dispose()
    }
}
else {
    [void]$form.ShowDialog()
}
