[CmdletBinding()]
# GUI layout revision: balanced analysis settings, larger bold table headers,
# wider live log, genome-browser track export, reset support, and a session-only completed-sample history panel.
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()


$script:NeutralSurfaceColor = [System.Drawing.Color]::White
$script:NeutralInkColor = [System.Drawing.Color]::FromArgb(30, 42, 34)
$script:NeutralSelectionColor = [System.Drawing.Color]::FromArgb(230, 242, 232)

function Enable-NeutralComboBox {
    param([System.Windows.Forms.ComboBox]$Combo)
    if (-not $Combo) { return }
    if ($Combo.DrawMode -ne [System.Windows.Forms.DrawMode]::OwnerDrawFixed) {
        $Combo.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
        $Combo.ItemHeight = 22
        $Combo.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
        $Combo.BackColor = $script:NeutralSurfaceColor
        $Combo.ForeColor = $script:NeutralInkColor
        $Combo.Add_DrawItem({
            param($sender, $e)
            $isEdit = (($e.State -band [System.Windows.Forms.DrawItemState]::ComboBoxEdit) -ne 0)
            $selected = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0) -and (-not $isEdit)
            $back = if ($selected) { $script:NeutralSelectionColor } else { $script:NeutralSurfaceColor }
            $brush = New-Object System.Drawing.SolidBrush($back)
            try { $e.Graphics.FillRectangle($brush, $e.Bounds) } finally { $brush.Dispose() }
            $text = ''
            if ($e.Index -ge 0 -and $e.Index -lt $sender.Items.Count) { $text = [string]$sender.Items[$e.Index] }
            elseif ($sender.SelectedIndex -ge 0 -and $sender.SelectedIndex -lt $sender.Items.Count) { $text = [string]$sender.Items[$sender.SelectedIndex] }
            elseif ($sender.Text) { $text = [string]$sender.Text }
            $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $text, $sender.Font, $e.Bounds, $script:NeutralInkColor, $back, $flags)
        })
    }
}

function Enable-NeutralListBox {
    param([System.Windows.Forms.ListBox]$List)
    if (-not $List) { return }
    if ($List.DrawMode -ne [System.Windows.Forms.DrawMode]::OwnerDrawFixed) {
        $List.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
        $List.ItemHeight = 20
        $List.BackColor = $script:NeutralSurfaceColor
        $List.ForeColor = $script:NeutralInkColor
        $List.Add_DrawItem({
            param($sender, $e)
            if ($e.Index -lt 0) { return }
            $selected = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
            $back = if ($selected) { $script:NeutralSelectionColor } else { $script:NeutralSurfaceColor }
            $brush = New-Object System.Drawing.SolidBrush($back)
            try { $e.Graphics.FillRectangle($brush, $e.Bounds) } finally { $brush.Dispose() }
            $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$sender.Items[$e.Index], $sender.Font, $e.Bounds, $script:NeutralInkColor, $back, $flags)
        })
    }
}

