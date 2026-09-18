[CmdletBinding()]
param(
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PrivateDistro = "OpDetect-Ubuntu"
$BaseDistro = "Ubuntu-24.04"
$DistroPreferenceFile = Join-Path $PSScriptRoot ".opdetect_wsl_distro"
$SharedDistroPreferenceFile = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\Shared Analysis State\wsl_distro.txt'))
$CoreDistroPreferenceFile = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\..\App\environment\.wsl_distro'))
$EnvironmentVerifiedFile = Join-Path $PSScriptRoot ".environment_verified"

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Wait-ForEnter {
    param([string]$Message = "Press Enter to close")
    [void](Read-Host $Message)
}

function Confirm-Action {
    param([string]$Message)
    $answer = Read-Host "$Message [Y/N]"
    return $answer -match '(?i)^(y|yes)$'
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-AsAdministrator {
    Write-Host "Administrator permission is required for this Windows-level WSL change." -ForegroundColor Yellow
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $PSCommandPath),
        "-Elevated"
    )
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arguments
    exit 0
}

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

function Restart-WslHostService {
    if (-not (Test-Administrator)) { return $false }
    foreach ($serviceName in @('WslService', 'LxssManager')) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -eq $service) { continue }
            Write-Host "Resetting the Windows WSL host service ($serviceName)..." -ForegroundColor Yellow
            if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
                Restart-Service -Name $serviceName -Force -ErrorAction Stop
            }
            else {
                Start-Service -Name $serviceName -ErrorAction Stop
            }
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            try { $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(20)) } catch { }
            Start-Sleep -Milliseconds 3500
            return $true
        }
        catch {
            Write-Warning "Could not reset $serviceName`: $($_.Exception.Message)"
        }
    }
    return $false
}

