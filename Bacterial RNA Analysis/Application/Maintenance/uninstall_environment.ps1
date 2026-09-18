[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class BacterialRnaNativeWindow {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
}
'@

$script:MaintenanceRoot = $PSScriptRoot
$script:ApplicationRoot = Split-Path -Parent $PSScriptRoot
$script:PackageRoot = Split-Path -Parent $script:ApplicationRoot

function Get-WslDistros {
    try {
        return @(& wsl.exe --list --quiet 2>$null | ForEach-Object { ([string]$_).Replace(([char]0).ToString(), [string]::Empty).Trim() } | Where-Object { $_ })
    }
    catch { return @() }
}

function Invoke-WslBash([string]$Distro, [string]$Command) {
    if ([string]::IsNullOrWhiteSpace($Distro)) { throw 'No WSL distribution is selected.' }
    $tempScript = Join-Path $env:TEMP ('bacterial_rna_remove_' + [guid]::NewGuid().ToString('N') + '.sh')
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempScript, "#!/usr/bin/env bash`nset -Eeuo pipefail`n$Command`n", $utf8NoBom)
    try {
        $linuxScript = (& wsl.exe -d $Distro -- wslpath -a -u $tempScript 2>$null | Select-Object -First 1)
        $linuxScript = ([string]$linuxScript).Replace(([char]0).ToString(), [string]::Empty).Trim()
        if (-not $linuxScript) { throw 'Could not translate the temporary removal script into a WSL path.' }
        $process = Start-Process -FilePath 'wsl.exe' -ArgumentList @('-d', $Distro, '--', '/bin/bash', $linuxScript) -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -ne 0) { throw "Linux removal command exited with code $($process.ExitCode)." }
    }
    finally { Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue }
}