function Set-NeutralGridSelection {
    param([System.Windows.Forms.DataGridView]$Grid)
    if (-not $Grid) { return }
    foreach ($style in @($Grid.DefaultCellStyle, $Grid.RowsDefaultCellStyle, $Grid.AlternatingRowsDefaultCellStyle)) {
        $style.SelectionBackColor = $script:NeutralSelectionColor
        $style.SelectionForeColor = $script:NeutralInkColor
    }
    $Grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $Grid.ColumnHeadersDefaultCellStyle.BackColor
    $Grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $Grid.ColumnHeadersDefaultCellStyle.ForeColor
    $Grid.RowHeadersDefaultCellStyle.SelectionBackColor = $script:NeutralSelectionColor
    $Grid.RowHeadersDefaultCellStyle.SelectionForeColor = $script:NeutralInkColor
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

$StartupLogDirectory = Join-Path $env:LOCALAPPDATA "OpDetect"
$StartupLogPath = Join-Path $StartupLogDirectory "startup.log"
try { [void](New-Item -ItemType Directory -Force -Path $StartupLogDirectory) } catch { }
function Write-StartupLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $StartupLogPath -Value ("{0:yyyy-MM-dd HH:mm:ss.fff}  {1}" -f (Get-Date), $Message) -Encoding UTF8
    }
    catch { }
}
Write-StartupLog "GUI script started from $PSScriptRoot"
trap {
    $startupError = $_.Exception.ToString()
    Write-StartupLog ("UNHANDLED ERROR: " + $startupError)
    try {
        [void][System.Windows.Forms.MessageBox]::Show(
            "OpDetect could not open its graphical window.`n`n$startupError`n`nStartup log:`n$StartupLogPath",
            "OpDetect startup error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
    catch { }
    break
}

$AppIconPath = Join-Path $PSScriptRoot "assets\opdetect.ico"
$script:AppIcon = $null
if (Test-Path -LiteralPath $AppIconPath) {
    try {
        $script:AppIcon = New-Object System.Drawing.Icon($AppIconPath)
    }
    catch {
        $script:AppIcon = $null
    }
}

$ManagedDistro = $null
$DistroPreferenceFile = Join-Path $PSScriptRoot ".opdetect_wsl_distro"
$SharedDistroPreferenceFile = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\Shared Analysis State\wsl_distro.txt'))
$CoreDistroPreferenceFile = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\..\App\environment\.wsl_distro'))
$EnvironmentVerifiedFile = Join-Path $PSScriptRoot ".environment_verified"
$EnvironmentStatusLogPath = Join-Path $StartupLogDirectory "environment_status.log"
$PipelineRoot = "/root/opdetect_pipeline"
$script:LastBrowseFolder = [Environment]::GetFolderPath("MyDocuments")
$script:RunState = $null
$script:RunTimer = $null
$script:AppendRunChunk = $null
$script:SuiteManaged = $false
$script:SuiteSignalTimer = $null
$script:SuiteShutdownRequested = $false
$script:EmbeddedHost = $null
try {
    $script:EmbeddedHost = Get-Variable -Name BacterialRNAAnalysisEmbeddedHost -Scope Global -ValueOnly -ErrorAction Stop
}
catch { }
$script:EmbeddedMode = $null -ne $script:EmbeddedHost

function Show-ErrorMessage {
    param([string]$Message)
    [void][System.Windows.Forms.MessageBox]::Show(
        $Message,
        "OpDetect",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
}

function Show-InfoMessage {
    param([string]$Message)
    [void][System.Windows.Forms.MessageBox]::Show(
        $Message,
        "OpDetect",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Text
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

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
    $script:SuiteRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '..\..\..')
    )
    $script:SuiteLauncherPath = Join-Path $script:SuiteRoot 'Operon Prediction Suite.exe'
    $script:SuiteManaged = Test-Path -LiteralPath $script:SuiteLauncherPath -PathType Leaf

    if (-not $script:SuiteManaged) {
        return
    }

    $script:SuiteSessionDirectory = Get-SuiteSessionDirectory -Root $script:SuiteRoot
    [void][System.IO.Directory]::CreateDirectory($script:SuiteSessionDirectory)
    $script:SuiteMarkerPath = Join-Path $script:SuiteSessionDirectory 'OpDetect.json'
    $script:SuiteShowSignalPath = Join-Path $script:SuiteSessionDirectory 'OpDetect.show'
    $script:SuiteHideSignalPath = Join-Path $script:SuiteSessionDirectory 'OpDetect.hide'
    $script:SuiteShutdownSignalPath = Join-Path $script:SuiteSessionDirectory 'OpDetect.shutdown'
}

function Write-SuiteApplicationMarker {
    param([bool]$Hidden)

    if (-not $script:SuiteManaged) {
        return
    }

    $currentProcess = Get-Process -Id $PID -ErrorAction Stop
    $metadata = [ordered]@{
        App = 'OpDetect'
        ProcessId = $PID
        StartTimeUtcTicks = [string]$currentProcess.StartTime.ToUniversalTime().Ticks
        SuiteRoot = $script:SuiteRoot
        Hidden = $Hidden
    }
    Write-Utf8NoBom -Path $script:SuiteMarkerPath -Text ($metadata | ConvertTo-Json -Compress)
}

function Remove-SuiteApplicationArtifacts {
    if (-not $script:SuiteManaged) {
        return
    }

    foreach ($path in @(
        $script:SuiteMarkerPath,
        $script:SuiteShowSignalPath,
        $script:SuiteHideSignalPath,
        $script:SuiteShutdownSignalPath
    )) {
        try {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                [System.IO.File]::Delete($path)
            }
        }
        catch { }
    }
}

function Return-ToPredictionSuite {
    try {
        if ($script:RunState -and -not $script:RunState.Finished) {
            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                'OpDetect is still running. Use STOP RUN and wait for the run to finish stopping before returning to the Prediction Suite.',
                'OpDetect is running',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }
        if ($script:EmbeddedMode) {
            $form.Hide()
            return
        }
        if (-not $script:SuiteManaged) {
            throw 'Operon Prediction Suite.exe was not found. This button is available in the complete extracted Prediction Suite.'
        }

        Write-SuiteApplicationMarker -Hidden $true

        try {
            [void](Start-Process `
                -FilePath $script:SuiteLauncherPath `
                -WorkingDirectory $script:SuiteRoot `
                -PassThru)
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
        Show-ErrorMessage $_.Exception.Message
    }
}


function Return-ToAnalysisModules {
    if ($script:RunState -and -not $script:RunState.Finished) {
        [void][System.Windows.Forms.MessageBox]::Show(
            $form,
            'OpDetect is still running. Use STOP RUN before returning to the analysis modules.',
            'OpDetect is running',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }
    if ($script:EmbeddedMode) {
        $global:BacterialRNAAnalysisReturnTarget = 'home'
        $form.Hide()
        return
    }
    Show-InfoMessage 'Open OpDetect from Bacterial RNA Analysis to use the direct analysis-module return button.'
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

function Get-CleanWslOutput {
    param([object[]]$Lines)
    return @($Lines | ForEach-Object {
        ([string]$_).Replace(([char]0).ToString(), [string]::Empty).Trim()
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-WslDistroRecords {
    $records = @()

    # The WSL registry is more reliable than parsing wsl.exe output on
    # Windows PowerShell 5.1, where UTF-16 output can be decoded incorrectly.
    $registryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (Test-Path -LiteralPath $registryPath) {
        try {
            foreach ($key in Get-ChildItem -LiteralPath $registryPath -ErrorAction Stop) {
                $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                $name = [string]$item.DistributionName
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    $version = 0
                    if ($null -ne $item.Version) {
                        $version = [int]$item.Version
                    }
                    $records += [pscustomobject]@{
                        Name = $name.Trim()
                        Version = $version
                    }
                }
            }
        }
        catch { }
    }

    if ($records.Count -eq 0) {
        try {
            $output = & wsl.exe --list --quiet 2>$null
            if ($LASTEXITCODE -eq 0) {
                foreach ($name in @(Get-CleanWslOutput $output)) {
                    $records += [pscustomobject]@{ Name = $name; Version = 0 }
                }
            }
        }
        catch { }
    }

    $unique = @{}
    foreach ($record in $records) {
        $key = $record.Name.ToLowerInvariant()
        if (-not $unique.ContainsKey($key)) {
            $unique[$key] = $record
        }
        elseif ($unique[$key].Version -eq 0 -and $record.Version -in @(1, 2)) {
            $unique[$key] = $record
        }
    }
    return @($unique.Values)
}

function Get-InstalledDistros {
    return @(Get-WslDistroRecords | ForEach-Object { $_.Name } | Sort-Object -Unique)
}

function Get-DistroVersion {
    param([string]$Distro)

    $record = @(Get-WslDistroRecords | Where-Object { $_.Name -ieq $Distro } | Select-Object -First 1)
    if ($record.Count -gt 0 -and $record[0].Version -in @(1, 2)) {
        return [int]$record[0].Version
    }

    try {
        $rows = @(Get-CleanWslOutput (& wsl.exe --list --verbose 2>$null))
        $escaped = [regex]::Escape($Distro)
        $row = $rows | Where-Object { $_ -match "(?i)(^|\s|\*)$escaped(\s|$)" } | Select-Object -First 1
        if ($row -and $row -match '\s([12])\s*$') {
            return [int]$Matches[1]
        }
    }
    catch { }
    return 0
}

function Test-DistroRunnable {
    param([string]$Distro)
    if ([string]::IsNullOrWhiteSpace($Distro)) { return $false }
    try {
        & wsl.exe -d $Distro -u root -- sh -lc 'exit 0' *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Restart-WslHostServiceIfElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return $false }
        foreach ($serviceName in @('WslService', 'LxssManager')) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -eq $service) { continue }
            if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
                Restart-Service -Name $serviceName -Force -ErrorAction Stop
            }
            else {
                Start-Service -Name $serviceName -ErrorAction Stop
            }
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            try { $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(20)) } catch { }
            Start-Sleep -Milliseconds 3000
            return $true
        }
    }
    catch { }
    return $false
}

function Repair-WslSessionForDistro {
    param(
        [Parameter(Mandatory = $true)][string]$Distro,
        [int]$Attempts = 2
    )

    if (Test-DistroRunnable $Distro) { return $true }
    for ($attempt = 1; $attempt -le [Math]::Max(1, $Attempts); $attempt++) {
        try { & wsl.exe --terminate $Distro *> $null } catch { }
        try { & wsl.exe --shutdown *> $null } catch { }
        if ($attempt -ge 2) { [void](Restart-WslHostServiceIfElevated) }
        try { & wsl.exe --status *> $null } catch { }
        Start-Sleep -Milliseconds (1200 + (650 * $attempt))
        if (Test-DistroRunnable $Distro) { return $true }
    }
    return $false
}

function Get-DistroKernelRelease {
    param([string]$Distro)
    if ([string]::IsNullOrWhiteSpace($Distro)) { return "" }
    try {
        $output = & wsl.exe -d $Distro -u root -- /bin/uname -r 2>$null
        if ($LASTEXITCODE -eq 0) {
            return ((Get-CleanWslOutput $output) -join " ").Trim()
        }
    }
    catch { }
    return ""
}

function Test-DistroIsWsl2 {
    param([string]$Distro)
    $kernel = Get-DistroKernelRelease $Distro
    return (-not [string]::IsNullOrWhiteSpace($kernel)) -and ($kernel -match '(?i)microsoft-standard.*wsl2|wsl2')
}

function Test-CompatibleDistro {
    param([string]$Distro)

    if (-not (Test-DistroRunnable $Distro)) {
        return $false
    }

    # Read os-release directly instead of evaluating shell syntax through
    # Windows PowerShell. The previous case-expression check could fail even
    # for a valid Ubuntu distribution because of native argument quoting.
    foreach ($releaseFile in @('/etc/os-release', '/usr/lib/os-release')) {
        try {
            $releaseOutput = & wsl.exe -d $Distro -u root -- /bin/cat $releaseFile 2>$null
            if ($LASTEXITCODE -eq 0) {
                foreach ($line in @(Get-CleanWslOutput $releaseOutput)) {
                    if ($line -match '^ID\s*=\s*(.+)$') {
                        $linuxId = $Matches[1].Trim().Trim('"').Trim("'").ToLowerInvariant()
                        if ($linuxId -in @('ubuntu', 'debian')) {
                            return $true
                        }
                    }
                }
            }
        }
        catch { }
    }

    # Fallback for a minimally initialized or imported Ubuntu/Debian rootfs.
    # OpDetect needs Bash and APT, so their presence is a practical and robust
    # compatibility test even when os-release cannot be parsed yet.
    try {
        & wsl.exe -d $Distro -u root -- /usr/bin/apt-get --version *> $null
        $hasApt = $LASTEXITCODE -eq 0

        & wsl.exe -d $Distro -u root -- /bin/bash --version *> $null
        $hasBash = $LASTEXITCODE -eq 0

        return ($hasApt -and $hasBash)
    }
    catch {
        return $false
    }
}

function Resolve-OpDetectDistro {
    # Directly probe the dedicated distribution first. This is deliberately
    # independent of registry parsing and UTF-16 output decoding.
    if (Test-CompatibleDistro 'OpDetect-Ubuntu') {
        return 'OpDetect-Ubuntu'
    }

    if (Test-Path -LiteralPath $DistroPreferenceFile) {
        $savedDirect = (Get-Content -LiteralPath $DistroPreferenceFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($savedDirect -and (Test-CompatibleDistro $savedDirect)) {
            return $savedDirect
        }
    }

    $records = @(Get-WslDistroRecords)
    if ($records.Count -eq 0) { return $null }

    $candidates = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $DistroPreferenceFile) {
        $saved = (Get-Content -LiteralPath $DistroPreferenceFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($saved) { [void]$candidates.Add($saved) }
    }
    foreach ($name in @('OpDetect-Ubuntu', 'Ubuntu-24.04', 'Ubuntu', 'Ubuntu-22.04', 'Debian')) {
        [void]$candidates.Add($name)
    }
    foreach ($record in $records) {
        if ($record.Name -match '(?i)ubuntu|debian') { [void]$candidates.Add($record.Name) }
    }
    foreach ($record in $records) { [void]$candidates.Add($record.Name) }

    $seen = @{}
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $key = $candidate.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $record = $records | Where-Object { $_.Name -ieq $candidate } | Select-Object -First 1
        if ($null -eq $record) { continue }

        # Never try to reinstall a distribution that is already registered.
        # Prefer an installed Ubuntu/Debian by name, even before it is started.
        if ($record.Name -match '(?i)ubuntu|debian') {
            return $record.Name
        }
        if (Test-CompatibleDistro $record.Name) {
            return $record.Name
        }
    }
    return $null
}

function Test-OpDetectRuntimeOnDistro {
    param([string]$Distro)

    if ([string]::IsNullOrWhiteSpace($Distro)) { return $false }
    try {
        # Prefer the distribution that actually owns the OpDetect environment.
        # The environment may live below either suite Miniforge installation or
        # at a custom Conda prefix recorded in `conda env list`.
        $probe = @'
for root in /root/.local/share/prok-rnaseq/miniforge3 /root/miniforge3 /opt/conda /opt/miniforge3; do
  if [ -x "$root/envs/opdetect-pipeline/bin/python" ]; then exit 0; fi
done
for conda_bin in /root/.local/share/prok-rnaseq/miniforge3/bin/conda /root/miniforge3/bin/conda /opt/conda/bin/conda /opt/miniforge3/bin/conda; do
  if [ -x "$conda_bin" ] && "$conda_bin" env list 2>/dev/null | awk 'NF && $1 !~ /^#/ {print $NF}' | grep -Eq '/opdetect-pipeline/?$'; then exit 0; fi
done
exit 1
'@
        & wsl.exe -d $Distro -u root -- /bin/bash -lc $probe *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Test-DistroRespondsFast {
    param([string]$Distro)

    if ([string]::IsNullOrWhiteSpace($Distro)) { return $false }
    try {
        & wsl.exe -d $Distro -u root -- /bin/true *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Refresh-ActiveDistro {
    $managedFallback = $null
    if (-not [string]::IsNullOrWhiteSpace($script:ManagedDistro) -and
        (Test-DistroRespondsFast $script:ManagedDistro) -and
        (Test-OpDetectRuntimeOnDistro $script:ManagedDistro)) {
        return $script:ManagedDistro
    }
    if (-not [string]::IsNullOrWhiteSpace($script:ManagedDistro) -and (Test-DistroRespondsFast $script:ManagedDistro)) {
        $managedFallback = $script:ManagedDistro
    }

    $script:ManagedDistro = $null

    # An OpDetect-specific saved choice takes precedence over suite-wide WSL
    # markers. A suite marker can point at a healthy RNA-seq environment that
    # does not contain the separate opdetect-pipeline environment.
    $savedFallback = $null
    if (Test-Path -LiteralPath $DistroPreferenceFile -PathType Leaf) {
        try {
            $saved = (Get-Content -LiteralPath $DistroPreferenceFile -Raw -ErrorAction Stop).Trim()
            if ($saved -and (Test-DistroRespondsFast $saved) -and (Test-OpDetectRuntimeOnDistro $saved)) {
                $script:ManagedDistro = $saved
                return $saved
            }
            if ($saved -and (Test-DistroRespondsFast $saved)) { $savedFallback = $saved }
        }
        catch { }
    }

    $dedicatedFallback = $null
    if ((Test-DistroRespondsFast 'OpDetect-Ubuntu') -and (Test-OpDetectRuntimeOnDistro 'OpDetect-Ubuntu')) {
        $script:ManagedDistro = 'OpDetect-Ubuntu'
        return $script:ManagedDistro
    }
    if (Test-DistroRespondsFast 'OpDetect-Ubuntu') { $dedicatedFallback = 'OpDetect-Ubuntu' }

    # If a preference marker was lost or became stale, locate the registered
    # distribution that contains the installed OpDetect environment.
    $records = @(Get-WslDistroRecords)
    foreach ($record in $records) {
        if (Test-OpDetectRuntimeOnDistro ([string]$record.Name)) {
            $script:ManagedDistro = [string]$record.Name
            return $script:ManagedDistro
        }
    }

    foreach ($fallback in @($savedFallback,$dedicatedFallback,$managedFallback)) {
        if ($fallback) { $script:ManagedDistro = $fallback; return $script:ManagedDistro }
    }

    # First-time installation may intentionally reuse the suite's working WSL
    # distribution, so retain these markers as installation fallbacks.
    foreach ($markerPath in @($SharedDistroPreferenceFile,$CoreDistroPreferenceFile)) {
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            try {
                $shared=(Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop).Trim()
                if($shared -and (Test-DistroRespondsFast $shared)){ $script:ManagedDistro=$shared; return $shared }
            } catch { }
        }
    }

    foreach ($preferred in @('OpDetect-Ubuntu', 'Ubuntu-24.04', 'Ubuntu', 'Ubuntu-22.04', 'Debian')) {
        $match = $records | Where-Object { $_.Name -ieq $preferred } | Select-Object -First 1
        if ($null -ne $match -and (Test-DistroRespondsFast ([string]$match.Name))) {
            $script:ManagedDistro = [string]$match.Name
            return $script:ManagedDistro
        }
    }
    return $null
}

$ManagedDistro = $null

function Test-PipelineReady {
    $distro = Refresh-ActiveDistro
    if ([string]::IsNullOrWhiteSpace($distro)) {
        return $false
    }

    # Custom/imported WSL distributions do not always expose a reliable
    # Version value in the registry. Verify WSL2 from the running kernel
    # instead of relying on Get-DistroVersion.
    if (-not (Test-DistroIsWsl2 $distro)) {
        return $false
    }

    try {
        & wsl.exe -d $distro -u root -- /usr/bin/test -x "$PipelineRoot/run_opdetect_pipeline.sh" *> $null
        if ($LASTEXITCODE -ne 0) { return $false }

        & wsl.exe -d $distro -u root -- /bin/bash "$PipelineRoot/environment_ready.sh" *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Convert-WindowsPathToWsl {
    param([string]$WindowsPath)

    if ([string]::IsNullOrWhiteSpace($WindowsPath)) {
        throw "An input path is empty."
    }

    $fullPath = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -match '^([A-Za-z]):[\\/](.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $tail = $Matches[2] -replace '\\', '/'
        return "/mnt/$drive/$tail"
    }

    throw "Could not convert this path for WSL: $fullPath`n`nUse a file on a local Windows drive such as C:, D:, or E:."
}

function Convert-ToBashSingleQuoted {
    param([string]$Value)
    $replacement = "'" + [char]34 + "'" + [char]34 + "'"
    return "'" + $Value.Replace("'", $replacement) + "'"
}

function Format-DecimalInvariant {
    param([decimal]$Value)
    return $Value.ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture)
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
    catch {
        # [Environment]::ProcessorCount remains a safe fallback.
    }
    if ($logical -lt 1) { $logical = 1 }
    $recommended = [Math]::Max(1, [int][Math]::Floor($logical * 0.75))
    return [pscustomobject]@{
        Logical = $logical
        Physical = $physical
        Recommended = $recommended
    }
}

function Get-SafeProjectName {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'opdetect_project'
    }
    $name = [regex]::Replace($Value.Trim(), '[^A-Za-z0-9._-]+', '_')
    $name = $name.Trim([char[]]'_.-')
    if ([string]::IsNullOrWhiteSpace($name)) {
        return 'opdetect_project'
    }
    return $name
}

function Get-DisplayFileStem {
    param(
        [string]$Value,
        [string]$Fallback = 'OpDetect project'
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Fallback }
    $name = [regex]::Replace($Value.Trim(), '[._-]+', ' ')
    $name = [regex]::Replace($name, '[<>:"/\\|?*]+', ' ')
    $name = [regex]::Replace($name, '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return $Fallback }
    return $name
}

function Get-FastqStem {
    param([string]$Path)
    $name = [System.IO.Path]::GetFileName($Path)
    $name = [regex]::Replace($name, '(?i)\.gz$', '')
    $name = [regex]::Replace($name, '(?i)\.(fastq|fq)$', '')
    return $name
}

function Get-SampleNameFromReadFile {
    param([string]$Path)
    $stem = Get-FastqStem $Path

    # Prefer explicit read tokens such as R1/R2. This prevents a biological or
    # replicate number earlier in the name (for example JL2_1_R2) from being
    # mistaken for the read direction.
    $clean = [regex]::Replace(
        $stem,
        '(?i)([._-](?:R[12]|read[12]|forward|reverse))(?:[._-].*)?$',
        ''
    )

    # Support simple legacy names such as sample_1.fastq / sample_2.fastq only
    # when no explicit read token was found.
    if ($clean -eq $stem) {
        $clean = [regex]::Replace(
            $stem,
            '(?i)([._-][12])(?:[._-]\d+)?$',
            ''
        )
    }

    if ([string]::IsNullOrWhiteSpace($clean)) {
        $clean = $stem
    }
    $clean = [regex]::Replace($clean, '[^A-Za-z0-9._-]+', '_')
    $clean = $clean.Trim([char[]]'_.-')
    if ([string]::IsNullOrWhiteSpace($clean)) {
        $clean = "sample"
    }
    return $clean
}

function Get-SafeProjectId {
    param([string]$ReferencePath)
    if ([string]::IsNullOrWhiteSpace($ReferencePath)) {
        return "opdetect_project"
    }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ReferencePath)
    if ($name.EndsWith('.fasta', [System.StringComparison]::OrdinalIgnoreCase) -or
        $name.EndsWith('.fna', [System.StringComparison]::OrdinalIgnoreCase)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($name)
    }
    $name = [regex]::Replace($name, '[^A-Za-z0-9._-]+', '_')
    $name = $name.Trim([char[]]'_.-')
    if ([string]::IsNullOrWhiteSpace($name)) {
        return "opdetect_project"
    }
    return $name
}

function Get-UniqueSampleName {
    param(
        [System.Data.DataTable]$Table,
        [string]$RequestedName
    )

    $candidate = $RequestedName
    $suffix = 2
    while (@($Table.Select("Sample = '" + $candidate.Replace("'", "''") + "'")).Count -gt 0) {
        $candidate = "${RequestedName}_$suffix"
        $suffix++
    }
    return $candidate
}

function Add-SampleRow {
    param(
        [System.Data.DataTable]$Table,
        [string]$Sample,
        [string]$R1,
        [string]$R2
    )

    if ($Table.Rows.Count -ge 6) {
        Show-ErrorMessage "OpDetect accepts a maximum of six biological replicates in one analysis. Remove a replicate before adding another one."
        return $false
    }

    $unique = Get-UniqueSampleName -Table $Table -RequestedName $Sample
    [void]$Table.Rows.Add($unique, $R1, $R2)
    return $true
}

function Get-PairDescriptor {
    param([System.IO.FileInfo]$File)

    $stem = Get-FastqStem $File.FullName
    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

    # First look only for explicit read-direction tokens. The prefix is greedy
    # so the right-most R1/R2 token is used. For example, JL2_1_R2 is correctly
    # identified as Read 2 rather than matching the earlier replicate token _1.
    $match = [regex]::Match(
        $stem,
        '^(?<prefix>.*)(?<sep>[._-])(?<read>R[12]|read[12]|forward|reverse)(?<suffix>(?:[._-].*)?)$',
        $options
    )

    # Then support simple legacy mate names such as sample_1 / sample_2. Bare
    # numbers are considered read directions only at the end of the stem, with
    # an optional numeric chunk suffix such as _001.
    if (-not $match.Success) {
        $match = [regex]::Match(
            $stem,
            '^(?<prefix>.+)(?<sep>[._-])(?<read>[12])(?<suffix>(?:[._-]\d+)?)$',
            $options
        )
    }

    if (-not $match.Success) {
        return [pscustomobject]@{
            IsRead = $false
            Read = 0
            Key = $stem.ToLowerInvariant()
            Sample = Get-SampleNameFromReadFile $File.FullName
            Path = $File.FullName
        }
    }

    $readToken = $match.Groups['read'].Value.ToLowerInvariant()
    $readNumber = if ($readToken -in @('r1', '1', 'read1', 'forward')) { 1 } else { 2 }
    $key = ($match.Groups['prefix'].Value + $match.Groups['suffix'].Value).ToLowerInvariant()

    return [pscustomobject]@{
        IsRead = $true
        Read = $readNumber
        Key = $key
        Sample = Get-SampleNameFromReadFile $File.FullName
        Path = $File.FullName
    }
}


function Get-ReadDescriptorFromPath {
    param([string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        return Get-PairDescriptor $item
    }
    catch {
        return [pscustomobject]@{
            IsRead = $false
            Read = 0
            Key = ''
            Sample = Get-SampleNameFromReadFile $Path
            Path = $Path
        }
    }
}

function Assert-ValidPairedSelection {
    param(
        [ref]$R1,
        [ref]$R2
    )

    $firstPath = [string]$R1.Value
    $secondPath = [string]$R2.Value
    if ([string]::IsNullOrWhiteSpace($firstPath) -or [string]::IsNullOrWhiteSpace($secondPath)) {
        throw "Select both paired-end FASTQ files."
    }
    if ([string]::Equals($firstPath, $secondPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Mate 1 and mate 2 must be two different FASTQ files."
    }

    # Explicit selection defines the pair. Do not reject, reorder, or compare
    # files based on R1/R2, _1/_2, forward/reverse, or sample-name tokens.
}


function Get-WindowsMachineReport {
    param([string]$DistroName)

    $lines = @()
    $lines += 'Windows machine information'
    $lines += ('Generated: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'))
    $lines += ('Computer name: ' + $env:COMPUTERNAME)
    $lines += ('PowerShell version: ' + $PSVersionTable.PSVersion.ToString())
    $lines += ('WSL distribution: ' + $DistroName)

    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($computer.Manufacturer) { $lines += ('Manufacturer: ' + [string]$computer.Manufacturer) }
        if ($computer.Model) { $lines += ('Model: ' + [string]$computer.Model) }
        if ($computer.SystemType) { $lines += ('System type: ' + [string]$computer.SystemType) }
        if ($computer.TotalPhysicalMemory) {
            $memoryGiB = [Math]::Round(([double]$computer.TotalPhysicalMemory / 1GB), 2)
            $lines += ('Installed memory: ' + $memoryGiB + ' GiB')
        }
    }
    catch { $lines += ('Computer-system details: unavailable (' + $_.Exception.Message + ')') }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $lines += ('Windows edition: ' + [string]$os.Caption)
        $lines += ('Windows version: ' + [string]$os.Version)
        $lines += ('Windows build: ' + [string]$os.BuildNumber)
        $lines += ('Windows architecture: ' + [string]$os.OSArchitecture)
    }
    catch { $lines += ('Windows OS details: unavailable (' + $_.Exception.Message + ')') }

    try {
        $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        if ($processors.Count -gt 0) {
            $cpuNames = @($processors | ForEach-Object { ([string]$_.Name).Trim() } | Select-Object -Unique)
            $physicalCores = ($processors | Measure-Object -Property NumberOfCores -Sum).Sum
            $logicalProcessors = ($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
            $lines += ('CPU: ' + ($cpuNames -join '; '))
            $lines += ('Physical CPU cores: ' + [string]$physicalCores)
            $lines += ('Logical processors: ' + [string]$logicalProcessors)
        }
    }
    catch { $lines += ('CPU details: unavailable (' + $_.Exception.Message + ')') }

    try {
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | ForEach-Object { ([string]$_.Name).Trim() } | Where-Object { $_ } | Select-Object -Unique)
        if ($gpus.Count -gt 0) { $lines += ('Graphics adapter(s): ' + ($gpus -join '; ')) }
    }
    catch { $lines += ('Graphics details: unavailable (' + $_.Exception.Message + ')') }

    try {
        $versionFile = Join-Path $PSScriptRoot 'VERSION.txt'
        if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
            $packageVersion = ([System.IO.File]::ReadAllText($versionFile)).Trim()
            if ($packageVersion) { $lines += ('OpDetect Windows package version: ' + $packageVersion) }
        }
    }
    catch { }

    return (($lines -join "`r`n") + "`r`n")
}

function Test-PathLooksLikeExplicitR2 {
    param([string]$Path)

    # Use explicit R2/read2/reverse tokens for the single-end safety guard.
    # A bare trailing "_2" may simply be a biological replicate name, so it is
    # intentionally not rejected here.
    $stem = Get-FastqStem $Path
    return [regex]::IsMatch(
        $stem,
        '(?i)(?:^|[._-])(?:R2|read2|reverse)(?=$|[._-])'
    )
}

function Get-R2LikeFiles {
    param([object[]]$Paths)

    $result = @()
    foreach ($path in @($Paths)) {
        if (Test-PathLooksLikeExplicitR2 ([string]$path)) {
            $result += ([string]$path)
        }
    }
    return $result
}

function Select-OneFile {
    param(
        [string]$Title,
        [string]$Filter
    )

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    $dialog.Multiselect = $false
    $dialog.CheckFileExists = $true
    if (Test-Path $script:LastBrowseFolder) {
        $dialog.InitialDirectory = $script:LastBrowseFolder
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:LastBrowseFolder = [System.IO.Path]::GetDirectoryName($dialog.FileName)
        return $dialog.FileName
    }
    return $null
}

function Select-MultipleFiles {
    param(
        [string]$Title,
        [string]$Filter
    )

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    $dialog.Multiselect = $true
    $dialog.CheckFileExists = $true
    if (Test-Path $script:LastBrowseFolder) {
        $dialog.InitialDirectory = $script:LastBrowseFolder
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        if ($dialog.FileNames.Count -gt 0) {
            $script:LastBrowseFolder = [System.IO.Path]::GetDirectoryName($dialog.FileNames[0])
        }
        return @($dialog.FileNames)
    }
    return @()
}

function Select-OneFolder {
    param([string]$Description)

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true
    if (Test-Path $script:LastBrowseFolder) {
        $dialog.SelectedPath = $script:LastBrowseFolder
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:LastBrowseFolder = $dialog.SelectedPath
        return $dialog.SelectedPath
    }
    return $null
}


function New-EnvironmentStatusRecord {
    param(
        [bool]$Ready = $false,
        [string]$Detail = "Not checked"
    )
    return [pscustomobject]@{
        Ready = $Ready
        Detail = $Detail
    }
}

function Get-PreferredDistroNameFast {
    # The OpDetect preference is authoritative for readiness checks. General
    # suite markers can legitimately refer to a different WSL distribution.
    $savedFallback = $null
    if (Test-Path -LiteralPath $DistroPreferenceFile) {
        try {
            $saved = (Get-Content -LiteralPath $DistroPreferenceFile -Raw -ErrorAction Stop).Trim()
            if ($saved -and (Test-DistroRespondsFast $saved) -and (Test-OpDetectRuntimeOnDistro $saved)) { return $saved }
            if ($saved -and (Test-DistroRespondsFast $saved)) { $savedFallback = $saved }
        }
        catch { }
    }

    $dedicatedFallback = $null
    if ((Test-DistroRespondsFast 'OpDetect-Ubuntu') -and (Test-OpDetectRuntimeOnDistro 'OpDetect-Ubuntu')) { return 'OpDetect-Ubuntu' }
    if (Test-DistroRespondsFast 'OpDetect-Ubuntu') { $dedicatedFallback = 'OpDetect-Ubuntu' }

    $records = @(Get-WslDistroRecords)
    foreach ($record in $records) {
        if (Test-OpDetectRuntimeOnDistro ([string]$record.Name)) {
            return [string]$record.Name
        }
    }

    foreach ($fallback in @($savedFallback,$dedicatedFallback)) {
        if ($fallback) { return $fallback }
    }

    # Retain the suite-wide distro as a first-install fallback only after no
    # existing OpDetect environment was found.
    foreach ($markerPath in @($SharedDistroPreferenceFile,$CoreDistroPreferenceFile)) {
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            try {
                $shared=(Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop).Trim()
                if($shared -and (Test-DistroRespondsFast $shared)){ return $shared }
            }
            catch { }
        }
    }

    foreach ($preferred in @('OpDetect-Ubuntu', 'Ubuntu-24.04', 'Ubuntu', 'Ubuntu-22.04', 'Debian')) {
        $match = $records | Where-Object { $_.Name -ieq $preferred } | Select-Object -First 1
        if ($null -ne $match -and (Test-DistroRespondsFast ([string]$match.Name))) {
            return [string]$match.Name
        }
    }

    $fallback = $records | Where-Object { $_.Name -match '(?i)ubuntu|debian' } | Select-Object -First 1
    if ($null -ne $fallback) {
        return [string]$fallback.Name
    }
    return $null
}

function Convert-LocalPackagePathToWslFast {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)

    $fullPath = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -match '^([A-Za-z]):[\\/](.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $tail = $Matches[2] -replace '\\', '/'
        return "/mnt/$drive/$tail"
    }
    throw "The extracted OpDetect package must be stored on a local Windows drive such as C:, D:, or E:."
}

function Invoke-WslStatusCheckWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$Distro,
        [Parameter(Mandatory = $true)][string]$LinuxScriptPath,
        [int]$TimeoutMilliseconds = 60000
    )

    # All managed Linux helper paths are fixed paths without spaces. Keeping
    # the native argument string simple avoids the Windows PowerShell 5.1
    # quoting problems that affected earlier status checks.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "wsl.exe"
    $startInfo.Arguments = "-d $Distro -u root -- /bin/bash $LinuxScriptPath"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        if (-not $process.Start()) {
            throw "wsl.exe could not be started."
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $watch = [System.Diagnostics.Stopwatch]::StartNew()

        while (-not $process.HasExited -and $watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }

        if (-not $process.HasExited) {
            try { $process.Kill() } catch { }
            try { $process.WaitForExit(2000) | Out-Null } catch { }
            return [pscustomobject]@{
                TimedOut = $true
                ExitCode = -1
                StandardOutput = ""
                StandardError = "The WSL environment check exceeded $([Math]::Round($TimeoutMilliseconds / 1000)) seconds."
            }
        }

        $process.WaitForExit()
        return [pscustomobject]@{
            TimedOut = $false
            ExitCode = $process.ExitCode
            StandardOutput = $stdoutTask.Result
            StandardError = $stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-EnvironmentStatus {
    $result = [ordered]@{
        Linux = (New-EnvironmentStatusRecord -Detail "WSL2 Linux is not available")
        Conda = (New-EnvironmentStatusRecord -Detail "The opdetect-pipeline environment is missing")
        Git = (New-EnvironmentStatusRecord -Detail "git is missing")
        Fastp = (New-EnvironmentStatusRecord -Detail "fastp is missing")
        Hisat2 = (New-EnvironmentStatusRecord -Detail "HISAT2 is missing")
        Samtools = (New-EnvironmentStatusRecord -Detail "SAMtools is missing")
        Bedtools = (New-EnvironmentStatusRecord -Detail "BEDtools is missing")
        Python = (New-EnvironmentStatusRecord -Detail "Required Python libraries are missing")
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $result
    }

    $distro = Get-PreferredDistroNameFast
    if ([string]::IsNullOrWhiteSpace($distro)) {
        $result.Linux.Detail = "No registered Ubuntu or Debian WSL distribution was found"
        return $result
    }
    $script:ManagedDistro = $distro

    try {
        if (-not (Repair-WslSessionForDistro -Distro $distro -Attempts 2)) {
            throw "The registered distribution '$distro' could not start after automatic WSL session recovery. Click Install or repair to run elevated host-service recovery. If Windows still owns a stuck WSL host, the repair window will offer a Windows restart. Do not reinstall or unregister Ubuntu."
        }
        # Always synchronize the status scripts from the currently opened
        # Windows package before checking versions. Earlier builds checked an
        # older copy under /root/opdetect_pipeline and could therefore report
        # TensorFlow/Keras 2.14 as Ready after the GUI requirements changed.
        $packageRootWsl = Convert-WindowsPathToWsl $PSScriptRoot
        $syncScriptWsl = ($packageRootWsl.TrimEnd('/')) + "/sync_runtime.sh"
        $syncCommand = "bash $(Convert-ToBashSingleQuoted $syncScriptWsl) $(Convert-ToBashSingleQuoted $packageRootWsl) '/root/opdetect_pipeline'"
        & wsl.exe -d $distro -u root -- bash -lc $syncCommand *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not synchronize the current readiness scripts into Linux."
        }

        # First use the exact Linux-side readiness script that the installer
        # uses. If it succeeds, the environment is ready and no multi-line
        # status parsing is needed.
        $readyCheck = Invoke-WslStatusCheckWithTimeout `
            -Distro $distro `
            -LinuxScriptPath "/root/opdetect_pipeline/environment_ready.sh" `
            -TimeoutMilliseconds 60000

        $logText = "Distro: $distro`r`nReady exit code: $($readyCheck.ExitCode)`r`nTimed out: $($readyCheck.TimedOut)`r`nSTDOUT:`r`n$($readyCheck.StandardOutput)`r`nSTDERR:`r`n$($readyCheck.StandardError)`r`n"
        try { Set-Content -LiteralPath $EnvironmentStatusLogPath -Value $logText -Encoding UTF8 } catch { }

        if (-not $readyCheck.TimedOut -and $readyCheck.ExitCode -eq 0) {
            $result.Linux = (New-EnvironmentStatusRecord -Ready $true -Detail "$distro is running and the Linux environment was verified")
            $result.Conda = (New-EnvironmentStatusRecord -Ready $true -Detail "shared Miniforge / opdetect-pipeline")
            $result.Git = (New-EnvironmentStatusRecord -Ready $true -Detail "git is available")
            $result.Fastp = (New-EnvironmentStatusRecord -Ready $true -Detail "shared Miniforge / opdetect-pipeline/bin/fastp")
            $result.Hisat2 = (New-EnvironmentStatusRecord -Ready $true -Detail "shared Miniforge / opdetect-pipeline/bin/hisat2")
            $result.Samtools = (New-EnvironmentStatusRecord -Ready $true -Detail "shared Miniforge / opdetect-pipeline/bin/samtools")
            $result.Bedtools = (New-EnvironmentStatusRecord -Ready $true -Detail "shared Miniforge / opdetect-pipeline/bin/bedtools")
            $result.Python = (New-EnvironmentStatusRecord -Ready $true -Detail "Python and all required libraries are available")
            return $result
        }

        # If the overall check fails, ask the Linux-side detail script for
        # per-component information. It is invoked from /root, not from the
        # Windows-mounted package folder.
        $detailCheck = Invoke-WslStatusCheckWithTimeout `
            -Distro $distro `
            -LinuxScriptPath "/root/opdetect_pipeline/quick_environment_status.sh" `
            -TimeoutMilliseconds 30000

        try {
            Add-Content -LiteralPath $EnvironmentStatusLogPath -Value ("`r`nDetailed exit code: $($detailCheck.ExitCode)`r`nSTDOUT:`r`n$($detailCheck.StandardOutput)`r`nSTDERR:`r`n$($detailCheck.StandardError)") -Encoding UTF8
        }
        catch { }

        if ($detailCheck.TimedOut) {
            $result.Linux.Detail = "Environment check timed out. Details were saved to $EnvironmentStatusLogPath"
            return $result
        }
        if ($detailCheck.ExitCode -ne 0) {
            $detail = ([string]$detailCheck.StandardError).Trim()
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = "The WSL environment check returned exit code $($detailCheck.ExitCode)."
            }
            $result.Linux.Detail = "$detail Details: $EnvironmentStatusLogPath"
            return $result
        }

        foreach ($line in @(Get-CleanWslOutput (($detailCheck.StandardOutput -split '\r?\n')))) {
            $parts = $line -split "`t", 3
            if ($parts.Count -lt 3) { continue }
            $key = $parts[0]
            if (-not $result.Contains($key)) { continue }
            $result[$key] = (New-EnvironmentStatusRecord -Ready ($parts[1] -eq '1') -Detail $parts[2])
        }
    }
    catch {
        $failure = "Linux status check failed: $($_.Exception.Message). Details: $EnvironmentStatusLogPath"
        $result.Linux = (New-EnvironmentStatusRecord -Detail $failure)
        foreach ($key in @('Conda','Git','Fastp','Hisat2','Samtools','Bedtools','Python')) {
            $result[$key] = (New-EnvironmentStatusRecord -Detail "Not evaluated because the registered WSL distribution could not be started.")
        }
    }

    return $result
}

function New-StatusBadge {
    param(
        [string]$Name,
        [int]$X,
        [int]$Y,
        [int]$Width = 116
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Name = "${Name}StatusBadge"
    $label.Text = "${Name}: Not checked"
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, 25)
    $label.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $label.BackColor = [System.Drawing.Color]::FromArgb(235, 235, 235)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
    return $label
}

function Set-StatusBadge {
    param(
        [System.Windows.Forms.Label]$Badge,
        [string]$Name,
        [object]$Record,
        [System.Windows.Forms.ToolTip]$ToolTip
    )

    if ($Record.Ready) {
        $Badge.Text = "${Name}: Ready"
        $Badge.BackColor = [System.Drawing.Color]::FromArgb(219, 242, 224)
        $Badge.ForeColor = [System.Drawing.Color]::FromArgb(25, 102, 48)
    }
    else {
        $detailText = [string]$Record.Detail
        if ($Name -eq 'Linux' -and $detailText -match '(?i)could not start|restart Windows|automatic WSL.*recovery|host-service recovery') {
            $Badge.Text = "${Name}: Recovery needed"
            $Badge.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 204)
            $Badge.ForeColor = [System.Drawing.Color]::FromArgb(135, 90, 0)
        }
        elseif ($detailText -match '(?i)^Not evaluated') {
            $Badge.Text = "${Name}: Not checked"
            $Badge.BackColor = [System.Drawing.Color]::FromArgb(235, 235, 235)
            $Badge.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
        }
        elseif ($Name -eq "Python" -and $detailText -match '(?i)outdated|update required|TensorFlow 2\.19|Keras 3\.9') {
            $Badge.Text = "${Name}: Update required"
            $Badge.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 204)
            $Badge.ForeColor = [System.Drawing.Color]::FromArgb(135, 90, 0)
        }
        else {
            $Badge.Text = "${Name}: Missing"
            $Badge.BackColor = [System.Drawing.Color]::FromArgb(252, 226, 226)
            $Badge.ForeColor = [System.Drawing.Color]::FromArgb(150, 35, 35)
        }
    }
    $ToolTip.SetToolTip($Badge, [string]$Record.Detail)
}