function Repair-WslSessionForDistro {
    param(
        [Parameter(Mandatory = $true)][string]$Distro,
        [int]$Attempts = 3
    )

    if (Test-DistroRunnable $Distro) { return $true }
    Write-Warning "The registered WSL distribution '$Distro' did not answer. Repairing the WSL session automatically; Ubuntu will not be reinstalled."
    for ($attempt = 1; $attempt -le [Math]::Max(1, $Attempts); $attempt++) {
        Write-Host "WSL recovery attempt $attempt of $Attempts..." -ForegroundColor Yellow
        try { & wsl.exe --terminate $Distro *> $null } catch { }
        try { & wsl.exe --shutdown *> $null } catch { }
        if ($attempt -ge 2) { [void](Restart-WslHostService) }
        if ($attempt -eq $Attempts -and (Test-Administrator)) {
            Write-Host 'Checking for a WSL runtime update before the final retry...' -ForegroundColor Yellow
            try { & wsl.exe --update | Out-Host } catch { Write-Warning "The WSL update check could not complete: $($_.Exception.Message)" }
            try { & wsl.exe --shutdown *> $null } catch { }
        }
        try { & wsl.exe --status *> $null } catch { }
        for ($probe = 1; $probe -le 4; $probe++) {
            Start-Sleep -Milliseconds (1200 + (450 * $attempt))
            if (Test-DistroRunnable $Distro) {
                Write-Host "WSL restarted successfully and $Distro is available." -ForegroundColor Green
                return $true
            }
        }
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

function Resolve-CompatibleDistro {
    # Reuse the distro already selected by the working RNA Processing/downstream environment first.
    foreach ($markerPath in @($SharedDistroPreferenceFile,$CoreDistroPreferenceFile)) {
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            try { $shared=(Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop).Trim(); if($shared -and (Test-CompatibleDistro $shared)){ return $shared } } catch { }
        }
    }

    # Test the dedicated distribution only after the suite's working distro. This avoids all
    # registry and wsl.exe output parsing issues when OpDetect-Ubuntu already
    # exists, as shown in Windows File Explorer under Linux.
    if (Test-CompatibleDistro $PrivateDistro) {
        return $PrivateDistro
    }

    # Also honor a previously selected distribution by testing it directly.
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
    foreach ($name in @($PrivateDistro, 'Ubuntu-24.04', 'Ubuntu', 'Ubuntu-22.04', 'Debian')) {
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

function Save-SelectedDistro {
    param([string]$Distro)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($DistroPreferenceFile, $Distro + [Environment]::NewLine, $encoding)
}

function Convert-LocalWindowsPathToWsl {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)

    $fullPath = [System.IO.Path]::GetFullPath($WindowsPath)

    # Normal Windows drives are mounted by WSL under /mnt/<drive>. Constructing
    # this directly avoids native argument parsing that can turn E:\folder into
    # E:folder before Linux receives it.
    if ($fullPath -match '^([A-Za-z]):[\\/](.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $tail = $Matches[2] -replace '\\', '/'
        return "/mnt/$drive/$tail"
    }

    throw "The OpDetect package must be extracted to a local Windows drive such as C:, D:, or E:. Current path: $fullPath"
}

function Test-WslReady {
    try {
        & wsl.exe --status *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Install-WslPlatform {
    Write-Header "Linux support is required"
    Write-Warning "OpDetect cannot run directly in Windows PowerShell, Command Prompt, or Windows R."
    Write-Host "The launcher can enable WSL2. A Windows restart may be required."
    Write-Host "Your biological data will not be changed."

    if (-not (Confirm-Action "Install the WSL2 platform now?")) {
        Write-Host "Installation cancelled. OpDetect was not run." -ForegroundColor Yellow
        Wait-ForEnter
        exit 1
    }

    if (-not (Test-Administrator)) {
        Restart-AsAdministrator
    }

    Write-Host "Enabling WSL2 components..." -ForegroundColor Green
    & wsl.exe --install --no-distribution
    if ($LASTEXITCODE -ne 0) {
        throw "WSL platform installation failed. Install current Windows updates, restart Windows, and run INSTALL_OR_REPAIR.bat again."
    }

    Write-Host ""
    Write-Host "WSL2 installation was requested successfully." -ForegroundColor Green
    Write-Host "Restart Windows, then run OpDetect.exe again."

    if (Confirm-Action "Restart Windows now?") {
        Restart-Computer
    }

    Wait-ForEnter
    exit 0
}

function Install-PrivateDistro {
    # Recheck immediately before installation. This prevents a duplicate-install
    # attempt if Windows registered Ubuntu between the initial checks.
    $existing = Resolve-CompatibleDistro
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Host "Detected installed WSL distribution: $existing" -ForegroundColor Green
        Write-Host "It will be reused. Ubuntu will not be installed again."
        return $existing
    }

    Write-Header "No Ubuntu or Debian WSL distribution was found"
    Write-Host "The launcher can install a dedicated Ubuntu 24.04 WSL2 distribution named $PrivateDistro."
    Write-Host "It will be accessed as Linux root, so no Ubuntu username or password is needed."

    if (-not (Confirm-Action "Install $PrivateDistro now?")) {
        Write-Host "Installation cancelled. OpDetect was not run." -ForegroundColor Yellow
        Wait-ForEnter
        exit 1
    }

    Write-Host "Updating WSL..." -ForegroundColor Green
    & wsl.exe --update | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "WSL update did not complete. Continuing with the installed WSL version."
    }

    & wsl.exe --set-default-version 2 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set WSL2 as the default. Restart Windows and run INSTALL_OR_REPAIR.bat again."
    }

    $registered = @(Get-WslDistroRecords | Where-Object { $_.Name -ieq $PrivateDistro } | Select-Object -First 1)
    if ($registered.Count -gt 0) {
        Write-Host "$PrivateDistro is already registered and will be reused." -ForegroundColor Green
        return $registered[0].Name
    }

    Write-Host "Downloading $BaseDistro and registering it as $PrivateDistro..." -ForegroundColor Green
    & wsl.exe --install -d $BaseDistro --name $PrivateDistro --no-launch | Out-Host
    $installExit = $LASTEXITCODE

    if ($installExit -ne 0) {
        $afterFailure = @(Get-WslDistroRecords | Where-Object { $_.Name -ieq $PrivateDistro } | Select-Object -First 1)
        if ($afterFailure.Count -gt 0) {
            Write-Host "$PrivateDistro already exists and will be reused." -ForegroundColor Green
            return $afterFailure[0].Name
        }

        Write-Warning "The standard download failed. Retrying with direct web download."
        & wsl.exe --install -d $BaseDistro --name $PrivateDistro --no-launch --web-download | Out-Host
        $installExit = $LASTEXITCODE
    }

    $installedAfter = Resolve-CompatibleDistro
    if (-not [string]::IsNullOrWhiteSpace($installedAfter)) {
        return $installedAfter
    }

    if ($installExit -ne 0) {
        throw "Ubuntu installation failed. Run 'wsl --update', restart Windows, and try again."
    }

    Write-Host "Ubuntu installation was requested, but Windows may need a restart to finish registration." -ForegroundColor Yellow
    Write-Host "Restart Windows and run OpDetect.exe again."
    Wait-ForEnter
    exit 0
}

function Ensure-Wsl2 {
    param([string]$Distro)

    # First trust the running kernel. Imported/custom WSL2 distributions can
    # have a missing or stale registry Version value even though they are
    # genuinely running under WSL2.
    if (Test-DistroIsWsl2 $Distro) {
        return
    }

    $version = Get-DistroVersion $Distro
    if ($version -eq 1) {
        Write-Warning "$Distro is currently using WSL1. OpDetect requires WSL2."
        if (-not (Confirm-Action "Convert $Distro to WSL2 now?")) {
            throw "WSL2 conversion was cancelled."
        }
        if (-not (Test-Administrator)) {
            Restart-AsAdministrator
        }
        & wsl.exe --set-default-version 2
        & wsl.exe --set-version $Distro 2
        if ($LASTEXITCODE -ne 0) {
            throw "Could not convert $Distro to WSL2."
        }
        if (-not (Test-DistroIsWsl2 $Distro)) {
            throw "The WSL2 conversion command completed, but the WSL2 kernel could not be verified."
        }
    }
    else {
        throw "Could not confirm that $Distro is running with WSL2. Run 'wsl --shutdown', restart Windows, and try again."
    }
}

function Convert-ToBashSingleQuoted {
    param([string]$Value)
    if ($Value.Contains("'")) {
        throw "The extracted pipeline folder path contains a single quote. Move it to a simpler folder and try again."
    }
    return "'" + $Value + "'"
}

try {
    Write-Header "OpDetect automatic Windows 11 setup"

    if ($env:OS -ne "Windows_NT") {
        throw "This launcher is for Windows. On native Ubuntu or Debian, run: bash setup_linux.sh"
    }

    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 22000) {
        Write-Warning "This computer does not appear to be Windows 11. The automated installer is designed for Windows 11."
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "wsl.exe is unavailable. Install current Windows updates and run this launcher again."
    }

    if (-not (Test-WslReady)) {
        $registeredDistros = @(Get-WslDistroRecords)
        if ($registeredDistros.Count -eq 0) {
            Install-WslPlatform
        }
        else {
            # A registered distro means the Windows feature is already present.
            # Continue to the targeted recovery below instead of attempting a
            # duplicate WSL/Ubuntu installation because `wsl --status` is stale.
            Write-Warning "WSL status is temporarily unavailable, but a registered Linux distribution was found. Continuing with automatic session recovery."
        }
    }

    $SelectedDistro = Resolve-CompatibleDistro
    if ([string]::IsNullOrWhiteSpace($SelectedDistro)) {
        $SelectedDistro = Install-PrivateDistro
    }

    if (-not (Repair-WslSessionForDistro -Distro $SelectedDistro -Attempts 3)) {
        if (-not (Test-Administrator)) {
            Write-Warning "User-level WSL recovery did not restart '$SelectedDistro'. Continuing in an elevated repair window so the WSL host service can be reset."
            Restart-AsAdministrator
        }
        Write-Warning "'$SelectedDistro' remains registered and its Linux files were preserved, but the Windows WSL host is still not responding. A Windows restart is now required; Ubuntu must not be reinstalled or unregistered."
        if (Confirm-Action 'Restart Windows now, then reopen OpDetect.exe to continue the same installation?') {
            Write-Host 'Restarting Windows. Reopen OpDetect.exe after sign-in; setup will continue with the existing distribution.' -ForegroundColor Green
            Restart-Computer -Force
            exit 0
        }
        throw "'$SelectedDistro' is registered, but Windows could not start it after automatic terminate/shutdown and WSL host-service recovery. Restart Windows once, then open OpDetect.exe again. Do not reinstall Ubuntu or delete the distribution."
    }
    if (-not (Test-CompatibleDistro $SelectedDistro)) {
        throw "The installed WSL distribution '$SelectedDistro' started, but the launcher could not find /etc/os-release, apt-get, and bash. The distribution may be incomplete."
    }

    Ensure-Wsl2 $SelectedDistro
    Save-SelectedDistro $SelectedDistro

    if ($SelectedDistro -eq $PrivateDistro) {
        Write-Host "Using OpDetect Linux environment: $SelectedDistro" -ForegroundColor Green
    }
    else {
        Write-Header "Using your existing WSL Linux installation"
        Write-Host "Detected compatible distribution: $SelectedDistro" -ForegroundColor Green
        Write-Host "Ubuntu is already installed and will be reused. A second distribution will NOT be installed."
        Write-Host "OpDetect commands will run as Linux root, so no Ubuntu password is required."
        Write-Host "Your normal Linux user and default login are not changed."
    }

    $sourcePath = (Resolve-Path $PSScriptRoot).Path
    $wslSource = Convert-LocalWindowsPathToWsl $sourcePath
    Write-Host "Windows package folder: $sourcePath"
    Write-Host "WSL package folder:     $wslSource"
    $quotedSource = Convert-ToBashSingleQuoted $wslSource

    Write-Header "Copying the pipeline into $SelectedDistro"
    $copyCommand = 'set -Eeuo pipefail; ' +
        'mkdir -p /root/opdetect_pipeline; ' +
        'cp -a ' + $quotedSource + '/. /root/opdetect_pipeline/; ' +
        '/bin/bash /root/opdetect_pipeline/normalize_after_copy.sh'

    & wsl.exe -d $SelectedDistro -u root -- bash -lc $copyCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Could not copy the pipeline into $SelectedDistro."
    }

    # Never trust the old installation marker by itself. Earlier interrupted
    # setup attempts could leave that marker behind even when Miniforge or the
    # bioinformatics tools were absent. Test the real environment instead.
    & wsl.exe -d $SelectedDistro -u root -- bash /root/opdetect_pipeline/environment_ready.sh *> $null
    $environmentReady = $LASTEXITCODE -eq 0

    if (-not $environmentReady) {
        Write-Header "Installing or repairing OpDetect dependencies"
        Write-Host "The existing installation is incomplete or missing required tools." -ForegroundColor Yellow
        Write-Host "The launcher will repair it automatically. No Ubuntu password will be requested."

        & wsl.exe -d $SelectedDistro -u root -- /bin/rm -f /root/opdetect_pipeline/.installation_complete
        & wsl.exe -d $SelectedDistro -u root -- bash -lc 'cd /root/opdetect_pipeline && bash setup_linux.sh'
        if ($LASTEXITCODE -ne 0) {
            throw "The Linux dependency installation or repair did not complete successfully."
        }
    }
    else {
        Write-Header "Using the existing OpDetect environment"
        Write-Host "Miniforge, the Conda environment, and all required tools were verified." -ForegroundColor Green
    }

    Write-Header "Checking the installation"
    $checkCommand = 'if [ -x /root/.local/share/prok-rnaseq/miniforge3/bin/conda ]; then C=/root/.local/share/prok-rnaseq/miniforge3; else C=/root/miniforge3; fi; source "$C/etc/profile.d/conda.sh"; ' +
        'conda activate opdetect-pipeline; ' +
        'cd /root/opdetect_pipeline; ' +
        'bash check_wsl_environment.sh'

    & wsl.exe -d $SelectedDistro -u root -- bash -lc $checkCommand
    if ($LASTEXITCODE -ne 0) {
        throw "The environment check found a problem. Review the messages above."
    }

    & wsl.exe -d $SelectedDistro -u root -- bash -lc 'touch /root/opdetect_pipeline/.installation_complete'

    # Save a Windows-side verification cache only after the real Linux check
    # succeeds. The GUI can display Ready immediately after the installer
    # closes, while Refresh and Run still perform a live verification.
    $verifiedText = "distro=$SelectedDistro`nverified=$([DateTime]::UtcNow.ToString('o'))`n"
    $verifiedEncoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($EnvironmentVerifiedFile, $verifiedText, $verifiedEncoding)

    Write-Header "Installation complete"
    Write-Host "Selected Linux environment: $SelectedDistro" -ForegroundColor Green
    Write-Host "No Ubuntu password was needed."
    Write-Host "Return to Bacterial RNA Analysis, open Operons and transcription units, and continue to OpDetect."
    Write-Host "Use Readiness check to confirm the installed environment."
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "The installer stopped without running OpDetect." -ForegroundColor Red
    Wait-ForEnter
    exit 1
}