function Add-Log([System.Windows.Forms.RichTextBox]$Box, [string]$Text) {
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $Box.AppendText("[$stamp] $Text`r`n")
    $Box.SelectionStart = $Box.TextLength
    $Box.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function New-Check([string]$Text, [int]$Top, [string]$Help) {
    $check = New-Object System.Windows.Forms.CheckBox
    $check.Text = $Text
    $check.Location = New-Object System.Drawing.Point(22, $Top)
    $check.Size = New-Object System.Drawing.Size(650, 28)
    $check.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $toolTip.SetToolTip($check, $Help)
    return $check
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Remove Bacterial RNA Analysis components'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(760, 690)
$form.MinimumSize = New-Object System.Drawing.Size(776, 729)
$form.BackColor = [System.Drawing.Color]::FromArgb(247, 249, 248)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AutoScaleMode = 'Dpi'

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 18000
$toolTip.InitialDelay = 300

$title = New-Object System.Windows.Forms.Label
$title.Text = 'SELECT WHAT TO REMOVE'
$title.Location = New-Object System.Drawing.Point(22, 18)
$title.Size = New-Object System.Drawing.Size(700, 30)
$title.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::FromArgb(30, 92, 54)
$form.Controls.Add($title)

$intro = New-Object System.Windows.Forms.Label
$intro.Text = 'Nothing is selected by default. Analysis results outside this extracted package are never deleted. Hover over an option for details.'
$intro.Location = New-Object System.Drawing.Point(24, 54)
$intro.Size = New-Object System.Drawing.Size(700, 42)
$intro.ForeColor = [System.Drawing.Color]::FromArgb(55, 61, 57)
$form.Controls.Add($intro)

$distroLabel = New-Object System.Windows.Forms.Label
$distroLabel.Text = 'WSL distribution'
$distroLabel.Location = New-Object System.Drawing.Point(24, 103)
$distroLabel.Size = New-Object System.Drawing.Size(145, 26)
$form.Controls.Add($distroLabel)
$distroBox = New-Object System.Windows.Forms.ComboBox
$distroBox.DropDownStyle = 'DropDownList'
$distroBox.Location = New-Object System.Drawing.Point(172, 100)
$distroBox.Size = New-Object System.Drawing.Size(270, 28)
$distros = @(Get-WslDistros)
foreach ($d in $distros) { [void]$distroBox.Items.Add($d) }
$record = Join-Path $script:ApplicationRoot 'App\environment\.wsl_distro'
if (Test-Path -LiteralPath $record) {
    $saved = ([System.IO.File]::ReadAllText($record)).Trim()
    if ($saved -and $distroBox.Items.Contains($saved)) { $distroBox.SelectedItem = $saved }
}
if ($distroBox.SelectedIndex -lt 0 -and $distroBox.Items.Count -gt 0) { $distroBox.SelectedIndex = 0 }
$form.Controls.Add($distroBox)

$core = New-Check 'Core RNA-seq Conda environment (prok-rnaseq)' 145 'Removes only the core Conda environment used for read QC, alignment, counts and coverage. The dedicated Miniforge installation remains.'
$downstream = New-Check 'Differential expression, GO and network environment (prok-rnaseq-downstream)' 179 'Removes the downstream R/Python Conda environment used by DE, enrichment, networks and the visualization studio.'
$opdetect = New-Check 'OpDetect Conda environment (opdetect-pipeline)' 213 'Removes the OpDetect environment from the separate ~/miniforge3 installation when present.'
$optional = New-Check 'Downloaded optional tools, package logs and temporary state' 247 'Removes package-local FADU/LongQC downloads, Logs, and temporary shared-state files. It does not remove project result folders.'
$coreMiniforge = New-Check 'Entire dedicated core Miniforge folder (~/.local/share/prok-rnaseq/miniforge3)' 281 'Removes only the suite-dedicated Miniforge installation and every Conda environment stored inside it. The Shared Database Library under ~/.local/share/prok-rnaseq/Database Library is preserved.'
$opdetectMiniforge = New-Check 'Entire OpDetect Miniforge folder (~/miniforge3)' 315 'Removes the complete ~/miniforge3 installation. Do not select this if other software uses that Miniforge installation.'
$wslDistro = New-Check 'Entire selected WSL distribution — DANGER: deletes all Linux files' 349 'Unregisters the selected WSL distribution. This permanently deletes every file and environment inside that Linux distribution, including data unrelated to this suite.'
$package = New-Check 'This extracted Bacterial RNA Analysis package' 383 'Closes the main suite and schedules deletion of this complete extracted package folder. Project result folders saved elsewhere are not deleted.'
foreach ($c in @($core,$downstream,$opdetect,$optional,$coreMiniforge,$opdetectMiniforge,$wslDistro,$package)) { $form.Controls.Add($c) }
$wslDistro.ForeColor = [System.Drawing.Color]::DarkRed
$package.ForeColor = [System.Drawing.Color]::DarkRed

$warning = New-Object System.Windows.Forms.Label
$warning.Text = 'Recommended: remove individual environments first. Remove Miniforge or the WSL distribution only when you are certain it is not shared with other work.'
$warning.Location = New-Object System.Drawing.Point(24, 421)
$warning.Size = New-Object System.Drawing.Size(700, 42)
$warning.BackColor = [System.Drawing.Color]::FromArgb(255, 246, 220)
$warning.Padding = New-Object System.Windows.Forms.Padding(9)
$warning.ForeColor = [System.Drawing.Color]::FromArgb(105, 70, 12)
$form.Controls.Add($warning)

$log = New-Object System.Windows.Forms.RichTextBox
$log.Location = New-Object System.Drawing.Point(24, 472)
$log.Size = New-Object System.Drawing.Size(710, 142)
$log.Anchor = 'Left,Right,Top,Bottom'
$log.ReadOnly = $true
$log.BackColor = [System.Drawing.Color]::White
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$log.Text = "Ready. No component is selected.`r`n"
$form.Controls.Add($log)

$remove = New-Object System.Windows.Forms.Button
$remove.Text = 'Remove selected components'
$remove.Location = New-Object System.Drawing.Point(430, 628)
$remove.Size = New-Object System.Drawing.Size(210, 40)
$remove.Anchor = 'Right,Bottom'
$remove.BackColor = [System.Drawing.Color]::FromArgb(62, 132, 78)
$remove.ForeColor = [System.Drawing.Color]::White
$remove.FlatStyle = 'Flat'
$remove.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($remove)
$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Close'
$cancel.Location = New-Object System.Drawing.Point(650, 628)
$cancel.Size = New-Object System.Drawing.Size(84, 40)
$cancel.Anchor = 'Right,Bottom'
$form.Controls.Add($cancel)
$cancel.Add_Click({ $form.Close() })

$remove.Add_Click({
    $selected = @()
    if ($core.Checked) { $selected += 'Core RNA-seq environment' }
    if ($downstream.Checked) { $selected += 'Downstream DE/GO/network environment' }
    if ($opdetect.Checked) { $selected += 'OpDetect environment' }
    if ($optional.Checked) { $selected += 'Optional tools, logs and temporary state' }
    if ($coreMiniforge.Checked) { $selected += 'Entire dedicated core Miniforge folder' }
    if ($opdetectMiniforge.Checked) { $selected += 'Entire OpDetect Miniforge folder' }
    if ($wslDistro.Checked) { $selected += 'ENTIRE WSL DISTRIBUTION' }
    if ($package.Checked) { $selected += 'THIS EXTRACTED SOFTWARE PACKAGE' }
    if ($selected.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'Select at least one component to remove.', 'Nothing selected', 'OK', 'Information')
        return
    }
    $confirmText = "The following components will be removed:`r`n`r`n• " + ($selected -join "`r`n• ") + "`r`n`r`nThis cannot be undone. Continue?"
    $answer = [System.Windows.Forms.MessageBox]::Show($form, $confirmText, 'Confirm removal', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    $remove.Enabled = $false
    $distro = if ($distroBox.SelectedItem) { [string]$distroBox.SelectedItem } else { '' }
    try {
        if (($core.Checked -or $downstream.Checked -or $opdetect.Checked -or $coreMiniforge.Checked -or $opdetectMiniforge.Checked) -and -not $distro) {
            throw 'A WSL distribution is required for the selected environment removal.'
        }
        if ($core.Checked -and -not $coreMiniforge.Checked) {
            Add-Log $log 'Removing prok-rnaseq...'
            Invoke-WslBash $distro 'root="$HOME/.local/share/prok-rnaseq/miniforge3"; if [ -x "$root/bin/conda" ]; then "$root/bin/conda" env remove -n prok-rnaseq -y || true; fi'
        }
        if ($downstream.Checked) {
            Add-Log $log 'Removing prok-rnaseq-downstream...'
            Invoke-WslBash $distro 'for root in "$HOME/.local/share/prok-rnaseq/miniforge3" "$HOME/miniforge3"; do if [ -x "$root/bin/conda" ]; then "$root/bin/conda" env remove -n prok-rnaseq-downstream -y || true; fi; done'
        }
        if ($opdetect.Checked -and -not $opdetectMiniforge.Checked) {
            Add-Log $log 'Removing opdetect-pipeline...'
            Invoke-WslBash $distro 'root="$HOME/miniforge3"; if [ -x "$root/bin/conda" ]; then "$root/bin/conda" env remove -n opdetect-pipeline -y || true; fi'
        }
        if ($coreMiniforge.Checked) {
            Add-Log $log 'Removing the dedicated core Miniforge folder...'
            Invoke-WslBash $distro 'rm -rf "$HOME/.local/share/prok-rnaseq/miniforge3"'
        }
        if ($opdetectMiniforge.Checked) {
            Add-Log $log 'Removing the OpDetect Miniforge folder...'
            Invoke-WslBash $distro 'rm -rf "$HOME/miniforge3"'
        }
        if ($optional.Checked) {
            Add-Log $log 'Removing package-local optional tools, logs and temporary state...'
            foreach ($path in @(
                (Join-Path $script:ApplicationRoot 'App\tools'),
                (Join-Path $script:ApplicationRoot 'Logs'),
                (Join-Path $script:ApplicationRoot 'Modules\Shared Analysis State')
            )) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
            }
            foreach ($file in @(
                (Join-Path $script:ApplicationRoot 'App\environment\.wsl_distro'),
                (Join-Path $script:ApplicationRoot 'App\environment\.miniforge_location')
            )) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        }
        if ($wslDistro.Checked) {
            if (-not $distro) { throw 'Select the WSL distribution to unregister.' }
            $second = [System.Windows.Forms.MessageBox]::Show($form, "FINAL WARNING: unregistering '$distro' permanently deletes all files in that Linux distribution. Continue?", 'Delete WSL distribution', 'YesNo', 'Error')
            if ($second -ne 'Yes') { Add-Log $log 'WSL distribution removal canceled.' }
            else {
                Add-Log $log "Unregistering WSL distribution $distro..."
                $p = Start-Process -FilePath 'wsl.exe' -ArgumentList @('--unregister', $distro) -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -ne 0) { throw "WSL unregister exited with code $($p.ExitCode)." }
            }
        }
        Add-Log $log 'Selected environment components were removed successfully.'
        if ($package.Checked) {
            Add-Log $log 'Closing the main Bacterial RNA Analysis window and scheduling package deletion...'
            $mainWindow = [BacterialRnaNativeWindow]::FindWindow($null, 'Bacterial RNA Analysis')
            if ($mainWindow -ne [IntPtr]::Zero) { [void][BacterialRnaNativeWindow]::PostMessage($mainWindow, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
            $tempBat = Join-Path $env:TEMP ('remove_bacterial_rna_analysis_' + [guid]::NewGuid().ToString('N') + '.cmd')
            $escapedRoot = $script:PackageRoot.Replace('%','%%')
            $batch = "@echo off`r`ntimeout /t 3 /nobreak >nul`r`nfor /l %%I in (1,1,120) do (`r`n  rmdir /s /q `"$escapedRoot`" 2>nul`r`n  if not exist `"$escapedRoot`" exit /b 0`r`n  timeout /t 1 /nobreak >nul`r`n)`r`ndel /q `"%~f0`"`r`n"
            [System.IO.File]::WriteAllText($tempBat, $batch, [System.Text.Encoding]::ASCII)
            Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'start', '""', '/min', $tempBat) -WindowStyle Hidden
            [void][System.Windows.Forms.MessageBox]::Show($form, 'The main application was asked to close. The extracted package will be deleted automatically after this utility exits.', 'Package removal scheduled', 'OK', 'Information')
            $form.Close()
            return
        }
        [void][System.Windows.Forms.MessageBox]::Show($form, 'The selected components were removed.', 'Removal complete', 'OK', 'Information')
    }
    catch {
        Add-Log $log ('ERROR: ' + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Removal error', 'OK', 'Error')
    }
    finally { if (-not $form.IsDisposed) { $remove.Enabled = $true } }
})

[void]$form.ShowDialog()