function Set-CachedEnvironmentReady {
    param([string]$Detail = "Verified by the OpDetect installer")

    $record = New-EnvironmentStatusRecord -Ready $true -Detail $Detail
    Set-StatusBadge -Badge $linuxBadge -Name "Linux" -Record $record -ToolTip $environmentToolTip
    Set-StatusBadge -Badge $condaBadge -Name "Conda" -Record $record -ToolTip $environmentToolTip
    Set-StatusBadge -Badge $gitBadge -Name "Git" -Record $record -ToolTip $environmentToolTip
    Set-StatusBadge -Badge $fastpBadge -Name "fastp" -Record $record -ToolTip $environmentToolTip
    Set-StatusBadge -Badge $hisat2Badge -Name "HISAT2" -Record $record -ToolTip $environmentToolTip
    Set-StatusBadge -Badge $samtoolsBadge -Name "SAMtools" -Record $record -ToolTip $environmentToolTip
    Set-StatusBadge -Badge $bedtoolsBadge -Name "BEDtools" -Record $record -ToolTip $environmentToolTip
    Set-StatusBadge -Badge $pythonBadge -Name "Python" -Record $record -ToolTip $environmentToolTip
    $script:EnvironmentReady = $true
    $runButton.Enabled = $true
    $environmentSummaryLabel.Text = "Linux and all required packages are ready."
    $environmentSummaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(25, 102, 48)
}

function Update-EnvironmentStatus {
    $script:EnvironmentReady = $false
    $environmentSummaryLabel.Text = "Checking Linux and required packages..."
    $environmentSummaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
    $refreshEnvironmentButton.Enabled = $false
    $form.UseWaitCursor = $true
    $form.Refresh()

    try {
        $environment = Get-EnvironmentStatus
        Set-StatusBadge -Badge $linuxBadge -Name "Linux" -Record $environment.Linux -ToolTip $environmentToolTip
        Set-StatusBadge -Badge $condaBadge -Name "Conda" -Record $environment.Conda -ToolTip $environmentToolTip
        Set-StatusBadge -Badge $gitBadge -Name "Git" -Record $environment.Git -ToolTip $environmentToolTip
        Set-StatusBadge -Badge $fastpBadge -Name "fastp" -Record $environment.Fastp -ToolTip $environmentToolTip
        Set-StatusBadge -Badge $hisat2Badge -Name "HISAT2" -Record $environment.Hisat2 -ToolTip $environmentToolTip
        Set-StatusBadge -Badge $samtoolsBadge -Name "SAMtools" -Record $environment.Samtools -ToolTip $environmentToolTip
        Set-StatusBadge -Badge $bedtoolsBadge -Name "BEDtools" -Record $environment.Bedtools -ToolTip $environmentToolTip
        Set-StatusBadge -Badge $pythonBadge -Name "Python" -Record $environment.Python -ToolTip $environmentToolTip

        $script:EnvironmentReady = @(
            $environment.Linux.Ready,
            $environment.Conda.Ready,
            $environment.Git.Ready,
            $environment.Fastp.Ready,
            $environment.Hisat2.Ready,
            $environment.Samtools.Ready,
            $environment.Bedtools.Ready,
            $environment.Python.Ready
        ) -notcontains $false

        if ($script:EnvironmentReady) {
            $environmentSummaryLabel.Text = "Linux and all required packages are ready."
            $environmentSummaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(25, 102, 48)
            $runButton.Enabled = $true
        }
        else {
            if (([string]$environment.Linux.Detail) -match '(?i)could not start|restart Windows|automatic WSL.*recovery|host-service recovery') {
                $environmentSummaryLabel.Text = "The existing WSL environment is registered but is not responding. Click Install or repair to reset the WSL host service without reinstalling Ubuntu."
                $environmentSummaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(135, 90, 0)
            }
            else {
                $environmentSummaryLabel.Text = "Setup is incomplete. Click Install or repair to prepare Linux and missing packages."
                $environmentSummaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(150, 35, 35)
            }
            $runButton.Enabled = $false
        }
    }
    catch {
        $checkError = $_.Exception.Message
        Write-StartupLog ("ENVIRONMENT CHECK ERROR: " + $checkError)
        try { Set-Content -LiteralPath $EnvironmentStatusLogPath -Value ("Environment check error: " + $checkError) -Encoding UTF8 } catch { }
        $failedLinux = New-EnvironmentStatusRecord -Ready $false -Detail ("Environment check error: " + $checkError)
        $skipped = New-EnvironmentStatusRecord -Ready $false -Detail "Not evaluated because the readiness routine encountered an unexpected Windows-side error. Hover Linux for the error detail."
        Set-StatusBadge -Badge $linuxBadge -Name "Linux" -Record $failedLinux -ToolTip $environmentToolTip
        Set-StatusBadge -Badge $condaBadge -Name "Conda" -Record $skipped -ToolTip $environmentToolTip
        Set-StatusBadge -Badge $gitBadge -Name "Git" -Record $skipped -ToolTip $environmentToolTip
        Set-StatusBadge -Badge $fastpBadge -Name "fastp" -Record $skipped -ToolTip $environmentToolTip
        Set-StatusBadge -Badge $hisat2Badge -Name "HISAT2" -Record $skipped -ToolTip $environmentToolTip
        Set-StatusBadge -Badge $samtoolsBadge -Name "SAMtools" -Record $skipped -ToolTip $environmentToolTip
        Set-StatusBadge -Badge $bedtoolsBadge -Name "BEDtools" -Record $skipped -ToolTip $environmentToolTip
        Set-StatusBadge -Badge $pythonBadge -Name "Python" -Record $skipped -ToolTip $environmentToolTip
        $environmentSummaryLabel.Text = "The environment check hit a Windows-side error. Hover Linux for details."
        $environmentSummaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(150, 35, 35)
        $runButton.Enabled = $false
    }
    finally {
        $form.UseWaitCursor = $false
        $refreshEnvironmentButton.Enabled = $true
    }
}

function New-ReadOnlyPathTextBox {
    param(
        [int]$X,
        [int]$Y,
        [int]$Width
    )
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point($X, $Y)
    $box.Size = New-Object System.Drawing.Size($Width, 25)
    $box.ReadOnly = $true
    $box.BackColor = [System.Drawing.SystemColors]::Window
    return $box
}


function Reset-RunProgressUI {
    $runProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $runProgressBar.Minimum = 0
    $runProgressBar.Maximum = 100
    $runProgressBar.Value = 0
    $runPercentLabel.Text = '0%'
    $currentStepLabel.Text = 'Ready to start. The workflow contains 10 steps.'
    $runLogBox.Clear()
    foreach ($row in $stepTable.Rows) {
        $row['Status'] = 'Pending'
    }
}

function Reset-ForNewRun {
    # Reset only the analysis workspace. Readiness badges, the detected WSL
    # distribution, and installed package status are deliberately preserved.
    if ($script:RunState -and -not $script:RunState.Finished) {
        Show-ErrorMessage 'An OpDetect analysis is still running. Stop it before resetting the window.'
        return
    }

    if ($script:RunTimer) {
        try { $script:RunTimer.Stop(); $script:RunTimer.Dispose() } catch { }
        $script:RunTimer = $null
    }
    $script:RunState = $null

    $referenceBox.Clear()
    $annotationBox.Clear()
    $projectBox.Text = 'opdetect_project'
    $sampleTable.Rows.Clear()
    $sampleGrid.ClearSelection()
    $outputBox.Text = $defaultOutput

    $threadsBox.Value = [decimal][Math]::Min([int]$threadsBox.Maximum, [int]$cpuTopology.Recommended)
    $thresholdBox.Value = [decimal]0.50
    $featureBox.SelectedIndex = 0
    $topologyBox.SelectedIndex = 0
    if ($copyBamBaiToIgvCheckBox) {
        $copyBamBaiToIgvCheckBox.Checked = $false
    }

    Reset-RunProgressUI
    $runProgressGroup.Text = 'Run progress - 10 steps'
    $statusLabel.Text = ''
    $statusLabel.ForeColor = [System.Drawing.SystemColors]::ControlText
    $stopRunButton.Enabled = $false
    $resetRunButton.Enabled = $true
    $runButton.Enabled = $script:EnvironmentReady
    $referenceButton.Focus()
}

function Add-SessionCompletedRun {
    param(
        [string]$ProjectId,
        [string[]]$SampleNames
    )

    # This history exists only in memory for the lifetime of the current GUI
    # process. RESET NEW RUN deliberately leaves it untouched; closing and
    # reopening OpDetect creates a fresh, empty session history.
    if ($null -eq $script:RunState) { return }
    if ($script:RunState.SessionHistoryAdded) { return }

    $projectDisplay = Get-DisplayFileStem -Value $ProjectId
    $cleanSamples = @($SampleNames | ForEach-Object {
        $name = Get-DisplayFileStem -Value ([string]$_)
        if (-not [string]::IsNullOrWhiteSpace($name)) { $name }
    })
    $sampleText = if ($cleanSamples.Count -gt 0) { $cleanSamples -join ', ' } else { 'sample names unavailable' }
    $entry = '{0:HH:mm} | {1}: {2}' -f (Get-Date), $projectDisplay, $sampleText

    if ($sessionRunList.Items.Count -eq 1 -and [string]$sessionRunList.Items[0] -eq 'No completed runs yet.') {
        $sessionRunList.Items.Clear()
    }
    [void]$sessionRunList.Items.Add($entry)
    $sessionRunList.TopIndex = [Math]::Max(0, $sessionRunList.Items.Count - 1)
    $script:RunState.SessionHistoryAdded = $true
}

function Set-RunStepStatus {
    param(
        [int]$Step,
        [string]$Status
    )
    if ($Step -ge 1 -and $Step -le $stepTable.Rows.Count) {
        $stepTable.Rows[$Step - 1]['Status'] = $Status
    }
}

function Restore-ResultsFromWsl {
    param(
        [string]$InternalOut,
        [string]$Destination,
        [string]$ProjectId,
        [bool]$CopyBamBaiToIgv = $false
    )

    try {
        if ([string]::IsNullOrWhiteSpace($InternalOut) -or [string]::IsNullOrWhiteSpace($Destination)) { return $false }
        [void](New-Item -ItemType Directory -Force -Path $Destination)
        $displayProject = Get-DisplayFileStem -Value $ProjectId
        $relative = $InternalOut.TrimStart('/') -replace '/', '\'
        $source = "\\wsl.localhost\$($script:ManagedDistro)\$relative\results"
        $predictionSource = Join-Path $source "$ProjectId.gene-pair-predictions.xlsx"
        $operonSource = Join-Path $source "$ProjectId.predicted-operons.xlsx"
        $bedGraphSource = Join-Path $source "$ProjectId.predicted-operons.bedgraph"
        $runLogSource = Join-Path $source 'OpDetect Run Report.docx'
        $correlationSource = Join-Path $source 'replicate-correlations.xlsx'
        if (-not (Test-Path -LiteralPath $predictionSource -PathType Leaf)) { return $false }
        if (-not (Test-Path -LiteralPath $operonSource -PathType Leaf)) { return $false }
        if (-not (Test-Path -LiteralPath $bedGraphSource -PathType Leaf)) { return $false }
        if (-not (Test-Path -LiteralPath $runLogSource -PathType Leaf)) { return $false }

        Copy-Item -LiteralPath $predictionSource -Destination (Join-Path $Destination "$displayProject gene pair predictions.xlsx") -Force
        Copy-Item -LiteralPath $operonSource -Destination (Join-Path $Destination "$displayProject predicted operons.xlsx") -Force
        Copy-Item -LiteralPath $runLogSource -Destination (Join-Path $Destination 'OpDetect Run Report.docx') -Force
        if (Test-Path -LiteralPath $correlationSource -PathType Leaf) {
            Copy-Item -LiteralPath $correlationSource -Destination (Join-Path $Destination 'Replicate correlations.xlsx') -Force
        }

        $igvDestination = Join-Path $Destination 'IGV'
        [void](New-Item -ItemType Directory -Force -Path $igvDestination)
        Copy-Item -LiteralPath $bedGraphSource -Destination (Join-Path $igvDestination "$displayProject predicted operons.bedgraph") -Force

        # Prefer the exact archived inputs created by current releases. Fall back
        # to the selections still visible in this GUI session for older runs.
        $inputSource = Join-Path $source 'igv-inputs'
        if (Test-Path -LiteralPath $inputSource -PathType Container) {
            Get-ChildItem -LiteralPath $inputSource -File -ErrorAction SilentlyContinue | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $igvDestination $_.Name) -Force
            }
        }
        else {
            foreach ($inputPath in @([string]$referenceBox.Text, [string]$annotationBox.Text)) {
                if (-not [string]::IsNullOrWhiteSpace($inputPath) -and (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
                    Copy-Item -LiteralPath $inputPath -Destination (Join-Path $igvDestination ([System.IO.Path]::GetFileName($inputPath))) -Force
                }
            }
        }

        if ($CopyBamBaiToIgv) {
            $bamSource = "\\wsl.localhost\$($script:ManagedDistro)\$relative\work\bam"
            if (Test-Path -LiteralPath $bamSource -PathType Container) {
                Get-ChildItem -LiteralPath $bamSource -Filter '*.sorted.bam' -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $sample = $_.Name -replace '(?i)\.sorted\.bam$', ''
                    $displaySample = Get-DisplayFileStem -Value $sample -Fallback 'sample'
                    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $igvDestination "$displaySample.bam") -Force
                    $indexSource = "$($_.FullName).bai"
                    if (Test-Path -LiteralPath $indexSource -PathType Leaf) {
                        Copy-Item -LiteralPath $indexSource -Destination (Join-Path $igvDestination "$displaySample.bam.bai") -Force
                    }
                }
            }
        }

        $logSource = "\\wsl.localhost\$($script:ManagedDistro)\$relative\logs"
        if (Test-Path -LiteralPath $logSource -PathType Container) {
            Get-ChildItem -LiteralPath $logSource -Filter '*.fastp.html' -File -ErrorAction SilentlyContinue | ForEach-Object {
                $sample = $_.Name -replace '(?i)\.fastp\.html$', ''
                $displaySample = Get-DisplayFileStem -Value $sample -Fallback 'sample'
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Destination "$displaySample fastp.html") -Force
            }
        }
        return $true
    }
    catch {
        Write-StartupLog "Windows-side result recovery failed: $($_.Exception.Message)"
        return $false
    }
}

function Read-RunFileChunk {
    param(
        [string]$Path,
        [string]$PositionKey
    )

    if ($null -eq $script:RunState) { return '' }
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }

    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            $position = 0L
            if ($script:RunState.ContainsKey($PositionKey)) {
                $position = [int64]$script:RunState[$PositionKey]
            }
            if ($position -gt $stream.Length) { $position = 0L }
            [void]$stream.Seek($position, [System.IO.SeekOrigin]::Begin)
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true, 4096, $true)
            try {
                $text = $reader.ReadToEnd()
                $script:RunState[$PositionKey] = $stream.Position
                return $text
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        Write-StartupLog "Could not read run file '$Path': $($_.Exception.Message)"
        return ''
    }
}

function Limit-RunLogDisplay {
    if ($null -eq $runLogBox -or $runLogBox.TextLength -le 1048576) { return }
    $keepFrom = [Math]::Max(0, ($runLogBox.TextLength - 786432))
    $tail = $runLogBox.Text.Substring($keepFrom)
    $firstNewline = $tail.IndexOf("`n")
    if ($firstNewline -ge 0 -and $firstNewline + 1 -lt $tail.Length) {
        $tail = $tail.Substring($firstNewline + 1)
    }
    $runLogBox.Text = "[Earlier live-console text was removed from this view. The persistent run log remains complete.]`r`n" + $tail
}

function Update-RunProgressDisplay {
    if ($null -eq $script:RunState) { return }

    try {
        $newText = Read-RunFileChunk -Path $script:RunState.ProgressFile -PositionKey 'ProgressPosition'
        if ([string]::IsNullOrEmpty($newText)) { return }

        foreach ($line in [regex]::Split($newText, "`r?`n")) {
            if ($line -match '^OPDETECT_PROGRESS\t(?<step>\d+)\t(?<percent>\d+)\t(?<state>[^\t]+)\t(?<message>.*)$') {
                $step = [int]$Matches['step']
                $percent = [Math]::Max(0, [Math]::Min(100, [int]$Matches['percent']))
                $markerState = $Matches['state'].ToLowerInvariant()
                $message = $Matches['message']

                $runProgressBar.Value = $percent
                $runPercentLabel.Text = "$percent%"
                $script:RunState.CurrentMessage = "Step $step of 10 - $message"
                $currentStepLabel.Text = $script:RunState.CurrentMessage

                if ($markerState -eq 'done' -or $markerState -eq 'finished') {
                    Set-RunStepStatus -Step $step -Status 'Finished'
                    if ($step -eq 10 -and $percent -eq 100) {
                        # The backend writes this marker only after the Windows export has
                        # completed and its required files have been verified. Disable Stop
                        # immediately so a completed run cannot be mistaken for an active one.
                        $script:RunState.CompletionMarkerSeen = $true
                        $stopRunButton.Enabled = $false
                    }
                }
                elseif ($markerState -eq 'failed') {
                    Set-RunStepStatus -Step $step -Status 'Failed'
                }
                else {
                    Set-RunStepStatus -Step $step -Status 'Running'
                }
            }
        }
    }
    catch {
        Write-StartupLog "Progress display update failed: $($_.Exception.Message)"
    }
}

function Update-RunLogDisplay {
    if ($null -eq $script:RunState) { return }

    try {
        $newText = Read-RunFileChunk -Path $script:RunState.LiveLogFile -PositionKey 'LiveLogPosition'
        if ([string]::IsNullOrEmpty($newText)) { return }

        $visibleText = [regex]::Replace($newText, '(?m)^OPDETECT_PROGRESS\t.*(?:\r?\n|$)', '')
        if (-not [string]::IsNullOrEmpty($visibleText)) {
            $runLogBox.AppendText(($visibleText -replace "`n", "`r`n"))
            Limit-RunLogDisplay
            $runLogBox.SelectionStart = $runLogBox.TextLength
            $runLogBox.ScrollToCaret()
        }
    }
    catch {
        Write-StartupLog "Run log display update failed: $($_.Exception.Message)"
    }
}

function Complete-RunAfterVerifiedExport {
    param([string]$ProjectId)

    if ($null -eq $script:RunState) { return $false }
    if ($script:RunState.Finished) { return $true }
    if (-not $script:RunState.CompletionMarkerSeen) { return $false }

    # OPDETECT_PROGRESS step 10 / 100 / done is emitted by the Linux backend only
    # after the simplified Windows package has been copied and verified. Treat that
    # marker as the authoritative completion event. Do not query or kill the hidden
    # wsl.exe launcher here: on some Windows builds its Process object becomes
    # temporarily unreadable after WSL exits, which previously caused endless monitor
    # errors and left the GUI looking as though it were still running.
    $script:RunState.Finished = $true
    $script:RunState.ExitCode = 0
    $script:RunState.StopRequested = $false
    try { $script:RunTimer.Stop() } catch { }

    $runButton.Enabled = $script:EnvironmentReady
    $stopRunButton.Enabled = $false
    $resetRunButton.Enabled = $true
    $copyBamBaiToIgvCheckBox.Enabled = $true
    $runProgressBar.Value = 100
    $runPercentLabel.Text = '100%'
    $currentStepLabel.Text = 'All 10 steps finished; the simplified result package was verified.'
    foreach ($row in $stepTable.Rows) { $row['Status'] = 'Finished' }
    $statusLabel.Text = "OpDetect completed successfully. Results: $($script:RunState.ResultPath)"
    $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
    Add-SessionCompletedRun -ProjectId $ProjectId -SampleNames @($script:RunState.SampleNames)

    # A final file-visibility check is informational only. The backend has already
    # verified the export before emitting the completion marker, and Windows may need
    # a moment to refresh a slow or external destination folder.
    try {
        $displayProject = Get-DisplayFileStem -Value $ProjectId
        $predictionPath = Join-Path $script:RunState.ResultPath "$displayProject gene pair predictions.xlsx"
        $operonPath = Join-Path $script:RunState.ResultPath "$displayProject predicted operons.xlsx"
        $reportPath = Join-Path $script:RunState.ResultPath 'OpDetect Run Report.docx'
        $bedGraphPath = Join-Path (Join-Path $script:RunState.ResultPath 'IGV') "$displayProject predicted operons.bedgraph"
        $visibleNow = (Test-Path -LiteralPath $predictionPath -PathType Leaf) -and
            (Test-Path -LiteralPath $operonPath -PathType Leaf) -and
            (Test-Path -LiteralPath $reportPath -PathType Leaf) -and
            (Test-Path -LiteralPath $bedGraphPath -PathType Leaf)
        if (-not $visibleNow -and -not $script:RunState.CompletionVisibilityNoteShown) {
            $script:RunState.CompletionVisibilityNoteShown = $true
            $runLogBox.AppendText("The backend verified the export. Windows Explorer may need a moment to refresh the destination folder.`r`n")
        }
    }
    catch {
        Write-StartupLog "Non-fatal final visibility check error: $($_.Exception.Message)"
    }

    return $true
}

function Start-OpDetectEmbeddedRun {
    param(
        [string]$ProjectId,
        [string[]]$SampleNames,
        [string]$GuiRunDir,
        [string]$ExpectedResultWindowsPath,
        [string]$InternalOut,
        [string]$RunId,
        [string]$ProgressFilePath,
        [string]$LiveLogPath,
        [bool]$CopyBamBaiToIgv = $false
    )

    if ($script:RunState -and -not $script:RunState.Finished) {
        throw 'An OpDetect analysis is already running.'
    }

    $distro = Refresh-ActiveDistro
    if ([string]::IsNullOrWhiteSpace($distro)) {
        throw 'No compatible Ubuntu or Debian WSL distribution is available.'
    }
    $script:ManagedDistro = $distro

    Reset-RunProgressUI
    $runProgressGroup.Text = "Run progress - $ProjectId"
    $runProgressBar.Value = 1
    $runPercentLabel.Text = '1%'
    Set-RunStepStatus -Step 1 -Status 'Running'
    $currentStepLabel.Text = 'Step 1 of 10 - Starting input validation'
    $statusLabel.Text = 'OpDetect is running. Replicates remain separate; alignment and consensus prediction can use substantial CPU.'
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(25, 70, 120)

    $tempRunRoot = Join-Path $env:TEMP "OpDetectGUI\\$RunId"
    [void](New-Item -ItemType Directory -Force -Path $tempRunRoot)
    $processStdoutLog = Join-Path $tempRunRoot 'wsl_process_stdout.log'
    $processStderrLog = Join-Path $tempRunRoot 'wsl_process_stderr.log'
    Remove-Item -LiteralPath $processStdoutLog, $processStderrLog -Force -ErrorAction SilentlyContinue

    $arguments = @(
        '-d', $script:ManagedDistro,
        '-u', 'root',
        '--', '/usr/bin/setsid', '--wait', '/bin/bash', "$GuiRunDir/launch_run.sh"
    )

    try {
        $process = Start-Process -FilePath 'wsl.exe' `
            -ArgumentList $arguments `
            -WindowStyle Hidden `
            -RedirectStandardOutput $processStdoutLog `
            -RedirectStandardError $processStderrLog `
            -PassThru
    }
    catch {
        throw "The background WSL process could not start.`n`n$($_.Exception.Message)"
    }

    $script:RunState = @{
        Process = $process
        ProgressPosition = 0
        LiveLogPosition = 0
        Finished = $false
        ExitCode = $null
        ProjectId = $ProjectId
        SampleNames = @($SampleNames)
        SessionHistoryAdded = $false
        ResultPath = $ExpectedResultWindowsPath
        InternalOut = $InternalOut
        ProgressFile = $ProgressFilePath
        LiveLogFile = $LiveLogPath
        ProcessStdoutLog = $processStdoutLog
        ProcessStderrLog = $processStderrLog
        GuiRunDir = $GuiRunDir
        StopRequested = $false
        StopRequestedAt = $null
        CurrentMessage = 'Step 1 of 10 - Starting input validation'
        CompletionMarkerSeen = $false
        CompletionVisibilityNoteShown = $false
        MonitorErrorReported = $false
        CopyBamBaiToIgv = $CopyBamBaiToIgv
    }
    $copyBamBaiToIgvCheckBox.Enabled = $false
    $stopRunButton.Enabled = $true
    $resetRunButton.Enabled = $false

    if ($script:RunTimer) {
        try { $script:RunTimer.Stop(); $script:RunTimer.Dispose() } catch { }
    }
    $script:RunTimer = New-Object System.Windows.Forms.Timer
    $script:RunTimer.Interval = 500
    $script:RunTimer.Add_Tick({
        try {
            if ($null -eq $script:RunState -or $script:RunState.Finished) {
                try { $script:RunTimer.Stop() } catch { }
                return
            }

            # Timer callbacks execute after Start-OpDetectEmbeddedRun has returned.
            # Never capture the function-local $ProjectId variable here: under
            # PowerShell strict mode it no longer exists and causes a JIT exception
            # at completion. The active run state is persistent for the timer's life.
            $activeProjectId = [string]$script:RunState.ProjectId

            Update-RunProgressDisplay
            Update-RunLogDisplay

            if ($script:RunState.CompletionMarkerSeen) {
                if (Complete-RunAfterVerifiedExport -ProjectId ([string]$script:RunState.ProjectId)) { return }
            }

            try { $script:RunState.Process.Refresh() } catch { }
        if (-not $script:RunState.Finished -and $script:RunState.StopRequested -and $null -ne $script:RunState.StopRequestedAt) {
            if (((Get-Date) - $script:RunState.StopRequestedAt).TotalSeconds -gt 20 -and -not $script:RunState.Process.HasExited) {
                try { $script:RunState.Process.Kill() } catch { }
            }
        }
        if (-not $script:RunState.Finished -and $script:RunState.Process.HasExited) {
            try { $script:RunState.Process.WaitForExit() } catch { }
            try { $script:RunState.Process.Refresh() } catch { }
            $script:RunState.Finished = $true
            try { $script:RunState.ExitCode = [int]$script:RunState.Process.ExitCode }
            catch { $script:RunState.ExitCode = -1 }

            Update-RunProgressDisplay
            Update-RunLogDisplay
            $script:RunTimer.Stop()
            $runButton.Enabled = $script:EnvironmentReady
            $stopRunButton.Enabled = $false
            $resetRunButton.Enabled = $true
            $copyBamBaiToIgvCheckBox.Enabled = $true

            $processExtra = ''
            try {
                if (Test-Path $script:RunState.ProcessStdoutLog) {
                    $processExtra += [System.IO.File]::ReadAllText($script:RunState.ProcessStdoutLog)
                }
                if (Test-Path $script:RunState.ProcessStderrLog) {
                    $processExtra += [System.IO.File]::ReadAllText($script:RunState.ProcessStderrLog)
                }
            }
            catch { }
            if (-not [string]::IsNullOrWhiteSpace($processExtra)) {
                $runLogBox.AppendText(($processExtra -replace "`n", "`r`n"))
            }

            if ($script:RunState.StopRequested) {
                foreach ($row in $stepTable.Rows) {
                    if ([string]$row['Status'] -eq 'Running') { $row['Status'] = 'Stopped' }
                }
                $currentStepLabel.Text = 'The run was stopped by the user.'
                $statusLabel.Text = 'OpDetect run stopped.'
                $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
                $runLogBox.AppendText("Run stopped by the user.`r`n")
            }
            elseif ($script:RunState.ExitCode -eq 0) {
                $displayProject = Get-DisplayFileStem -Value $activeProjectId
                $predictionPath = Join-Path $script:RunState.ResultPath "$displayProject gene pair predictions.xlsx"
                $operonPath = Join-Path $script:RunState.ResultPath "$displayProject predicted operons.xlsx"
                $reportPath = Join-Path $script:RunState.ResultPath 'OpDetect Run Report.docx'
                $igvPath = Join-Path $script:RunState.ResultPath 'IGV'
                $bedGraphPath = Join-Path $igvPath "$displayProject predicted operons.bedgraph"
                $filesVisible = (Test-Path -LiteralPath $predictionPath -PathType Leaf) -and
                    (Test-Path -LiteralPath $operonPath -PathType Leaf) -and
                    (Test-Path -LiteralPath $reportPath -PathType Leaf) -and
                    (Test-Path -LiteralPath $bedGraphPath -PathType Leaf) -and
                    ((-not [bool]$script:RunState.CopyBamBaiToIgv) -or (
                        (@(Get-ChildItem -LiteralPath $igvPath -Filter '*.bam' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.bam.bai' }).Count -gt 0) -and
                        (@(Get-ChildItem -LiteralPath $igvPath -Filter '*.bam.bai' -File -ErrorAction SilentlyContinue).Count -gt 0)
                    )) -and
                    (@(Get-ChildItem -LiteralPath $script:RunState.ResultPath -Filter '* fastp.html' -File -ErrorAction SilentlyContinue).Count -gt 0)

                if (-not $filesVisible) {
                    $runLogBox.AppendText("The Linux analysis finished, but Windows could not see the exported files. Attempting a recovery copy...`r`n")
                    [void](Restore-ResultsFromWsl -InternalOut $script:RunState.InternalOut -Destination $script:RunState.ResultPath -ProjectId $activeProjectId -CopyBamBaiToIgv ([bool]$script:RunState.CopyBamBaiToIgv))
                    $filesVisible = (Test-Path -LiteralPath $predictionPath -PathType Leaf) -and
                        (Test-Path -LiteralPath $operonPath -PathType Leaf) -and
                        (Test-Path -LiteralPath $reportPath -PathType Leaf) -and
                        (Test-Path -LiteralPath $bedGraphPath -PathType Leaf) -and
                        ((-not [bool]$script:RunState.CopyBamBaiToIgv) -or (
                            (@(Get-ChildItem -LiteralPath $igvPath -Filter '*.bam' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.bam.bai' }).Count -gt 0) -and
                            (@(Get-ChildItem -LiteralPath $igvPath -Filter '*.bam.bai' -File -ErrorAction SilentlyContinue).Count -gt 0)
                        )) -and
                        (@(Get-ChildItem -LiteralPath $script:RunState.ResultPath -Filter '* fastp.html' -File -ErrorAction SilentlyContinue).Count -gt 0)
                }

                if (-not $filesVisible) {
                    foreach ($row in $stepTable.Rows) {
                        if ([string]$row['Status'] -eq 'Running') { $row['Status'] = 'Failed' }
                    }
                    Set-RunStepStatus -Step 10 -Status 'Failed'
                    $currentStepLabel.Text = 'The Linux analysis finished, but Windows result export could not be verified.'
                    $statusLabel.Text = 'Results were generated in Linux but were not copied to the selected Windows folder.'
                    $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
                    $runLogBox.AppendText("Expected Windows folder: $($script:RunState.ResultPath)`r`n")
                    $runLogBox.AppendText("Internal Linux results: $($script:RunState.InternalOut)/results`r`n")
                }
                else {
                    $runProgressBar.Value = 100
                    $runPercentLabel.Text = '100%'
                    $currentStepLabel.Text = 'All 10 steps finished; the simplified result package was verified.'
                    foreach ($row in $stepTable.Rows) {
                        if ([string]$row['Status'] -ne 'Finished') { $row['Status'] = 'Finished' }
                    }
                    $statusLabel.Text = "OpDetect completed successfully. Results: $($script:RunState.ResultPath)"
                    $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
                    Add-SessionCompletedRun -ProjectId $activeProjectId -SampleNames @($script:RunState.SampleNames)
                    try {
                        $combinedLog = Join-Path $script:RunState.ResultPath 'OpDetect Run Report.docx'
                        if (-not (Test-Path -LiteralPath $combinedLog -PathType Leaf)) {
                            $runLogBox.AppendText("WARNING: Results are present, but the Word run report was not found.`r`n")
                        }
                    }
                    catch { }
                }
            }
            else {
                foreach ($row in $stepTable.Rows) {
                    if ([string]$row['Status'] -eq 'Running') { $row['Status'] = 'Failed' }
                }
                if ([string]::IsNullOrWhiteSpace($runLogBox.Text)) {
                    $runLogBox.AppendText("The Linux launcher exited before producing pipeline output. Exit code: $($script:RunState.ExitCode).`r`n")
                }
                $currentStepLabel.Text = "The run stopped with exit code $($script:RunState.ExitCode). Review the log."
                $statusLabel.Text = "OpDetect stopped with exit code $($script:RunState.ExitCode)."
                $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
            }
            return
        }
        }
        catch {
            Write-StartupLog "Run monitor error: $($_.Exception.Message)"
            if ($script:RunState -and $script:RunState.CompletionMarkerSeen) {
                [void](Complete-RunAfterVerifiedExport -ProjectId ([string]$script:RunState.ProjectId))
                return
            }
            if ($script:RunState -and -not $script:RunState.Finished -and -not $script:RunState.MonitorErrorReported) {
                $script:RunState.MonitorErrorReported = $true
                try { $runLogBox.AppendText("The GUI monitor encountered a recoverable status-check error. Pipeline output will continue to be read.`r`n") } catch { }
            }
        }
    })
    $script:RunTimer.Start()
}

$form = New-Object System.Windows.Forms.Form
if ($script:AppIcon) { $form.Icon = $script:AppIcon }
$form.Text = "OpDetect RNA-seq Pipeline"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1180, 1005)
$form.MinimumSize = New-Object System.Drawing.Size(1050, 895)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.AutoScroll = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Location = New-Object System.Drawing.Point(0, 0)
$headerPanel.Size = New-Object System.Drawing.Size(1164, 82)
$headerPanel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$headerPanel.BackColor = [System.Drawing.Color]::White
$headerPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($headerPanel)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Choose your files, then run OpDetect"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(20, 8)
$title.AutoSize = $true
$headerPanel.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "No Linux paths, config files, sample sheets, RStudio, or VS Code are required."
$subtitle.Location = New-Object System.Drawing.Point(23, 50)
$subtitle.AutoSize = $true
$headerPanel.Controls.Add($subtitle)
$headerPanel.Add_Layout({
    $subtitle.Top = $title.Bottom + 3
    $subtitle.Left = $title.Left + 3
})

$returnToSuiteButton = New-Object System.Windows.Forms.Button
$returnToSuiteButton.Text = "< Return to Prediction Suite"
$returnToSuiteButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$returnToSuiteButton.Location = New-Object System.Drawing.Point(870, 16)
$returnToSuiteButton.Size = New-Object System.Drawing.Size(265, 38)
$returnToSuiteButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$returnToSuiteButton.BackColor = [System.Drawing.Color]::FromArgb(235, 242, 237)
$returnToSuiteButton.ForeColor = [System.Drawing.Color]::FromArgb(42, 82, 52)
$returnToSuiteButton.Enabled = ($script:SuiteManaged -or $script:EmbeddedMode)
if ($script:EmbeddedMode) { $returnToSuiteButton.Text = "< Back to operon methods" }
$headerPanel.Controls.Add($returnToSuiteButton)

$returnToAnalysisButton = New-Object System.Windows.Forms.Button
$returnToAnalysisButton.Text = "< Back to analysis modules"
$returnToAnalysisButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$returnToAnalysisButton.Location = New-Object System.Drawing.Point(680, 16)
$returnToAnalysisButton.Size = New-Object System.Drawing.Size(180, 38)
$returnToAnalysisButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$returnToAnalysisButton.BackColor = [System.Drawing.Color]::White
$returnToAnalysisButton.ForeColor = [System.Drawing.Color]::FromArgb(42, 82, 52)
$returnToAnalysisButton.Visible = $script:EmbeddedMode
$headerPanel.Controls.Add($returnToAnalysisButton)

$environmentGroup = New-Object System.Windows.Forms.GroupBox
$environmentGroup.Text = "Linux and required packages"
$environmentGroup.Location = New-Object System.Drawing.Point(20, 88)
$environmentGroup.Size = New-Object System.Drawing.Size(1115, 105)
$environmentGroup.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($environmentGroup)

$environmentSummaryLabel = New-Object System.Windows.Forms.Label
$environmentSummaryLabel.Text = "Checking Linux and required packages..."
$environmentSummaryLabel.Location = New-Object System.Drawing.Point(14, 22)
$environmentSummaryLabel.Size = New-Object System.Drawing.Size(770, 22)
$environmentGroup.Controls.Add($environmentSummaryLabel)

$refreshEnvironmentButton = New-Object System.Windows.Forms.Button
$refreshEnvironmentButton.Text = "Readiness check"
$refreshEnvironmentButton.Location = New-Object System.Drawing.Point(865, 17)
$refreshEnvironmentButton.Size = New-Object System.Drawing.Size(116, 28)
$refreshEnvironmentButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$environmentGroup.Controls.Add($refreshEnvironmentButton)

$repairEnvironmentButton = New-Object System.Windows.Forms.Button
$repairEnvironmentButton.Text = "Install or repair"
$repairEnvironmentButton.Location = New-Object System.Drawing.Point(987, 17)
$repairEnvironmentButton.Size = New-Object System.Drawing.Size(112, 28)
$repairEnvironmentButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$environmentGroup.Controls.Add($repairEnvironmentButton)

$environmentToolTip = New-Object System.Windows.Forms.ToolTip
$environmentToolTip.AutoPopDelay = 10000
$environmentToolTip.InitialDelay = 300
$environmentToolTip.ReshowDelay = 100

$script:ActiveOpDetectParameterPopup = $null
function Hide-OpDetectParameterPopup {
    if ($script:ActiveOpDetectParameterPopup) {
        try { $script:ActiveOpDetectParameterPopup.Close() } catch { }
        try { $script:ActiveOpDetectParameterPopup.Dispose() } catch { }
        $script:ActiveOpDetectParameterPopup = $null
    }
}

function Format-OpDetectStructuredHelpText {
    param([System.Windows.Forms.RichTextBox]$Box, [string]$Title)
    if (-not $Box) { return }

    $regularFont = New-Object System.Drawing.Font('Segoe UI', [single]9.5, [System.Drawing.FontStyle]::Regular)
    $boldFont = New-Object System.Drawing.Font('Segoe UI', [single]9.5, [System.Drawing.FontStyle]::Bold)
    $headingFont = New-Object System.Drawing.Font('Segoe UI', [single]10.5, [System.Drawing.FontStyle]::Bold)
    $titleFont = New-Object System.Drawing.Font('Segoe UI', [single]11.5, [System.Drawing.FontStyle]::Bold)
    $headingColor = [System.Drawing.Color]::FromArgb(42, 82, 52)
    $bodyColor = [System.Drawing.Color]::FromArgb(30, 42, 34)

    $Box.SelectAll()
    $Box.SelectionFont = $regularFont
    $Box.SelectionColor = $bodyColor

    if ($Title) {
        $titleIndex = $Box.Text.IndexOf($Title, [System.StringComparison]::Ordinal)
        if ($titleIndex -ge 0) {
            $Box.Select($titleIndex, $Title.Length)
            $Box.SelectionFont = $titleFont
            $Box.SelectionColor = $headingColor
        }
    }

    # Same category-name treatment as Differential Expression / GO / Networks.
    $prefixPattern = '(?m)^([A-Za-z][A-Za-z0-9 /+&().,_\-]{1,72}:)'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Box.Text, $prefixPattern)) {
        $Box.Select($match.Index, $match.Length)
        $Box.SelectionFont = $boldFont
        $Box.SelectionColor = $headingColor
    }

    $sectionPattern = '(?m)^([^\r\n:]{2,90})(?=\r?\n(?:What this setting controls:|Allowed range:|Recommended starting value:|When to lower it:|When to raise it:|Practical trade-off:))'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Box.Text, $sectionPattern)) {
        $Box.Select($match.Index, $match.Length)
        $Box.SelectionFont = $headingFont
        $Box.SelectionColor = $headingColor
    }

    $Box.Select(0, 0)
}

function Show-OpDetectParameterPopup {
    param([System.Windows.Forms.Control]$Anchor, [string]$Title, [string]$Message)
    Hide-OpDetectParameterPopup
    $screen = [System.Windows.Forms.Screen]::FromControl($Anchor)
    $area = $screen.WorkingArea
    $popupWidth = [Math]::Min(560, [Math]::Max(390, ($area.Width - 30)))
    $fullText = "$Title`r`n`r`n$Message"
    $font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $measure = [System.Windows.Forms.TextRenderer]::MeasureText($fullText, $font, ([System.Drawing.Size]::new(($popupWidth - 32), 3000)), ([System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix))
    $popupHeight = [Math]::Min(650, [Math]::Max(210, ($measure.Height + 34)))
    $box = New-Object System.Windows.Forms.RichTextBox
    $box.Size = [System.Drawing.Size]::new(($popupWidth - 4), ($popupHeight - 4))
    $box.ReadOnly = $true
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $box.BackColor = [System.Drawing.Color]::White
    $box.ForeColor = [System.Drawing.Color]::FromArgb(30, 42, 34)
    $box.Font = $font
    $box.WordWrap = $true
    $box.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
    $box.Text = $fullText
    Format-OpDetectStructuredHelpText -Box $box -Title $Title

    # Do not use $host here. PowerShell variable names are case-insensitive,
    # and $Host is a built-in read-only variable.
    $popupControlHost = New-Object System.Windows.Forms.ToolStripControlHost -ArgumentList $box
    $popupControlHost.AutoSize = $false
    $popupControlHost.Size = $box.Size
    $popupControlHost.Margin = New-Object System.Windows.Forms.Padding(0)
    $popup = New-Object System.Windows.Forms.ToolStripDropDown
    $popup.AutoSize = $false
    $popup.Padding = New-Object System.Windows.Forms.Padding(1)
    $popup.Size = [System.Drawing.Size]::new($popupWidth, $popupHeight)
    $popup.BackColor = [System.Drawing.Color]::FromArgb(190, 205, 194)
    $popup.DropShadowEnabled = $true
    [void]$popup.Items.Add($popupControlHost)
    $point = $Anchor.PointToScreen([System.Drawing.Point]::new(($Anchor.Width + 6), 0))
    $x = $point.X
    if (($x + $popupWidth) -gt $area.Right) { $x = $Anchor.PointToScreen([System.Drawing.Point]::new((-1 * ($popupWidth + 6)), 0)).X }
    $x = [Math]::Max(($area.Left + 4), [Math]::Min($x, ($area.Right - $popupWidth - 4)))
    $y = [Math]::Max(($area.Top + 4), [Math]::Min($point.Y, ($area.Bottom - $popupHeight - 4)))
    $script:ActiveOpDetectParameterPopup = $popup
    $popup.Show([System.Drawing.Point]::new($x, $y))
}

function New-CircledParameterHelpButton {
    param(
        [string]$Title,
        [string]$Message,
        [int]$X,
        [int]$Y
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = '?'
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size(22, 22)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(72, 126, 83)
    $button.BackColor = [System.Drawing.Color]::FromArgb(235, 245, 237)
    $button.ForeColor = [System.Drawing.Color]::FromArgb(42, 82, 52)
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $button.TabStop = $false
    $button.Cursor = [System.Windows.Forms.Cursors]::Help
    $button.Tag = [pscustomobject]@{ Title = $Title; Message = $Message }

    $circlePath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $circlePath.AddEllipse(0, 0, 21, 21)
    $button.Region = New-Object System.Drawing.Region($circlePath)
    $circlePath.Dispose()

    $environmentToolTip.SetToolTip($button, 'Hover to view the complete accepted range, recommended value, use cases, and trade-offs.')
    $button.Add_MouseEnter({ param($sender, $eventArgs) Show-OpDetectParameterPopup -Anchor $sender -Title ([string]$sender.Tag.Title) -Message ([string]$sender.Tag.Message) })
    $button.Add_MouseLeave({ Hide-OpDetectParameterPopup })
    return $button
}


function Set-OpDetectInputHoverHelp {
    param(
        [System.Windows.Forms.Control[]]$Controls,
        [string]$Title,
        [string]$Message
    )
    if (-not $Message) { return }
    foreach ($control in @($Controls)) {
        if (-not $control) { continue }
        $environmentToolTip.SetToolTip($control, $Message)
        $control.AccessibleName = $Title
        $control.AccessibleDescription = $Message
        $control.Add_MouseHover({
            param($sender, $eventArgs)
            if ($sender.AccessibleDescription) {
                Show-OpDetectParameterPopup -Anchor $sender -Title ([string]$sender.AccessibleName) -Message ([string]$sender.AccessibleDescription)
            }
        })
        $control.Add_MouseLeave({ Hide-OpDetectParameterPopup })
        $control.Add_Leave({ Hide-OpDetectParameterPopup })
    }
}

$linuxBadge = New-StatusBadge -Name "Linux" -X 14 -Y 59 -Width 116
$condaBadge = New-StatusBadge -Name "Conda" -X 136 -Y 59 -Width 116
$gitBadge = New-StatusBadge -Name "Git" -X 258 -Y 59 -Width 116
$fastpBadge = New-StatusBadge -Name "fastp" -X 380 -Y 59 -Width 116
$hisat2Badge = New-StatusBadge -Name "HISAT2" -X 502 -Y 59 -Width 116
$samtoolsBadge = New-StatusBadge -Name "SAMtools" -X 624 -Y 59 -Width 116
$bedtoolsBadge = New-StatusBadge -Name "BEDtools" -X 746 -Y 59 -Width 116
$pythonBadge = New-StatusBadge -Name "Python" -X 868 -Y 59 -Width 131
foreach ($badge in @($linuxBadge, $condaBadge, $gitBadge, $fastpBadge, $hisat2Badge, $samtoolsBadge, $bedtoolsBadge, $pythonBadge)) {
    $environmentGroup.Controls.Add($badge)
}

$referenceLabel = New-Object System.Windows.Forms.Label
$referenceLabel.Text = "Reference FASTA"
$referenceLabel.Location = New-Object System.Drawing.Point(20, 203)
$referenceLabel.Size = New-Object System.Drawing.Size(130, 25)
$form.Controls.Add($referenceLabel)

$referenceBox = New-ReadOnlyPathTextBox -X 155 -Y 199 -Width 860
$referenceBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($referenceBox)

$referenceButton = New-Object System.Windows.Forms.Button
$referenceButton.Text = "Browse..."
$referenceButton.Location = New-Object System.Drawing.Point(1025, 197)
$referenceButton.Size = New-Object System.Drawing.Size(110, 30)
$referenceButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($referenceButton)

$annotationLabel = New-Object System.Windows.Forms.Label
$annotationLabel.Text = "Annotation GFF / GTF"
$annotationLabel.Location = New-Object System.Drawing.Point(20, 243)
$annotationLabel.Size = New-Object System.Drawing.Size(135, 25)
$form.Controls.Add($annotationLabel)

$annotationBox = New-ReadOnlyPathTextBox -X 155 -Y 239 -Width 860
$annotationBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($annotationBox)

$annotationButton = New-Object System.Windows.Forms.Button
$annotationButton.Text = "Browse..."
$annotationButton.Location = New-Object System.Drawing.Point(1025, 237)
$annotationButton.Size = New-Object System.Drawing.Size(110, 30)
$annotationButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($annotationButton)

$projectLabel = New-Object System.Windows.Forms.Label
$projectLabel.Text = "Project / condition"
$projectLabel.Location = New-Object System.Drawing.Point(20, 323)
$projectLabel.Size = New-Object System.Drawing.Size(130, 25)
$form.Controls.Add($projectLabel)

$projectBox = New-Object System.Windows.Forms.TextBox
$projectBox.Location = New-Object System.Drawing.Point(155, 319)
$projectBox.Size = New-Object System.Drawing.Size(300, 25)
$projectBox.Text = "opdetect_project"
$form.Controls.Add($projectBox)

$projectHint = New-Object System.Windows.Forms.Label
$projectHint.Text = "Defaults to the FASTA filename; you may edit it"
$projectHint.Location = New-Object System.Drawing.Point(470, 323)
$projectHint.AutoSize = $true
$form.Controls.Add($projectHint)

$samplesLabel = New-Object System.Windows.Forms.Label
$samplesLabel.Text = "Biological RNA-seq replicates, one to six. Add each independent library separately for one condition."
$samplesLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$samplesLabel.Location = New-Object System.Drawing.Point(20, 359)
$samplesLabel.AutoSize = $true
$form.Controls.Add($samplesLabel)

$sampleTable = New-Object System.Data.DataTable
[void]$sampleTable.Columns.Add("Sample", [string])
[void]$sampleTable.Columns.Add("Read 1 / single-end FASTQ", [string])
[void]$sampleTable.Columns.Add("Read 2 FASTQ (NA for single-end)", [string])

$sampleGrid = New-Object System.Windows.Forms.DataGridView
$sampleGrid.Location = New-Object System.Drawing.Point(20, 389)
$sampleGrid.Size = New-Object System.Drawing.Size(1115, 96)
$sampleGrid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

# Define the columns explicitly before binding the DataTable.  On some
# Windows PowerShell 5.1 / WinForms combinations, automatically generated
# columns are not available immediately after DataSource is assigned.  The
# previous Columns[0] access could therefore raise IndexOutOfRangeException
# before the graphical window opened.
$sampleGrid.AutoGenerateColumns = $false
$sampleGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill

$sampleNameColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$sampleNameColumn.Name = 'SampleColumn'
$sampleNameColumn.HeaderText = 'Biological replicate'
$sampleNameColumn.DataPropertyName = 'Sample'
$sampleNameColumn.MinimumWidth = 160
$sampleNameColumn.FillWeight = 18
$sampleNameColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
[void]$sampleGrid.Columns.Add($sampleNameColumn)

$readOneColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$readOneColumn.Name = 'ReadOneColumn'
$readOneColumn.HeaderText = 'Mate 1 / single-end FASTQ'
$readOneColumn.DataPropertyName = 'Read 1 / single-end FASTQ'
$readOneColumn.MinimumWidth = 260
$readOneColumn.FillWeight = 41
$readOneColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
[void]$sampleGrid.Columns.Add($readOneColumn)

$readTwoColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$readTwoColumn.Name = 'ReadTwoColumn'
$readTwoColumn.HeaderText = 'Mate 2 FASTQ (NA for single-end)'
$readTwoColumn.DataPropertyName = 'Read 2 FASTQ (NA for single-end)'
$readTwoColumn.MinimumWidth = 260
$readTwoColumn.FillWeight = 41
$readTwoColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
[void]$sampleGrid.Columns.Add($readTwoColumn)

$sampleGrid.DataSource = $sampleTable
$sampleGrid.AllowUserToAddRows = $false
$sampleGrid.AllowUserToDeleteRows = $false
$sampleGrid.AllowUserToResizeRows = $false
$sampleGrid.AllowUserToResizeColumns = $false
$sampleGrid.ReadOnly = $true
$sampleGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$sampleGrid.MultiSelect = $true
$sampleGrid.RowHeadersVisible = $false
$sampleGrid.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$sampleGrid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::DisableResizing
$sampleGrid.EnableHeadersVisualStyles = $false
$sampleGrid.GridColor = [System.Drawing.Color]::Black
$sampleGrid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::Single
$sampleGrid.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::Single
$sampleGrid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(235, 245, 237)
$sampleGrid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(42, 82, 52)
$sampleGrid.ColumnHeadersDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(235, 245, 237)
$sampleGrid.ColumnHeadersDefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::FromArgb(42, 82, 52)
$sampleGrid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$sampleGrid.ColumnHeadersHeight = 28
$sampleGrid.RowTemplate.Height = 20
$form.Controls.Add($sampleGrid)

$addPairedButton = New-Object System.Windows.Forms.Button
$addPairedButton.Text = "Add paired-end mates"
$addPairedButton.Location = New-Object System.Drawing.Point(20, 491)
$addPairedButton.Size = New-Object System.Drawing.Size(190, 30)
$form.Controls.Add($addPairedButton)
$environmentToolTip.SetToolTip($addPairedButton, 'Select two FASTQ files sequentially. The first is mate 1 and the second is mate 2. OpDetect does not require R1/R2 tokens or matching filenames.')

$addSingleButton = New-Object System.Windows.Forms.Button
$addSingleButton.Text = "Add single-end replicate(s)"
$addSingleButton.Location = New-Object System.Drawing.Point(218, 491)
$addSingleButton.Size = New-Object System.Drawing.Size(170, 30)
$form.Controls.Add($addSingleButton)

$scanFolderButton = New-Object System.Windows.Forms.Button
$scanFolderButton.Text = "Scan FASTQ folder"
$scanFolderButton.Location = New-Object System.Drawing.Point(396, 491)
$scanFolderButton.Size = New-Object System.Drawing.Size(140, 30)
$form.Controls.Add($scanFolderButton)

$removeButton = New-Object System.Windows.Forms.Button
$removeButton.Text = "Remove selected"
$removeButton.Location = New-Object System.Drawing.Point(544, 491)
$removeButton.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($removeButton)

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = "Clear samples"
$clearButton.Location = New-Object System.Drawing.Point(677, 491)
$clearButton.Size = New-Object System.Drawing.Size(128, 30)
$form.Controls.Add($clearButton)

$sessionHistoryGroup = New-Object System.Windows.Forms.GroupBox
$sessionHistoryGroup.Text = 'Completed this session'
$sessionHistoryGroup.Location = New-Object System.Drawing.Point(855, 491)
$sessionHistoryGroup.Size = New-Object System.Drawing.Size(280, 174)
$sessionHistoryGroup.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($sessionHistoryGroup)

$sessionRunList = New-Object System.Windows.Forms.ListBox
$sessionRunList.Location = New-Object System.Drawing.Point(9, 19)
$sessionRunList.Size = New-Object System.Drawing.Size(262, 146)
$sessionRunList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$sessionRunList.IntegralHeight = $false
$sessionRunList.HorizontalScrollbar = $true
$sessionRunList.Font = New-Object System.Drawing.Font('Segoe UI', 8.25)
[void]$sessionRunList.Items.Add('No completed runs yet.')
$sessionHistoryGroup.Controls.Add($sessionRunList)

$sessionHistoryToolTip = New-Object System.Windows.Forms.ToolTip
$sessionHistoryToolTip.SetToolTip($sessionHistoryGroup, 'Successful runs completed during this Prediction Suite session. RESET NEW RUN and Return to Prediction Suite keep this list; closing the Prediction Suite clears it.')
$sessionHistoryToolTip.SetToolTip($sessionRunList, 'Successful runs completed during this Prediction Suite session. RESET NEW RUN and Return to Prediction Suite keep this list; closing the Prediction Suite clears it.')

$outputLabel = New-Object System.Windows.Forms.Label
$outputLabel.Text = "Save results in"
$outputLabel.Location = New-Object System.Drawing.Point(20, 283)
$outputLabel.Size = New-Object System.Drawing.Size(130, 25)
$form.Controls.Add($outputLabel)

$outputBox = New-ReadOnlyPathTextBox -X 155 -Y 279 -Width 860
$outputBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$defaultOutput = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "OpDetect_Results"
$outputBox.Text = $defaultOutput
$form.Controls.Add($outputBox)

$outputButton = New-Object System.Windows.Forms.Button
$outputButton.Text = "Choose folder..."
$outputButton.Location = New-Object System.Drawing.Point(1025, 277)
$outputButton.Size = New-Object System.Drawing.Size(110, 30)
$outputButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($outputButton)

$threadsLabel = New-Object System.Windows.Forms.Label
$threadsLabel.Text = "CPU threads"
$threadsLabel.Location = New-Object System.Drawing.Point(20, 541)
$threadsLabel.AutoSize = $true
$form.Controls.Add($threadsLabel)

$threadsBox = New-Object System.Windows.Forms.NumericUpDown
$threadsBox.Location = New-Object System.Drawing.Point(110, 537)
$threadsBox.Size = New-Object System.Drawing.Size(65, 25)
$threadsBox.Minimum = 1
$cpuTopology = Get-CpuTopology
$threadsBox.Maximum = [decimal][Math]::Max(1, [int]$cpuTopology.Logical)
$threadsBox.Value = [decimal][Math]::Min([int]$threadsBox.Maximum, [int]$cpuTopology.Recommended)
$form.Controls.Add($threadsBox)

# Keep all analysis settings on one clearly spaced row.
$thresholdLabel = New-Object System.Windows.Forms.Label
$thresholdLabel.Text = "Prediction threshold"
$thresholdLabel.Location = New-Object System.Drawing.Point(180, 541)
$thresholdLabel.Size = New-Object System.Drawing.Size(118, 24)
$form.Controls.Add($thresholdLabel)

$thresholdHelpText = @"
What this setting controls:
The prediction threshold is the minimum OpDetect model probability required for a candidate adjacent-gene pair to be accepted. Lower values accept more candidates; higher values retain only stronger model predictions.

Allowed range:
The GUI accepts values from 0.05 to 0.95 in steps of 0.05. Values near either extreme should be used only after comparison with known operons or independent evidence.

Recommended starting value:
0.50 is the balanced default for routine bacterial short-read RNA-seq and is the best starting point when no organism-specific benchmark is available.

When to lower it:
Use about 0.35 to 0.45 for exploratory discovery, weakly expressed operons, shallow coverage, or when sensitivity is more important than false-positive control. Review these extra candidates in IGV and with replicate consistency.

When to raise it:
Use about 0.60 to 0.75 for high-coverage data, strong biological replicates, or when a smaller high-confidence operon set is preferred. Raising the threshold can miss genuine weak or condition-specific transcription units.

Practical trade-off:
0.35-0.45 prioritizes sensitivity and returns more candidates. 0.50 balances sensitivity and specificity. 0.60-0.75 prioritizes specificity and a smaller high-confidence result set. Compare thresholds on known operons whenever organism-specific validation data are available.
"@
$thresholdHelpButton = New-CircledParameterHelpButton -Title 'OpDetect prediction threshold' -Message $thresholdHelpText -X 300 -Y 538
$form.Controls.Add($thresholdHelpButton)
$environmentToolTip.SetToolTip($thresholdHelpButton, 'Explain the accepted range, default, and sensitivity versus specificity trade-off.')

$thresholdBox = New-Object System.Windows.Forms.NumericUpDown
$thresholdBox.Location = New-Object System.Drawing.Point(328, 537)
$thresholdBox.Size = New-Object System.Drawing.Size(65, 25)
$thresholdBox.Minimum = [decimal]0.05
$thresholdBox.Maximum = [decimal]0.95
$thresholdBox.DecimalPlaces = 2
$thresholdBox.Increment = [decimal]0.05
$thresholdBox.Value = [decimal]0.50
$form.Controls.Add($thresholdBox)

$featureLabel = New-Object System.Windows.Forms.Label
$featureLabel.Text = "Annotation feature"
$featureLabel.Location = New-Object System.Drawing.Point(410, 541)
$featureLabel.Size = New-Object System.Drawing.Size(108, 22)
$form.Controls.Add($featureLabel)

$featureBox = New-Object System.Windows.Forms.ComboBox
$featureBox.Location = New-Object System.Drawing.Point(520, 537)
$featureBox.Size = New-Object System.Drawing.Size(85, 25)
$featureBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$featureBox.Items.Add("CDS")
[void]$featureBox.Items.Add("gene")
$featureBox.SelectedIndex = 0
$form.Controls.Add($featureBox)

$topologyLabel = New-Object System.Windows.Forms.Label
$topologyLabel.Text = "Replicon topology"
$topologyLabel.Location = New-Object System.Drawing.Point(620, 541)
$topologyLabel.Size = New-Object System.Drawing.Size(112, 22)
$form.Controls.Add($topologyLabel)

$topologyBox = New-Object System.Windows.Forms.ComboBox
$topologyBox.Location = New-Object System.Drawing.Point(735, 537)
$topologyBox.Size = New-Object System.Drawing.Size(75, 25)
$topologyBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$topologyBox.Items.Add("Auto")
[void]$topologyBox.Items.Add("Circular")
[void]$topologyBox.Items.Add("Linear")
$topologyBox.SelectedIndex = 0
$form.Controls.Add($topologyBox)

$cpuHintLabel = New-Object System.Windows.Forms.Label
$physicalText = if ($null -ne $cpuTopology.Physical) { "$($cpuTopology.Physical) physical cores, " } else { "" }
$cpuHintLabel.Text = "Detected: $physicalText$($cpuTopology.Logical) logical processors. Suggested: $($cpuTopology.Recommended) threads."
$cpuHintLabel.Location = New-Object System.Drawing.Point(20, 567)
$cpuHintLabel.Size = New-Object System.Drawing.Size(585, 22)
$cpuHintLabel.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
$cpuHintLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($cpuHintLabel)

$copyBamBaiToIgvCheckBox = New-Object System.Windows.Forms.CheckBox
$copyBamBaiToIgvCheckBox.Text = "Copy BAM and BAI to IGV folder"
$copyBamBaiToIgvCheckBox.Location = New-Object System.Drawing.Point(620, 565)
$copyBamBaiToIgvCheckBox.Size = New-Object System.Drawing.Size(220, 24)
$copyBamBaiToIgvCheckBox.Checked = $false
$copyBamBaiToIgvCheckBox.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$copyBamBaiToIgvCheckBox.ForeColor = [System.Drawing.Color]::FromArgb(45, 70, 50)
$copyBamBaiToIgvCheckBox.UseCompatibleTextRendering = $false
$form.Controls.Add($copyBamBaiToIgvCheckBox)
$environmentToolTip.SetToolTip($copyBamBaiToIgvCheckBox, 'Optional. Copies each final coordinate-sorted BAM and matching BAI into the exported IGV folder. Leave clear to avoid duplicating large alignment files; the predicted-operon bedGraph, FASTA and annotation are still exported.')

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "RUN OPDETECT"
$runButton.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$runButton.Location = New-Object System.Drawing.Point(20, 631)
$runButton.Size = New-Object System.Drawing.Size(205, 42)
$runButton.Enabled = $true
$form.Controls.Add($runButton)

$stopRunButton = New-Object System.Windows.Forms.Button
$stopRunButton.Text = "STOP RUN"
$stopRunButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$stopRunButton.Location = New-Object System.Drawing.Point(235, 635)
$stopRunButton.Size = New-Object System.Drawing.Size(125, 34)
$stopRunButton.Enabled = $false
$stopRunButton.BackColor = [System.Drawing.Color]::FromArgb(245, 225, 225)
$stopRunButton.ForeColor = [System.Drawing.Color]::DarkRed
$form.Controls.Add($stopRunButton)

$openOutputButton = New-Object System.Windows.Forms.Button
$openOutputButton.Text = "Open results location"
$openOutputButton.Location = New-Object System.Drawing.Point(375, 635)
$openOutputButton.Size = New-Object System.Drawing.Size(150, 34)
$form.Controls.Add($openOutputButton)

$instructionsButton = New-Object System.Windows.Forms.Button
$instructionsButton.Text = "Open instructions"
$instructionsButton.Location = New-Object System.Drawing.Point(535, 635)
$instructionsButton.Size = New-Object System.Drawing.Size(130, 34)
$form.Controls.Add($instructionsButton)

$resetRunButton = New-Object System.Windows.Forms.Button
$resetRunButton.Text = "RESET NEW RUN"
$resetRunButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$resetRunButton.Location = New-Object System.Drawing.Point(675, 635)
$resetRunButton.Size = New-Object System.Drawing.Size(130, 34)
$resetRunButton.Enabled = $true
$form.Controls.Add($resetRunButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ""
$statusLabel.Location = New-Object System.Drawing.Point(20, 595)
$statusLabel.Size = New-Object System.Drawing.Size(785, 32)
$statusLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($statusLabel)

$runProgressGroup = New-Object System.Windows.Forms.GroupBox
$runProgressGroup.Text = "Run progress and live Python code - 10 steps"
$runProgressGroup.Location = New-Object System.Drawing.Point(20, 673)
$runProgressGroup.Size = New-Object System.Drawing.Size(1115, 292)
$runProgressGroup.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($runProgressGroup)

$currentStepLabel = New-Object System.Windows.Forms.Label
$currentStepLabel.Text = "Ready to start. The workflow contains 10 steps."
$currentStepLabel.Location = New-Object System.Drawing.Point(15, 24)
$currentStepLabel.Size = New-Object System.Drawing.Size(950, 22)
$currentStepLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$runProgressGroup.Controls.Add($currentStepLabel)

$runPercentLabel = New-Object System.Windows.Forms.Label
$runPercentLabel.Text = "0%"
$runPercentLabel.Location = New-Object System.Drawing.Point(1030, 24)
$runPercentLabel.Size = New-Object System.Drawing.Size(55, 22)
$runPercentLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$runPercentLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$runProgressGroup.Controls.Add($runPercentLabel)

$openOpDetectLogFileButton = New-Object System.Windows.Forms.Button
$openOpDetectLogFileButton.Text = 'Open log file'
$openOpDetectLogFileButton.Size = New-Object System.Drawing.Size(105, 25)
$openOpDetectLogFileButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$openOpDetectLogFileButton.Add_Click({
    $candidate = if ($script:RunState -and $script:RunState.LiveLogFile -and (Test-Path -LiteralPath $script:RunState.LiveLogFile -PathType Leaf)) { $script:RunState.LiveLogFile } else { $null }
    if ($candidate) { Start-Process -FilePath $candidate } else { [System.Windows.Forms.MessageBox]::Show($form, 'No OpDetect live log exists yet.', 'Log file', 'OK', 'Information') | Out-Null }
})
$runProgressGroup.Controls.Add($openOpDetectLogFileButton)

$openOpDetectLogFolderButton = New-Object System.Windows.Forms.Button
$openOpDetectLogFolderButton.Text = 'Open log folder'
$openOpDetectLogFolderButton.Size = New-Object System.Drawing.Size(115, 25)
$openOpDetectLogFolderButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$openOpDetectLogFolderButton.Add_Click({
    $candidate = if ($script:RunState -and $script:RunState.LiveLogFile) { Split-Path -Parent $script:RunState.LiveLogFile } else { $null }
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) { Start-Process explorer.exe $candidate } else { [System.Windows.Forms.MessageBox]::Show($form, 'No OpDetect log folder exists yet.', 'Log folder', 'OK', 'Information') | Out-Null }
})
$runProgressGroup.Controls.Add($openOpDetectLogFolderButton)

$runProgressBar = New-Object System.Windows.Forms.ProgressBar
$runProgressBar.Location = New-Object System.Drawing.Point(17, 50)
$runProgressBar.Size = New-Object System.Drawing.Size(1070, 20)
$runProgressBar.Minimum = 0
$runProgressBar.Maximum = 100
$runProgressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$runProgressGroup.Controls.Add($runProgressBar)

$stepTable = New-Object System.Data.DataTable
[void]$stepTable.Columns.Add('Task', [string])
[void]$stepTable.Columns.Add('Status', [string])
$stepNames = @(
    'Validate inputs',
    'Prepare OpDetect software',
    'Convert annotation',
    'Build HISAT2 index',
    'QC and align biological replicates',
    'Integrate replicate coverage',
    'Prepare replicate-aware input',
    'Run replicate-consensus models',
    'Build robust candidate operons',
    'Export Windows results and tracks'
)
for ($i = 0; $i -lt $stepNames.Count; $i++) {
    [void]$stepTable.Rows.Add($stepNames[$i], 'Pending')
}

$stepGrid = New-Object System.Windows.Forms.DataGridView
$stepGrid.Location = New-Object System.Drawing.Point(17, 80)
$stepGrid.Size = New-Object System.Drawing.Size(470, 202)
$stepGrid.AutoGenerateColumns = $false
$stepGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None

$taskColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$taskColumn.Name = 'TaskColumn'
$taskColumn.HeaderText = 'Task'
$taskColumn.DataPropertyName = 'Task'
$taskColumn.MinimumWidth = 250
$taskColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
[void]$stepGrid.Columns.Add($taskColumn)

$stepStatusColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$stepStatusColumn.Name = 'StatusColumn'
$stepStatusColumn.HeaderText = 'Status'
$stepStatusColumn.DataPropertyName = 'Status'
$stepStatusColumn.Width = 110
$stepStatusColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::None
[void]$stepGrid.Columns.Add($stepStatusColumn)

$stepGrid.DataSource = $stepTable
$stepGrid.ReadOnly = $true
$stepGrid.AllowUserToAddRows = $false
$stepGrid.AllowUserToDeleteRows = $false
$stepGrid.AllowUserToResizeRows = $false
$stepGrid.AllowUserToResizeColumns = $false
$stepGrid.RowHeadersVisible = $false
$stepGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$stepGrid.ScrollBars = [System.Windows.Forms.ScrollBars]::None
$stepGrid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::DisableResizing
$stepGrid.EnableHeadersVisualStyles = $false
$stepGrid.GridColor = [System.Drawing.Color]::Black
$stepGrid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::Single
$stepGrid.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::Single
$stepGrid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$stepGrid.ColumnHeadersHeight = 25
$stepGrid.RowTemplate.Height = 17
$stepGrid.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
foreach ($gridRow in $stepGrid.Rows) { $gridRow.Height = 17 }
$runProgressGroup.Controls.Add($stepGrid)

$runLogBox = New-Object System.Windows.Forms.RichTextBox
$runLogBox.Location = New-Object System.Drawing.Point(500, 80)
$runLogBox.Size = New-Object System.Drawing.Size(587, 202)
$runLogBox.ReadOnly = $true
$runLogBox.WordWrap = $false
$runLogBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
$runLogBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$runLogBox.BackColor = [System.Drawing.Color]::White
$runProgressGroup.Controls.Add($runLogBox)

function Layout-OpDetectRunProgress {
    if (-not $runProgressGroup -or $runProgressGroup.IsDisposed) { return }
    $innerWidth = [Math]::Max(620, ($runProgressGroup.ClientSize.Width - 34))
    $contentHeight = [Math]::Max(120, ($runProgressGroup.ClientSize.Height - 86))
    $gap = 12
    $stepWidth = [Math]::Max(390, [int][Math]::Floor($innerWidth * 0.42))
    $logWidth = [Math]::Max(210, ($innerWidth - $stepWidth - $gap))

    $openOpDetectLogFolderButton.SetBounds(($runProgressGroup.ClientSize.Width - 310), 19, 115, 25)
    $openOpDetectLogFileButton.SetBounds(($runProgressGroup.ClientSize.Width - 190), 19, 105, 25)
    $currentStepLabel.SetBounds(15, 22, [Math]::Max(240, ($runProgressGroup.ClientSize.Width - 345)), 20)
    $runPercentLabel.SetBounds(($runProgressGroup.ClientSize.Width - 72), 22, 55, 20)
    $runProgressBar.SetBounds(17, 47, $innerWidth, 19)
    $stepGrid.SetBounds(17, 76, $stepWidth, $contentHeight)
    $runLogBox.SetBounds((17 + $stepWidth + $gap), 76, $logWidth, $contentHeight)
}
$runProgressGroup.Add_Resize({ Layout-OpDetectRunProgress })
Layout-OpDetectRunProgress

# The standalone OpDetect window keeps its original spacious layout.  When it
# is hosted inside Bacterial RNA Analysis, compact the same controls into one
# 802-pixel canvas so the complete form is visible at common laptop heights.
# AutoScroll remains as a fallback for unusually small or highly scaled
# displays; content is never silently clipped below the embedded host.
if ($script:EmbeddedMode) {
    # Fit the embedded interface on one canvas. The previous 56-pixel header
    # clipped the subtitle into the environment group at normal DPI.
    $form.AutoScroll = $false
    $form.AutoScrollMinSize = New-Object System.Drawing.Size(0, 0)

    $headerPanel.SetBounds(0, 0, 1164, 72)
    $title.Location = New-Object System.Drawing.Point(20, 5)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $subtitle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $subtitle.Location = New-Object System.Drawing.Point(23, 39)
    $returnToAnalysisButton.SetBounds(680, 8, 180, 34)
    $returnToSuiteButton.SetBounds(870, 8, 265, 34)

    $environmentGroup.SetBounds(20, 78, 1115, 76)
    $environmentSummaryLabel.SetBounds(14, 18, 770, 20)
    $refreshEnvironmentButton.SetBounds(865, 14, 116, 26)
    $repairEnvironmentButton.SetBounds(987, 14, 112, 26)
    foreach ($badge in @($linuxBadge, $condaBadge, $gitBadge, $fastpBadge, $hisat2Badge, $samtoolsBadge, $bedtoolsBadge, $pythonBadge)) {
        $badge.Top = 44
        $badge.Height = 25
    }

    $referenceLabel.Top = 162; $referenceBox.Top = 158; $referenceButton.Top = 156
    $annotationLabel.Top = 193; $annotationBox.Top = 189; $annotationButton.Top = 187
    $outputLabel.Top = 224; $outputBox.Top = 220; $outputButton.Top = 218
    $projectLabel.Top = 255; $projectBox.Top = 251; $projectHint.Top = 255

    $samplesLabel.Top = 284
    $sampleGrid.SetBounds(20, 307, 1115, 92)
    $addPairedButton.Top = 405
    $addSingleButton.Top = 405
    $scanFolderButton.Top = 405
    $removeButton.Top = 405
    $clearButton.Top = 405
    $sessionHistoryGroup.SetBounds(855, 405, 280, 145)
    $sessionRunList.SetBounds(9, 19, 262, 117)

    # Leave a visible gap after the sample-action buttons so the analysis
    # settings read as a separate row instead of touching the buttons above.
    $threadsLabel.SetBounds(20, 460, 86, 22); $threadsBox.SetBounds(110, 456, 65, 25)
    $thresholdLabel.SetBounds(180, 460, 118, 24); $thresholdHelpButton.SetBounds(300, 457, 22, 22); $thresholdBox.SetBounds(328, 456, 65, 25)
    $featureLabel.SetBounds(410, 460, 108, 22); $featureBox.SetBounds(520, 456, 85, 25)
    $topologyLabel.SetBounds(620, 460, 112, 22); $topologyBox.SetBounds(735, 456, 92, 25)
    $cpuHintLabel.SetBounds(20, 486, 585, 22)
    $copyBamBaiToIgvCheckBox.SetBounds(620, 484, 220, 24)
    $statusLabel.SetBounds(20, 509, 785, 23)
    $runButton.SetBounds(20, 536, 205, 36)
    $stopRunButton.SetBounds(235, 537, 125, 34)
    $openOutputButton.SetBounds(375, 537, 150, 34)
    $instructionsButton.SetBounds(535, 537, 130, 34)
    $resetRunButton.SetBounds(675, 537, 130, 34)

    $runProgressGroup.SetBounds(20, 578, 1115, 224)
    $currentStepLabel.SetBounds(15, 22, 950, 20)
    $runPercentLabel.SetBounds(1030, 22, 55, 20)
    $runProgressBar.SetBounds(17, 47, 1070, 19)
    $stepGrid.SetBounds(17, 76, 470, 164)
    $stepGrid.ColumnHeadersHeight = 24
    $stepGrid.RowTemplate.Height = 16
    $stepGrid.Font = New-Object System.Drawing.Font('Segoe UI', 8.25)
    foreach ($gridRow in $stepGrid.Rows) { $gridRow.Height = 16 }
    $runLogBox.SetBounds(500, 76, 587, 164)
    Layout-OpDetectRunProgress
}


# File/folder hover guidance. Hover directly over the input box, its label, or
# Browse button to see exactly what OpDetect expects.
Set-OpDetectInputHoverHelp @($referenceBox, $referenceLabel, $referenceButton) 'Reference FASTA' @'
Choose the bacterial reference genome used for these RNA-seq reads.
Accepted files: .fa, .fasta, or .fna.
Use the same genome assembly that the annotation describes. Do not provide a protein FASTA here.
'@
Set-OpDetectInputHoverHelp @($annotationBox, $annotationLabel, $annotationButton) 'Genome annotation' @'
Choose the annotation matching the selected reference genome.
Accepted files: .gff, .gff3, or .gtf.
Gene coordinates and contig names must correspond to the reference FASTA.
'@
Set-OpDetectInputHoverHelp @($outputBox, $outputLabel, $outputButton) 'Results folder' @'
Choose a writable Windows folder where the completed OpDetect result folder will be created.
This is a folder, not an input file. Avoid protected system directories.
'@
Set-OpDetectInputHoverHelp @($projectBox, $projectLabel) 'Project / condition name' @'
Enter a short project or biological-condition name used to label the OpDetect run and exported result folder.
The FASTA filename is used as a convenient starting value and can be edited.
'@
Set-OpDetectInputHoverHelp @($sampleGrid, $samplesLabel, $addPairedButton, $addSingleButton, $scanFolderButton) 'RNA-seq FASTQ inputs' @'
Add one row per independent biological RNA-seq library.
Paired-end: provide matching R1 and R2 FASTQ/FASTQ.GZ files.
Single-end: provide one FASTQ/FASTQ.GZ file; mate 2 is recorded as NA.
Scan folder can detect common R1/R2 naming patterns automatically.
'@

$refreshEnvironmentButton.Add_Click({
    Update-EnvironmentStatus
})

$repairEnvironmentButton.Add_Click({
    $installer = Join-Path (Split-Path -Parent $PSScriptRoot) "Troubleshooting\Install or Repair.bat"
    if (Test-Path $installer) {
        Start-Process -FilePath $installer
        $statusLabel.Text = "The Linux setup or repair process has started. Reopen OpDetect when it finishes."
        $form.Close()
    }
    else {
        Show-ErrorMessage "The Troubleshooting\Install or Repair.bat utility is missing from the extracted package."
    }
})

$referenceButton.Add_Click({
    $selected = Select-OneFile -Title "Choose the bacterial reference FASTA" -Filter "FASTA files (*.fa;*.fasta;*.fna)|*.fa;*.fasta;*.fna|All files (*.*)|*.*"
    if ($null -ne $selected) {
        $referenceBox.Text = $selected
        $projectBox.Text = Get-SafeProjectId $selected
        $statusLabel.Text = "Reference selected."
    }
})

$annotationButton.Add_Click({
    $selected = Select-OneFile -Title "Choose the matching GFF, GFF3, or GTF annotation" -Filter "Annotation files (*.gff3;*.gff;*.gtf)|*.gff3;*.gff;*.gtf|All files (*.*)|*.*"
    if ($null -ne $selected) {
        $annotationBox.Text = $selected
        $statusLabel.Text = "Annotation selected."
    }
})

$addPairedButton.Add_Click({
    try {
        if ($sampleTable.Rows.Count -ge 6) {
            Show-ErrorMessage "Six biological replicates are already listed."
            return
        }

        $r1 = Select-OneFile -Title "Choose mate 1 FASTQ file. The filename can be anything" -Filter "FASTQ files (*.fastq;*.fastq.gz;*.fq;*.fq.gz)|*.fastq;*.fastq.gz;*.fq;*.fq.gz|All files (*.*)|*.*"
        if ($null -eq $r1) { return }

        $r2 = Select-OneFile -Title "Choose mate 2 FASTQ file. The filename can be anything" -Filter "FASTQ files (*.fastq;*.fastq.gz;*.fq;*.fq.gz)|*.fastq;*.fastq.gz;*.fq;*.fq.gz|All files (*.*)|*.*"
        if ($null -eq $r2) { return }

        if ($r1 -eq $r2) {
            throw "Mate 1 and mate 2 must be different files."
        }

        Assert-ValidPairedSelection -R1 ([ref]$r1) -R2 ([ref]$r2)

        $sample = Get-SampleNameFromReadFile $r1
        if (Add-SampleRow -Table $sampleTable -Sample $sample -R1 $r1 -R2 $r2) {
            $statusLabel.Text = "Paired-end replicate added. The first selected file is mate 1 and the second is mate 2; filenames were not interpreted."
        }
    }
    catch {
        Write-StartupLog ("ADD PAIRED-END ERROR: " + $_.Exception.ToString())
        Show-ErrorMessage $_.Exception.Message
    }
})

$addSingleButton.Add_Click({
    try {
        # PowerShell unwraps a one-item function result into a scalar string.
        # Wrapping with @() guarantees an array for zero, one, or many files.
        $files = @(Select-MultipleFiles -Title "Choose one or more single-end FASTQ files. Filenames can use any convention." -Filter "FASTQ files (*.fastq;*.fastq.gz;*.fq;*.fq.gz)|*.fastq;*.fastq.gz;*.fq;*.fq.gz|All files (*.*)|*.*")
        if ($files.Count -eq 0) { return }

        # The explicit Single-end action defines the layout. Filename tokens are not used to override the user.

        foreach ($file in $files) {
            if ($sampleTable.Rows.Count -ge 6) {
                Show-ErrorMessage "Only the first files were added because OpDetect accepts at most six biological replicates."
                break
            }
            $sample = Get-SampleNameFromReadFile ([string]$file)
            [void](Add-SampleRow -Table $sampleTable -Sample $sample -R1 ([string]$file) -R2 "NA")
        }

        $statusLabel.Text = "Single-end biological replicate file(s) added. Filename patterns were not interpreted."
    }
    catch {
        Write-StartupLog ("ADD SINGLE-END ERROR: " + $_.Exception.ToString())
        Show-ErrorMessage ("The single-end FASTQ file could not be added.`n`n" + $_.Exception.Message)
    }
})

$scanFolderButton.Add_Click({
    $folder = Select-OneFolder -Description "Choose a folder containing FASTQ files. Automatic folder import uses common R1/R2 or _1/_2 patterns; use Add paired-end for arbitrary names."
    if ($null -eq $folder) { return }

    $files = @(Get-ChildItem -LiteralPath $folder -File | Where-Object {
        $_.Name -match '(?i)\.(fastq|fq)(\.gz)?$'
    } | Sort-Object Name)

    if ($files.Count -eq 0) {
        Show-ErrorMessage "No FASTQ or FASTQ.GZ files were found in that folder."
        return
    }

    $descriptors = @($files | ForEach-Object { Get-PairDescriptor $_ })
    $pairedGroups = @($descriptors | Where-Object { $_.IsRead } | Group-Object Key)
    $added = 0
    $orphans = 0

    foreach ($group in $pairedGroups) {
        if ($sampleTable.Rows.Count -ge 6) { break }
        $r1 = @($group.Group | Where-Object { $_.Read -eq 1 })
        $r2 = @($group.Group | Where-Object { $_.Read -eq 2 })
        if ($r1.Count -eq 1 -and $r2.Count -eq 1) {
            if (Add-SampleRow -Table $sampleTable -Sample $r1[0].Sample -R1 $r1[0].Path -R2 $r2[0].Path) {
                $added++
            }
        }
        else {
            $orphans += $group.Count
        }
    }

    foreach ($single in @($descriptors | Where-Object { -not $_.IsRead })) {
        if ($sampleTable.Rows.Count -ge 6) { break }
        if (Add-SampleRow -Table $sampleTable -Sample $single.Sample -R1 $single.Path -R2 "NA") {
            $added++
        }
    }

    $message = "$added biological replicate(s) were added from the folder."
    if ($orphans -gt 0) {
        $message += " $orphans file(s) with incomplete or ambiguous automatic filename pairing were skipped. Use Add paired-end to pair arbitrary filenames explicitly."
    }
    if ($sampleTable.Rows.Count -ge 6 -and $files.Count -gt $added) {
        $message += " The six-replicate OpDetect limit was reached."
    }
    Show-InfoMessage $message
    $statusLabel.Text = "FASTQ folder scan complete. Review the sample table before running."
})

$removeButton.Add_Click({
    $indexes = @($sampleGrid.SelectedRows | ForEach-Object { $_.Index } | Sort-Object -Descending)
    foreach ($index in $indexes) {
        if ($index -ge 0 -and $index -lt $sampleTable.Rows.Count) {
            $sampleTable.Rows.RemoveAt($index)
        }
    }
    $statusLabel.Text = "Selected replicate rows removed."
})

$clearButton.Add_Click({
    $sampleTable.Rows.Clear()
    $statusLabel.Text = "Replicate list cleared."
})

$outputButton.Add_Click({
    $selected = Select-OneFolder -Description "Choose the Windows folder where final OpDetect results should be saved"
    if ($null -ne $selected) {
        $outputBox.Text = $selected
        $statusLabel.Text = "Results location selected."
    }
})

$openOutputButton.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $outputBox.Text)) {
            [void](New-Item -ItemType Directory -Force -Path $outputBox.Text)
        }
        Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $outputBox.Text)
    }
    catch {
        Show-ErrorMessage $_.Exception.Message
    }
})

$instructionsButton.Add_Click({
    try {
        $instructionsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Instructions.html'
        if (-not (Test-Path -LiteralPath $instructionsPath -PathType Leaf)) {
            throw "Instructions.html was not found beside OpDetect.exe. Keep the complete extracted package together."
        }
        Start-Process -FilePath $instructionsPath
    }
    catch {
        Show-ErrorMessage $_.Exception.Message
    }
})

$returnToSuiteButton.Add_Click({
    Return-ToPredictionSuite
})
$returnToAnalysisButton.Add_Click({ Return-ToAnalysisModules })

$resetRunButton.Add_Click({
    Reset-ForNewRun
})

$stopRunButton.Add_Click({
    if (-not $script:RunState -or $script:RunState.Finished -or $script:RunState.StopRequested) {
        return
    }
    if ($script:RunState.CompletionMarkerSeen -or $runProgressBar.Value -ge 100) {
        [void](Complete-RunAfterVerifiedExport -ProjectId ([string]$script:RunState.ProjectId))
        return
    }

    $script:RunState.StopRequested = $true
    $script:RunState.StopRequestedAt = Get-Date
    $stopRunButton.Enabled = $false
    $currentStepLabel.Text = 'Stopping the active OpDetect run...'
    $statusLabel.Text = 'Stop requested. Finishing the current shutdown operation...'
    $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
    $runLogBox.AppendText("Stop requested by the user.`r`n")
    $runLogBox.SelectionStart = $runLogBox.TextLength
    $runLogBox.ScrollToCaret()

    try {
        $stopArguments = @(
            '-d', $script:ManagedDistro,
            '-u', 'root',
            '--', '/bin/bash', '/root/opdetect_pipeline/stop_run.sh', [string]$script:RunState.GuiRunDir
        )
        [void](Start-Process -FilePath 'wsl.exe' -ArgumentList $stopArguments -WindowStyle Hidden -PassThru)
    }
    catch {
        $runLogBox.AppendText("Could not send the Linux stop command: $($_.Exception.Message)`r`n")
        try { $script:RunState.Process.Kill() } catch { }
    }
})

$runButton.Add_Click({
    try {
        $statusLabel.Text = "Checking inputs..."
        $form.Refresh()

        Update-EnvironmentStatus
        if (-not $script:EnvironmentReady) {
            throw "Linux or one or more required packages are not ready.`n`nUse the Install or repair button in the status panel, then run the Readiness check."
        }

        if ([string]::IsNullOrWhiteSpace($referenceBox.Text) -or -not (Test-Path -LiteralPath $referenceBox.Text -PathType Leaf)) {
            throw "Choose a valid reference FASTA file."
        }
        if ([string]::IsNullOrWhiteSpace($annotationBox.Text) -or -not (Test-Path -LiteralPath $annotationBox.Text -PathType Leaf)) {
            throw "Choose a valid GFF, GFF3, or GTF annotation file."
        }
        if ($sampleTable.Rows.Count -lt 1 -or $sampleTable.Rows.Count -gt 6) {
            throw "Add between one and six biological RNA-seq replicates."
        }
        if ([string]::IsNullOrWhiteSpace($projectBox.Text)) {
            throw "Enter a project name."
        }
        if ([string]::IsNullOrWhiteSpace($outputBox.Text)) {
            throw "Choose a results folder."
        }

        foreach ($row in $sampleTable.Rows) {
            $r1 = [string]$row['Read 1 / single-end FASTQ']
            $r2 = [string]$row['Read 2 FASTQ (NA for single-end)']
            if (-not (Test-Path -LiteralPath $r1 -PathType Leaf)) {
                throw "FASTQ file not found: $r1"
            }
            if ($r2 -ne "NA" -and -not (Test-Path -LiteralPath $r2 -PathType Leaf)) {
                throw "FASTQ file not found: $r2"
            }
        }

        if (-not (Test-Path -LiteralPath $outputBox.Text)) {
            [void](New-Item -ItemType Directory -Force -Path $outputBox.Text)
        }

        if ($sampleTable.Rows.Count -eq 1) {
            $runLogBox.AppendText("WARNING: One biological replicate was supplied. Replicate agreement cannot be assessed.`r`n")
        }
        else {
            $runLogBox.AppendText("Replicate-aware consensus enabled for $($sampleTable.Rows.Count) separate biological replicates.`r`n")
        }

        $statusLabel.Text = "Synchronizing the current pipeline version with Linux..."
        $form.Refresh()
        $packageRootWsl = Convert-WindowsPathToWsl $PSScriptRoot
        $syncScriptWsl = ($packageRootWsl.TrimEnd('/')) + "/sync_runtime.sh"
        $syncCommand = "bash $(Convert-ToBashSingleQuoted $syncScriptWsl) $(Convert-ToBashSingleQuoted $packageRootWsl) '/root/opdetect_pipeline'"
        & wsl.exe -d $script:ManagedDistro -u root -- bash -lc $syncCommand
        if ($LASTEXITCODE -ne 0) {
            throw "Could not synchronize the current OpDetect pipeline scripts into Linux."
        }

        $statusLabel.Text = "Converting selected Windows paths for WSL..."
        $form.Refresh()

        $referenceWsl = Convert-WindowsPathToWsl $referenceBox.Text
        $annotationWsl = Convert-WindowsPathToWsl $annotationBox.Text
        $outputParentWsl = Convert-WindowsPathToWsl $outputBox.Text

        $sampleRecords = @()
        foreach ($row in $sampleTable.Rows) {
            $r1Windows = [string]$row['Read 1 / single-end FASTQ']
            $r2Windows = [string]$row['Read 2 FASTQ (NA for single-end)']
            $r1Wsl = Convert-WindowsPathToWsl $r1Windows
            $r2Wsl = if ($r2Windows -eq "NA") { "NA" } else { Convert-WindowsPathToWsl $r2Windows }
            $sampleRecords += [pscustomobject]@{
                Sample = [string]$row['Sample']
                R1 = $r1Wsl
                R2 = $r2Wsl
            }
        }

        $projectId = Get-SafeProjectName $projectBox.Text
        $projectDisplayName = Get-DisplayFileStem -Value $projectId
        $runId = Get-Date -Format "yyyyMMdd_HHmmss"
        $guiRunDir = "$PipelineRoot/gui_runs/$runId"
        $internalOut = "/root/opdetect_runs/$projectId-$runId"
        $exportName = "$projectId-$runId"
        $exportDirWsl = ($outputParentWsl.TrimEnd('/')) + "/" + $exportName

        $tempRoot = Join-Path $env:TEMP "OpDetectGUI"
        [void](New-Item -ItemType Directory -Force -Path $tempRoot)
        $localRunDir = Join-Path $tempRoot $runId
        [void](New-Item -ItemType Directory -Force -Path $localRunDir)
        $progressPath = Join-Path $localRunDir 'progress.tsv'
        $liveLogPath = Join-Path $localRunDir 'live_run.log'
        $stepTimingPath = Join-Path $localRunDir 'step-timings.tsv'
        Write-Utf8NoBom -Path $progressPath -Text ''
        Write-Utf8NoBom -Path $liveLogPath -Text ''
        Write-Utf8NoBom -Path $stepTimingPath -Text ''
        $windowsMachineInfoPath = Join-Path $localRunDir 'windows_machine_info.txt'
        $windowsMachineInfoText = Get-WindowsMachineReport -DistroName $script:ManagedDistro
        Write-Utf8NoBom -Path $windowsMachineInfoPath -Text $windowsMachineInfoText
        $progressPathWsl = Convert-WindowsPathToWsl $progressPath
        $liveLogPathWsl = Convert-WindowsPathToWsl $liveLogPath
        $stepTimingPathWsl = Convert-WindowsPathToWsl $stepTimingPath

        $thresholdInvariant = Format-DecimalInvariant ([decimal]$thresholdBox.Value)
        $samplesTsvWsl = "$guiRunDir/samples.tsv"
        $annotationFeature = [string]$featureBox.SelectedItem
        $topologyMode = switch ([string]$topologyBox.SelectedItem) {
            'Circular' { 'circular' }
            'Linear' { 'linear' }
            default { 'auto' }
        }
        $copyBamBaiToIgv = [bool]$copyBamBaiToIgvCheckBox.Checked
        $copyBamBaiValue = if ($copyBamBaiToIgv) { '1' } else { '0' }
        $configLines = @(
            "PROJECT_ID=$(Convert-ToBashSingleQuoted $projectId)",
            "REFERENCE_FA=$(Convert-ToBashSingleQuoted $referenceWsl)",
            "ANNOTATION_GFF=$(Convert-ToBashSingleQuoted $annotationWsl)",
            "SAMPLES_TSV=$(Convert-ToBashSingleQuoted $samplesTsvWsl)",
            "OUTDIR=$(Convert-ToBashSingleQuoted $internalOut)",
            "OPDETECT_REPO='/root/tools/OpDetect'",
            "THREADS=$([int]$threadsBox.Value)",
            "ANNOTATION_FEATURE=$(Convert-ToBashSingleQuoted $annotationFeature)",
            "HISAT2_EXTRA='--no-spliced-alignment'",
            "PREDICTION_THRESHOLD=$thresholdInvariant",
            "MIN_REPLICATE_SUPPORT=0.60",
            "REPLICON_TOPOLOGY=$(Convert-ToBashSingleQuoted $topologyMode)",
            "COPY_BAM_BAI_TO_IGV=$copyBamBaiValue"
        )
        $configText = ($configLines -join "`n") + "`n"

        $sampleLines = @()
        $sampleLines += ("replicate`tr1`tr2")
        foreach ($record in $sampleRecords) {
            $sampleLines += ("$($record.Sample)`t$($record.R1)`t$($record.R2)")
        }
        $samplesText = ($sampleLines -join "`n") + "`n"

        $launchText = @"
#!/usr/bin/env bash
set -Eeuo pipefail
RUN_DIR=$(Convert-ToBashSingleQuoted $guiRunDir)
INTERNAL_OUT=$(Convert-ToBashSingleQuoted $internalOut)
EXPORT_DIR=$(Convert-ToBashSingleQuoted $exportDirWsl)
DISPLAY_PROJECT=$(Convert-ToBashSingleQuoted $projectDisplayName)
REFERENCE_SOURCE=$(Convert-ToBashSingleQuoted $referenceWsl)
ANNOTATION_SOURCE=$(Convert-ToBashSingleQuoted $annotationWsl)
PROGRESS_FILE=$(Convert-ToBashSingleQuoted $progressPathWsl)
LIVE_LOG=$(Convert-ToBashSingleQuoted $liveLogPathWsl)
STEP_TIMING_FILE=$(Convert-ToBashSingleQuoted $stepTimingPathWsl)
COPY_BAM_BAI_TO_IGV=$copyBamBaiValue
RUN_STARTED_ISO=`$(date --iso-8601=seconds)
RUN_STARTED_EPOCH=`$(date +%s)
mkdir -p "`$RUN_DIR"
: > "`$PROGRESS_FILE"
: > "`$LIVE_LOG"
printf '%s\n' "`$`$" > "`$RUN_DIR/pipeline.pid"
export OPDETECT_PROGRESS_FILE="`$PROGRESS_FILE"
export OPDETECT_STEP_TIMING_FILE="`$STEP_TIMING_FILE"
export TF_CPP_MIN_LOG_LEVEL=3
export CUDA_VISIBLE_DEVICES=-1

log_line() {
  printf '%s\n' "`$*" | tee -a "`$LIVE_LOG"
}

gui_progress() {
  local step=`$1 percent=`$2 state=`$3 message=`$4
  local line
  printf -v line 'OPDETECT_PROGRESS\t%s\t%s\t%s\t%s' "`$step" "`$percent" "`$state" "`$message"
  printf '%s\n' "`$line"
  printf '%s\n' "`$line" >> "`$PROGRESS_FILE"
}

cleanup_pid() {
  rm -f "`$RUN_DIR/pipeline.pid"
}

stop_requested() {
  trap - ERR TERM INT
  log_line ""
  log_line "OpDetect stop requested by the user."
  cleanup_pid
  exit 130
}

trap stop_requested TERM INT
trap cleanup_pid EXIT

emit_gui_source() {
  local language=`$1 path=`$2
  log_line ""
  log_line "================================================================================================"
  log_line "`$language CODE TRACE - EXACT SOURCE USED FOR THIS RUN"
  log_line "FILE: `$path"
  log_line "================================================================================================"
  nl -ba -w5 -s' | ' "`$path" | tee -a "`$LIVE_LOG"
  log_line "END `$language CODE TRACE"
}

log_line "Code retention: live console and persistent live_run.log only."
log_line "No duplicate source-code folder is created."
log_line "The generated orchestration code is printed below before execution."
emit_gui_source "SHELL" "`$RUN_DIR/launch_run.sh"
emit_gui_source "ENV CONFIGURATION" "`$RUN_DIR/config.env"
emit_gui_source "TSV SAMPLE SHEET" "`$RUN_DIR/samples.tsv"

CONDA_ROOT=""
for candidate in /root/.local/share/prok-rnaseq/miniforge3 /root/miniforge3 /opt/conda /opt/miniforge3 /home/*/.local/share/prok-rnaseq/miniforge3 /home/*/miniforge3; do
  if [[ -x "`$candidate/bin/conda" && -r "`$candidate/etc/profile.d/conda.sh" ]]; then CONDA_ROOT="`$candidate"; break; fi
done
if [[ -z "`$CONDA_ROOT" ]]; then log_line "ERROR: Could not locate Miniforge/Conda for OpDetect."; exit 10; fi
source "`$CONDA_ROOT/etc/profile.d/conda.sh"
OPDETECT_ENV="`$CONDA_ROOT/envs/opdetect-pipeline"
if [[ ! -x "`$OPDETECT_ENV/bin/python" ]]; then
  OPDETECT_ENV=`$(conda env list 2>/dev/null | awk 'NF && `$1 !~ /^#/ && `$NF ~ /\/opdetect-pipeline\/?`$/ {print `$NF; exit}')
fi
if [[ -z "`$OPDETECT_ENV" || ! -x "`$OPDETECT_ENV/bin/python" ]]; then log_line "ERROR: Could not locate the opdetect-pipeline environment."; exit 12; fi
conda activate "`$OPDETECT_ENV"
cd /root/opdetect_pipeline

set +e
bash run_opdetect_pipeline.sh "`$RUN_DIR/config.env" 2>&1 | tee -a "`$LIVE_LOG"
pipeline_code=`${PIPESTATUS[0]}
set -e
if (( pipeline_code != 0 )); then
  log_line ""
  log_line "OpDetect stopped with exit code `$pipeline_code. Review the error above."
  exit "`$pipeline_code"
fi

STEP10_STARTED_ISO=`$(date --iso-8601=seconds)
STEP10_STARTED_EPOCH=`$(date +%s)
gui_progress 10 98 start "Creating the simplified Excel, QC, and IGV result package"
RESULT_SOURCE="`$INTERNAL_OUT/results"
LOG_SOURCE="`$INTERNAL_OUT/logs"
BAM_SOURCE="`$INTERNAL_OUT/work/bam"
IGV_EXPORT="`$EXPORT_DIR/IGV"
rm -rf "`$EXPORT_DIR"
mkdir -p "`$EXPORT_DIR" "`$IGV_EXPORT"
SOURCE_PREDICTIONS="`$RESULT_SOURCE/$projectId.gene-pair-predictions.csv"
SOURCE_OPERONS="`$RESULT_SOURCE/$projectId.predicted-operons.tsv"
SOURCE_OPERON_BEDGRAPH="`$RESULT_SOURCE/$projectId.predicted-operons.bedgraph"
INTERNAL_PREDICTIONS_XLSX="`$RESULT_SOURCE/$projectId.gene-pair-predictions.xlsx"
INTERNAL_OPERONS_XLSX="`$RESULT_SOURCE/$projectId.predicted-operons.xlsx"
PEARSON_TSV="`$RESULT_SOURCE/qc/replicate-pearson.tsv"
SPEARMAN_TSV="`$RESULT_SOURCE/qc/replicate-spearman.tsv"
INTERNAL_CORRELATIONS_XLSX="`$RESULT_SOURCE/replicate-correlations.xlsx"
EXPORTED_CORRELATIONS="`$EXPORT_DIR/Replicate correlations.xlsx"
EXPORTED_PREDICTIONS="`$EXPORT_DIR/`$DISPLAY_PROJECT gene pair predictions.xlsx"
EXPORTED_OPERONS="`$EXPORT_DIR/`$DISPLAY_PROJECT predicted operons.xlsx"
EXPORTED_OPERON_BEDGRAPH="`$IGV_EXPORT/`$DISPLAY_PROJECT predicted operons.bedgraph"

[[ -s "`$SOURCE_PREDICTIONS" ]] || { log_line "ERROR: Prediction table is missing or empty: `$SOURCE_PREDICTIONS"; exit 1; }
[[ -s "`$SOURCE_OPERONS" ]] || { log_line "ERROR: Predicted-operon table is missing or empty: `$SOURCE_OPERONS"; exit 1; }
[[ -s "`$SOURCE_OPERON_BEDGRAPH" ]] || { log_line "ERROR: Predicted-operon bedGraph is missing or empty: `$SOURCE_OPERON_BEDGRAPH"; exit 1; }
[[ -s "`$REFERENCE_SOURCE" ]] || { log_line "ERROR: Reference FASTA is missing: `$REFERENCE_SOURCE"; exit 1; }
[[ -s "`$ANNOTATION_SOURCE" ]] || { log_line "ERROR: Annotation file is missing: `$ANNOTATION_SOURCE"; exit 1; }

python /root/opdetect_pipeline/scripts/table_to_xlsx.py \
  --input "`$SOURCE_PREDICTIONS" --delimiter comma \
  --sheet-name "Gene pair predictions" --output "`$INTERNAL_PREDICTIONS_XLSX"
python /root/opdetect_pipeline/scripts/table_to_xlsx.py \
  --input "`$SOURCE_OPERONS" --delimiter tab \
  --sheet-name "Predicted operons" \
  --drop-columns "chromosome,topology,wraps_origin" \
  --output "`$INTERNAL_OPERONS_XLSX"
if [[ -s "`$PEARSON_TSV" && -s "`$SPEARMAN_TSV" ]]; then
  python /root/opdetect_pipeline/scripts/correlations_to_xlsx.py \
    --pearson "`$PEARSON_TSV" --spearman "`$SPEARMAN_TSV" \
    --output "`$INTERNAL_CORRELATIONS_XLSX"
  cp -f "`$INTERNAL_CORRELATIONS_XLSX" "`$EXPORTED_CORRELATIONS"
  log_line "Replicate correlations exported to: `$EXPORTED_CORRELATIONS"
else
  log_line "Replicate correlation workbook was not created because fewer than two biological replicates were available."
fi
cp -f "`$INTERNAL_PREDICTIONS_XLSX" "`$EXPORTED_PREDICTIONS"
cp -f "`$INTERNAL_OPERONS_XLSX" "`$EXPORTED_OPERONS"
cp -f "`$SOURCE_OPERON_BEDGRAPH" "`$EXPORTED_OPERON_BEDGRAPH"
cp -f "`$REFERENCE_SOURCE" "`$IGV_EXPORT/`$(basename "`$REFERENCE_SOURCE")"
cp -f "`$ANNOTATION_SOURCE" "`$IGV_EXPORT/`$(basename "`$ANNOTATION_SOURCE")"

clean_display_stem() {
  printf '%s' "`$1" | sed -E 's/[._-]+/ /g; s/[^A-Za-z0-9 ()]+/ /g; s/[[:space:]]+/ /g; s/^ //; s/ `$//'
}

while IFS=`$'\t' read -r sample r1 r2; do
  [[ "`$sample" == "replicate" || -z "`$sample" ]] && continue
  display_sample=`$(clean_display_stem "`$sample")
  [[ -n "`$display_sample" ]] || display_sample="sample"
  fastp_source="`$LOG_SOURCE/`$sample.fastp.html"
  bam_source="`$BAM_SOURCE/`$sample.sorted.bam"
  bai_source="`$bam_source.bai"
  [[ -s "`$fastp_source" ]] || { log_line "ERROR: fastp HTML report is missing for `$sample: `$fastp_source"; exit 1; }
  [[ -s "`$bam_source" ]] || { log_line "ERROR: Sorted BAM is missing for `$sample: `$bam_source"; exit 1; }
  [[ -s "`$bai_source" ]] || { log_line "ERROR: BAM index is missing for `$sample: `$bai_source"; exit 1; }
  cp -f "`$fastp_source" "`$EXPORT_DIR/`$display_sample fastp.html"
  if [[ "`$COPY_BAM_BAI_TO_IGV" == "1" ]]; then
    cp -f "`$bam_source" "`$IGV_EXPORT/`$display_sample.bam"
    cp -f "`$bai_source" "`$IGV_EXPORT/`$display_sample.bam.bai"
  fi
done < "`$RUN_DIR/samples.tsv"

if [[ "`$COPY_BAM_BAI_TO_IGV" == "1" ]]; then
  log_line "BAM/BAI copies were added to the IGV folder."
else
  log_line "BAM/BAI copy to the IGV folder was not requested."
fi

[[ -s "`$EXPORTED_PREDICTIONS" ]] || { log_line "ERROR: Excel prediction workbook could not be exported."; exit 1; }
[[ -s "`$EXPORTED_OPERONS" ]] || { log_line "ERROR: Excel predicted-operon workbook could not be exported."; exit 1; }
[[ -s "`$EXPORTED_OPERON_BEDGRAPH" ]] || { log_line "ERROR: IGV predicted-operon bedGraph could not be exported."; exit 1; }
[[ -s "`$IGV_EXPORT/`$(basename "`$REFERENCE_SOURCE")" ]] || { log_line "ERROR: Reference FASTA could not be copied to IGV."; exit 1; }
[[ -s "`$IGV_EXPORT/`$(basename "`$ANNOTATION_SOURCE")" ]] || { log_line "ERROR: Annotation could not be copied to IGV."; exit 1; }

RUN_FINISHED_ISO=`$(date --iso-8601=seconds)
RUN_FINISHED_EPOCH=`$(date +%s)
RUN_DURATION_SECONDS=`$((RUN_FINISHED_EPOCH - RUN_STARTED_EPOCH))
RUN_LOG_INTERNAL="`$RUN_DIR/opdetect-run-report.txt"

log_line ""
log_line "Verified simplified Windows result package:"
find "`$EXPORT_DIR" -type f -printf '%P\t%s bytes\n' | sort | tee -a "`$LIVE_LOG"
log_line "Final results copied to: `$EXPORT_DIR"
STEP10_FINISHED_ISO=`$(date --iso-8601=seconds)
STEP10_FINISHED_EPOCH=`$(date +%s)
STEP10_DURATION=`$((STEP10_FINISHED_EPOCH - STEP10_STARTED_EPOCH))
printf '10\tExport simplified Windows results\t%s\t%s\t%s\tdone\n' \
  "`$STEP10_STARTED_ISO" "`$STEP10_FINISHED_ISO" "`$STEP10_DURATION" >> "`$STEP_TIMING_FILE"

{
  cat <<REPORT_HEADER
OpDetect RNA-seq Pipeline Run Log
=================================
Run status: SUCCESS
Project: $projectId
Run ID: $runId
Started: `$RUN_STARTED_ISO
Finished: `$RUN_FINISHED_ISO
Elapsed seconds: `$RUN_DURATION_SECONDS
Internal WSL working directory: $internalOut
Windows export directory (WSL path): `$EXPORT_DIR

[WINDOWS MACHINE]
REPORT_HEADER

  if [[ -s "`$RUN_DIR/windows_machine_info.txt" ]]; then
    cat "`$RUN_DIR/windows_machine_info.txt"
  else
    echo "Windows machine information was unavailable."
  fi

  cat <<REPORT_LINUX

[WSL / LINUX MACHINE]
WSL distribution: `$WSL_DISTRO_NAME
Linux kernel: `$(uname -a)
Architecture: `$(uname -m)
REPORT_LINUX
  if [[ -r /etc/os-release ]]; then
    grep -E '^(PRETTY_NAME|VERSION_ID|ID)=' /etc/os-release || true
  fi
  echo "CPU summary:"
  lscpu 2>/dev/null | grep -E '^(Architecture|CPU\(s\)|Model name|Socket\(s\)|Core\(s\) per socket|Thread\(s\) per core):' || true
  echo "Memory available to WSL:"
  free -h 2>/dev/null || true
  echo "Disk usage for working and export locations:"
  df -h "`$INTERNAL_OUT" "`$EXPORT_DIR" 2>/dev/null || true

  cat <<REPORT_SOFTWARE

[SOFTWARE VERSIONS]
REPORT_SOFTWARE
  echo "Exact executable paths and SHA-256 hashes:"
  for tool in git fastp hisat2 samtools bedtools python; do
    resolved="`$(command -v "`$tool" 2>/dev/null || true)"
    if [[ -n "`$resolved" && -f "`$resolved" ]]; then
      printf '%s\tpath=%s\tsha256=' "`$tool" "`$resolved"
      sha256sum "`$resolved" | awk '{print `$1}'
    else
      printf '%s\tunavailable\n' "`$tool"
    fi
  done
  git --version 2>&1 || true
  fastp --version 2>&1 | head -n 1 || true
  hisat2 --version 2>&1 | head -n 1 || true
  samtools --version 2>&1 | head -n 1 || true
  bedtools --version 2>&1 | head -n 1 || true
  TF_CPP_MIN_LOG_LEVEL=3 python - <<'PYVERSIONS' 2>&1 || true
import platform
print('Python', platform.python_version())
for name in ['numpy', 'pandas', 'scipy', 'sklearn', 'tensorflow', 'keras']:
    try:
        module = __import__(name)
        print(name, getattr(module, '__version__', 'unknown'))
    except Exception as exc:
        print(name, 'unavailable:', exc)
PYVERSIONS
  echo "Python package provenance:"
  python - <<'PYPACKAGES' 2>&1 || true
import importlib.metadata
for dist in sorted(importlib.metadata.distributions(), key=lambda d: (d.metadata.get('Name') or '').casefold()):
    m = dist.metadata
    print('\t'.join(['PYTHON PACKAGE', m.get('Name') or dist.name, 'version=' + dist.version,
        'license=' + (m.get('License') or '').replace('\n', ' '),
        'home=' + (m.get('Home-page') or ''),
        'project_urls=' + '; '.join(m.get_all('Project-URL') or [])]))
PYPACKAGES
  echo "Conda package provenance:"
  conda list --explicit 2>&1 || true
  if [[ -n "`$CONDA_PREFIX" && -d "`$CONDA_PREFIX/conda-meta" ]]; then
    python - "`$CONDA_PREFIX/conda-meta" <<'PYCONDAPROVENANCE' 2>&1 || true
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
fields = (
    'package', 'version', 'build', 'build_number', 'subdir', 'channel',
    'license', 'license_family', 'package_url', 'package_sha256', 'package_md5',
    'requested_spec', 'dependencies', 'upstream_urls', 'metadata_file',
    'metadata_sha256', 'metadata_status',
)

def clean(value):
    if value is None:
        return ''
    if isinstance(value, (list, tuple)):
        value = '; '.join(str(item) for item in value)
    elif isinstance(value, dict):
        value = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':'))
    return ' '.join(str(value).replace('\t', ' ').splitlines()).strip()

print('CONDA PACKAGE FIELDS\t' + '\t'.join(fields))
count = 0
for path in sorted(root.glob('*.json')):
    raw = path.read_bytes()
    metadata_sha256 = hashlib.sha256(raw).hexdigest()
    try:
        payload = json.loads(raw.decode('utf-8', errors='replace'))
        repodata = payload.get('repodata_record')
        if not isinstance(repodata, dict):
            repodata = {}
        channel = payload.get('channel', repodata.get('channel', ''))
        if isinstance(channel, dict):
            channel = channel.get('canonical_name') or channel.get('name') or channel.get('url') or channel
        urls = [payload.get(key) for key in ('source_url', 'dev_url', 'doc_url', 'home', 'homepage')]
        record = {
            'package': clean(payload.get('name') or repodata.get('name') or path.stem),
            'version': clean(payload.get('version') or repodata.get('version')),
            'build': clean(payload.get('build') or repodata.get('build')),
            'build_number': clean(payload.get('build_number', repodata.get('build_number', ''))),
            'subdir': clean(payload.get('subdir') or repodata.get('subdir')),
            'channel': clean(channel),
            'license': clean(payload.get('license') or repodata.get('license')),
            'license_family': clean(payload.get('license_family') or repodata.get('license_family')),
            'package_url': clean(payload.get('url') or repodata.get('url')),
            'package_sha256': clean(payload.get('sha256') or repodata.get('sha256')),
            'package_md5': clean(payload.get('md5') or repodata.get('md5')),
            'requested_spec': clean(payload.get('requested_spec')),
            'dependencies': clean(payload.get('depends') or repodata.get('depends') or []),
            'upstream_urls': '; '.join(dict.fromkeys(clean(item) for item in urls if item)),
            'metadata_file': path.name,
            'metadata_sha256': metadata_sha256,
            'metadata_status': 'ok',
        }
    except Exception as exc:
        record = {field: '' for field in fields}
        record.update({
            'package': path.stem,
            'metadata_file': path.name,
            'metadata_sha256': metadata_sha256,
            'metadata_status': clean(f'unreadable: {exc}'),
        })
    print('CONDA PACKAGE\t' + '\t'.join(record[field] for field in fields))
    count += 1
print(f'CONDA PACKAGE COUNT\t{count}')
print('Conda files and paths_data.paths inventories were omitted because they are installation manifests, not executable source or generated analysis code; metadata_sha256 fingerprints each complete original record.')
PYCONDAPROVENANCE
  fi
  if [[ -d /root/tools/OpDetect/.git ]]; then
    printf 'OpDetect Git commit: '
    git -C /root/tools/OpDetect rev-parse HEAD 2>/dev/null || true
  fi

  cat <<REPORT_SETTINGS

[INPUTS AND SETTINGS]
Reference FASTA: $referenceWsl
Annotation GFF/GFF3/GTF: $annotationWsl
Annotation feature: $annotationFeature
CPU threads requested: $([int]$threadsBox.Value)
Prediction threshold: $thresholdInvariant
Real biological replicate count: $($sampleTable.Rows.Count)
Replicate consensus minimum support: 0.60
Replicon topology mode: $topologyMode
Copy BAM and BAI to IGV folder: $copyBamBaiToIgv

Sample sheet:
REPORT_SETTINGS
  cat "`$RUN_DIR/samples.tsv"

  cat <<REPORT_QC

[FASTP, REPLICATE, AND ALIGNMENT QC]
REPORT_QC
  if [[ -s "`$INTERNAL_OUT/logs/replicate_qc.log" ]]; then
    cat "`$INTERNAL_OUT/logs/replicate_qc.log"
  fi
  if [[ -s "`$INTERNAL_OUT/results/qc/sample-qc.tsv" ]]; then
    echo ""
    cat "`$INTERNAL_OUT/results/qc/sample-qc.tsv"
  fi
  if [[ -s "`$PEARSON_TSV" && -s "`$SPEARMAN_TSV" ]]; then
    echo ""
    echo "Pearson replicate correlation matrix:"
    cat "`$PEARSON_TSV"
    echo ""
    echo "Spearman replicate correlation matrix:"
    cat "`$SPEARMAN_TSV"
  fi

  cat <<REPORT_TRACK

[IGV PREDICTED-OPERON BEDGRAPH]
The fourth bedGraph column is the signed mean OpDetect model probability.
Positive values indicate forward-strand operons; negative values indicate reverse-strand operons.
The magnitude ranges from 0 to 1. This value is not a statistical p-value and is not a guaranteed probability that the biological prediction is correct.
REPORT_TRACK

  cat <<REPORT_TIMING

[STEP TIMINGS]
REPORT_TIMING
  cat "`$STEP_TIMING_FILE" 2>/dev/null || true

  cat <<REPORT_RESULTS

[EXPORTED RESULT FILES]
REPORT_RESULTS
  find "`$EXPORT_DIR" -type f -printf '%P\t%s bytes\n' | sort || true
  echo "SHA-256 checksums:"
  find "`$EXPORT_DIR" -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null || true

  cat <<REPORT_PROGRESS

[STEP PROGRESS RECORD]
REPORT_PROGRESS
  cat "`$PROGRESS_FILE" 2>/dev/null || true

  cat <<REPORT_CONSOLE

[COMPLETE CONSOLE OUTPUT]
REPORT_CONSOLE
  grep -v '^OPDETECT_PROGRESS' "`$LIVE_LOG" 2>/dev/null || true
} > "`$RUN_LOG_INTERNAL"

RUN_REPORT_INTERNAL="`$RESULT_SOURCE/OpDetect Run Report.docx"
RUN_REPORT_DOCX="`$EXPORT_DIR/OpDetect Run Report.docx"
python /root/opdetect_pipeline/scripts/text_report_to_docx.py \
  --input "`$RUN_LOG_INTERNAL" --output "`$RUN_REPORT_INTERNAL" --title "OpDetect Run Report"
cp -f "`$RUN_REPORT_INTERNAL" "`$RUN_REPORT_DOCX"
[[ -s "`$RUN_REPORT_DOCX" ]] || { log_line "ERROR: Word run report could not be exported."; exit 1; }

if [[ "`$COPY_BAM_BAI_TO_IGV" == "1" ]]; then
  gui_progress 10 100 done "Excel, replicate correlations when available, top-level fastp QC, BAM/BAI, FASTA, annotation, IGV bedGraph, and Word report exported"
else
  gui_progress 10 100 done "Excel, replicate correlations when available, top-level fastp QC, FASTA, annotation, IGV bedGraph, and Word report exported; BAM/BAI copy was not requested"
fi
"@

        $configPath = Join-Path $localRunDir "config.env"
        $samplesPath = Join-Path $localRunDir "samples.tsv"
        $launchPath = Join-Path $localRunDir "launch_run.sh"
        Write-Utf8NoBom -Path $configPath -Text $configText
        Write-Utf8NoBom -Path $samplesPath -Text $samplesText
        Write-Utf8NoBom -Path $launchPath -Text $launchText

        $localRunDirWsl = Convert-WindowsPathToWsl $localRunDir
        $quotedGuiRunDir = Convert-ToBashSingleQuoted $guiRunDir
        $quotedLocalRunDir = Convert-ToBashSingleQuoted $localRunDirWsl
        $copyCommand = "set -Eeuo pipefail; mkdir -p $quotedGuiRunDir; cp $quotedLocalRunDir/config.env $quotedGuiRunDir/config.env; cp $quotedLocalRunDir/samples.tsv $quotedGuiRunDir/samples.tsv; cp $quotedLocalRunDir/windows_machine_info.txt $quotedGuiRunDir/windows_machine_info.txt; cp $quotedLocalRunDir/launch_run.sh $quotedGuiRunDir/launch_run.sh; sed -i 's/\r$//' $quotedGuiRunDir/launch_run.sh; chmod +x $quotedGuiRunDir/launch_run.sh"

        & wsl.exe -d $script:ManagedDistro -u root -- bash -lc $copyCommand
        if ($LASTEXITCODE -ne 0) {
            throw "Could not transfer the generated run files into the WSL2 Linux environment."
        }

        $expectedResultWindowsPath = Join-Path $outputBox.Text $exportName
        $runButton.Enabled = $false
        Start-OpDetectEmbeddedRun `
            -ProjectId $projectId `
            -SampleNames @($sampleRecords | ForEach-Object { [string]$_.Sample }) `
            -GuiRunDir $guiRunDir `
            -ExpectedResultWindowsPath $expectedResultWindowsPath `
            -InternalOut $internalOut `
            -RunId $runId `
            -ProgressFilePath $progressPath `
            -LiveLogPath $liveLogPath `
            -CopyBamBaiToIgv $copyBamBaiToIgv
    }
    catch {
        $statusLabel.Text = "The run was not started: $($_.Exception.Message)"
        $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
        $runLogBox.AppendText("ERROR: $($_.Exception.Message)`r`n")
        $runButton.Enabled = $script:EnvironmentReady
        $resetRunButton.Enabled = $true
    }
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:RunState -and -not $script:RunState.Finished) {
        $eventArgs.Cancel = $true
        $statusLabel.Text = 'OpDetect is still running. Use STOP RUN before closing this window.'
        $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
    }
})

$form.Add_FormClosed({
    if ($script:SuiteSignalTimer) {
        try { $script:SuiteSignalTimer.Dispose() } catch { }
    }
    Remove-SuiteApplicationArtifacts
})

$form.Add_Shown({
    Write-StartupLog "Main window shown"
    if (Test-Path -LiteralPath $EnvironmentVerifiedFile) {
        try {
            $cacheText = Get-Content -LiteralPath $EnvironmentVerifiedFile -Raw -ErrorAction Stop
            if ($cacheText -match '(?m)^distro=(.+)$') {
                $script:ManagedDistro = $Matches[1].Trim()
            }
        }
        catch { }
        $environmentSummaryLabel.Text = "A previous installation was found. Use Readiness check to verify the current model runtime."
        $environmentSummaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
        $statusLabel.Text = ""
        $runButton.Enabled = $false
    }
    else {
        $environmentSummaryLabel.Text = "Environment check has not run yet. Use Readiness check to verify, or select files and click Run."
        $environmentSummaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
        $statusLabel.Text = ""
    }

    # Force the first window onto the visible desktop. This also recovers from
    # Windows remembering an off-screen location after monitor changes.
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.ShowInTaskbar = $true
    $form.TopMost = $true
    $form.Activate()
    $form.BringToFront()

    $script:StartupUiTimer = New-Object System.Windows.Forms.Timer
    $script:StartupUiTimer.Interval = 900
    $script:StartupUiTimer.Add_Tick({
        $script:StartupUiTimer.Stop()
        $form.TopMost = $false
        $form.Activate()
        $form.BringToFront()
        Write-StartupLog "Startup foreground timer completed"
    })
    $script:StartupUiTimer.Start()
})

try {
    Apply-NeutralSelectionTheme $form
    if ($script:SuiteManaged) {
        Write-SuiteApplicationMarker -Hidden $false
        Start-SuiteSignalMonitor
    }
    if ($script:EmbeddedMode) {
        Write-StartupLog "Entering embedded host"
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
        Write-StartupLog "Embedded host returned normally"
    }
    else {
        Write-StartupLog "Entering ShowDialog"
        [void]$form.ShowDialog()
        Write-StartupLog "ShowDialog returned normally"
    }
}
catch {
    Write-StartupLog ("SHOWDIALOG ERROR: " + $_.Exception.ToString())
    Show-ErrorMessage ("The OpDetect window could not be displayed.`n`n" + $_.Exception.Message + "`n`nStartup log:`n" + $StartupLogPath)
}
finally {
    if ($script:StartupUiTimer) {
        try { $script:StartupUiTimer.Dispose() } catch { }
    }
    if ($script:SuiteSignalTimer) {
        try { $script:SuiteSignalTimer.Dispose() } catch { }
    }
}
