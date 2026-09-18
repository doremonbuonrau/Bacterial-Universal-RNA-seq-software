[CmdletBinding()]
param(
    [ValidateSet('short','long','both')]
    [string]$AnalysisType = 'both',
    [switch]$RepairPythonPackages
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$appRoot = Split-Path -Parent $PSScriptRoot
$corePreferenceFile = Join-Path $PSScriptRoot '.wsl_distro'

function Show-Message([string]$Text, [string]$Title, [string]$Icon = 'Information') {
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', $Icon)
}

function ConvertTo-WindowsCommandLineArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    return '"' + ([string]$Value).Replace('"', '\"') + '"'
}

function Normalize-NativeOutputText([string]$Text) {
    if ($null -eq $Text) { return '' }
    $clean = [string]$Text
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

function Invoke-WslConsole([string[]]$Arguments) {
    # Keep installation output live, but pass every WSL argument separately.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & wsl.exe @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $line = [string]$_.Exception.Message
                if (-not $line) { $line = [string]$_ }
                Write-Host $line
            }
            else { Write-Host ([string]$_) }
        }
        if ($null -eq $LASTEXITCODE) { return -1 }
        return [int]$LASTEXITCODE
    }
    catch {
        Write-Host ("WSL launch failed: " + $_.Exception.Message)
        return -1
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
    $probe = Invoke-WslCapture @('-d', (Normalize-WslName $Distro), '-u', 'root', '--', '/bin/cat', '/etc/os-release') 60000
    if ($probe.ExitCode -ne 0) { return $false }
    return ([string]$probe.StandardOutput) -match '(?im)^ID=\"?(ubuntu|debian)\"?$'
}

function Test-WslDistroHasCoreRnaEnvironment([string]$Distro) {
    $name = Normalize-WslName $Distro
    if (-not $name -or -not (Test-WslDistroRunnable $name)) { return $false }
    $probe = Invoke-WslCapture @('-d', $name, '-u', 'root', '--', 'bash', '-lc', 'if [ -x /root/.local/share/prok-rnaseq/miniforge3/envs/prok-rnaseq/bin/python ]; then printf BACTERIAL_RNA_CORE_READY; fi') 60000
    return ($probe.ExitCode -eq 0 -and $probe.StandardOutput -match 'BACTERIAL_RNA_CORE_READY')
}

function Test-WslDistroIsWsl2([string]$Distro) {
    if (-not (Test-WslDistroRunnable $Distro)) { return $false }
    $kernel = Invoke-WslCapture @('-d', (Normalize-WslName $Distro), '-u', 'root', '--', '/bin/uname', '-r') 60000
    if ($kernel.ExitCode -ne 0) { return $false }
    return ([string]$kernel.StandardOutput) -match '(?i)WSL2|microsoft-standard'
}

function Resolve-WslBashPath([string]$Distro, [bool]$UseDefault) {
    foreach ($candidate in @('/bin/bash', '/usr/bin/bash')) {
        if ($UseDefault) {
            $probe = Invoke-WslCapture @('-u', 'root', '--', $candidate, '--version') 30000
        }
        else {
            $probe = Invoke-WslCapture @('-d', (Normalize-WslName $Distro), '-u', 'root', '--', $candidate, '--version') 30000
        }
        if ($probe.ExitCode -eq 0) { return $candidate }
    }
    return $null
}

function Invoke-WslSetupDiagnostic([string]$Distro, [bool]$UseDefault, [string]$SetupPath) {
    $diagnostic = 'printf "PATH=%s\n" "$PATH"; printf "shells:\n"; ls -l /bin/bash /usr/bin/bash 2>&1 || true; printf "setup script:\n"; ls -l "$1" 2>&1 || true; head -n 2 "$1" 2>&1 || true'
    if ($UseDefault) {
        return Invoke-WslCapture @('-u', 'root', '--', '/bin/sh', '-c', $diagnostic, 'rna-setup-diagnostic', $SetupPath) 30000
    }
    return Invoke-WslCapture @('-d', (Normalize-WslName $Distro), '-u', 'root', '--', '/bin/sh', '-c', $diagnostic, 'rna-setup-diagnostic', $SetupPath) 30000
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

function Get-WslRegisteredDistroNames {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($name in @(Get-WslRegistryDistroNames)) {
        $clean = Normalize-WslName ([string]$name)
        if ($clean -and -not $names.Contains($clean)) { [void]$names.Add($clean) }
    }
    foreach ($name in @(Get-WslListedDistroNames)) {
        $clean = Normalize-WslName ([string]$name)
        if ($clean -and -not $names.Contains($clean)) { [void]$names.Add($clean) }
    }
    return @($names)
}

function Resolve-WslDistro {
    $preferred = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $corePreferenceFile -PathType Leaf) {
        try {
            $saved = Normalize-WslName (Get-Content -LiteralPath $corePreferenceFile -Raw -ErrorAction Stop)
            if ($saved) { [void]$preferred.Add($saved) }
        } catch { }
    }

    $defaultName = ''
    $defaultProbe = Invoke-WslCapture @('-u', 'root', '--', '/usr/bin/printenv', 'WSL_DISTRO_NAME') 60000
    if ($defaultProbe.ExitCode -eq 0) { $defaultName = Get-WslNameFromProbeOutput $defaultProbe.StandardOutput }

    $listed = @(Get-WslListedDistroNames)
    $listedMap = @{}
    foreach ($name in $listed) {
        $clean = Normalize-WslName ([string]$name)
        if ($clean) { $listedMap[$clean.ToLowerInvariant()] = $clean }
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($value in $preferred) { [void]$candidates.Add([string]$value) }
    if ($defaultName) { [void]$candidates.Add($defaultName) }
    foreach ($value in $listed) { [void]$candidates.Add([string]$value) }
    foreach ($known in @('Ubuntu-24.04', 'Ubuntu', 'Ubuntu-22.04', 'Debian', 'OpDetect-Ubuntu')) { [void]$candidates.Add($known) }

    $seen = @{}
    $normalized = New-Object System.Collections.Generic.List[string]
    foreach ($candidateValue in $candidates) {
        $candidate = Normalize-WslName ([string]$candidateValue)
        if (-not $candidate) { continue }
        $key = $candidate.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if ($listedMap.ContainsKey($key)) { $candidate = [string]$listedMap[$key] }
        [void]$normalized.Add($candidate)
    }

    # Repair/update the distro that already owns the managed core environment.
    foreach ($candidate in $normalized) {
        if (Test-WslDistroHasCoreRnaEnvironment $candidate) {
            return [pscustomobject]@{ Name = $candidate; UseDefault = $false; Verified = $true; Source = 'existing RNA Processing environment' }
        }
    }

    # First installation: choose a normal runnable Ubuntu/Debian distro, never
    # the legacy OpDetect-Ubuntu solely because Windows made it the default.
    foreach ($candidate in $normalized) {
        if ($candidate -match '(?i)^OpDetect-Ubuntu$') { continue }
        if (Test-WslDistroCompatible $candidate) {
            return [pscustomobject]@{ Name = $candidate; UseDefault = $false; Verified = $true; Source = 'runnable Ubuntu/Debian distribution' }
        }
    }

    return $null
}

function Get-WslDistroVersion([string]$Distro) {
    if ([string]::IsNullOrWhiteSpace($Distro)) { return 0 }
    try {
        $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        foreach ($item in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $properties = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            $name = Normalize-WslName ([string]$properties.DistributionName)
            if ($name -and $name -ieq $Distro) {
                $version = 0
                try { $version = [int]$properties.Version } catch { $version = 0 }
                if ($version -in @(1, 2)) { return $version }
            }
        }
    }
    catch { }
    if (Test-WslDistroIsWsl2 $Distro) { return 2 }
    return 0
}

function Convert-WindowsPathToWsl([string]$WindowsPath) {
    $fullPath = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -match '^([A-Za-z]):[\\/](.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $tail = $Matches[2].Replace('\', '/')
        return "/mnt/$drive/$tail"
    }
    throw "The application must be extracted to a local Windows drive such as C:, D:, or E:. Unsupported path: $WindowsPath"
}

function Get-InstalledDistroSummary {
    $combined = @((Get-WslRegistryDistroNames)) + @((Get-WslListedDistroNames))
    $names = @($combined | Where-Object { $_ } | Select-Object -Unique)
    if ($names.Count -eq 0) { return '(none detected)' }
    return ($names -join ', ')
}

try {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($null -eq $wsl) {
        Show-Message 'WSL is not available. Windows 10 version 2004 or Windows 11 is required.' 'RNA-seq setup' 'Error'
        exit 2
    }

    $listed = @(Get-WslListedDistroNames)
    $registry = @(Get-WslRegistryDistroNames)
    $target = Resolve-WslDistro
    if ($null -eq $target) {
        if ($RepairPythonPackages) {
            Show-Message 'The lightweight package repair requires an existing WSL environment. Use Install or repair core to create or recover the full environment.' 'Core environment required' 'Warning'
            exit 2
        }
        if ($listed.Count -gt 0) {
            Show-Message ("WSL reports installed distributions, but none could be selected after normalization.`r`n`r`nRegistered with WSL: " + ($listed -join ', ') + "`r`n`r`nRun 'wsl --shutdown' once, open Ubuntu, and retry. The suite will not install another Ubuntu copy.") 'Refresh existing WSL environment' 'Warning'
            exit 3
        }
        if ($registry.Count -gt 0) {
            Show-Message ("Windows contains stale WSL registry entries, but the WSL service does not list a registered distribution.`r`n`r`nRegistry entries: " + ($registry -join ', ') + "`r`n`r`nOpen Windows Terminal and run 'wsl --list --verbose'. Do not install another copy until the existing registration is repaired.") 'Repair existing WSL registration' 'Warning'
            exit 3
        }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            'No registered WSL Linux distribution was found. Install Ubuntu 24.04 now? Windows may request administrator permission and a restart.',
            'Install Linux environment',
            'YesNo',
            'Question'
        )
        if ($answer -ne 'Yes') { exit 0 }
        Start-Process -FilePath 'wsl.exe' -Verb RunAs -Wait -ArgumentList @('--install', '-d', 'Ubuntu-24.04')
        Show-Message 'Ubuntu installation was requested. Complete any restart or first-run user-name prompt, then run Install or Repair again.' 'RNA-seq setup'
        exit 0
    }

    $selected = Normalize-WslName ([string]$target.Name)
    $useDefault = [bool]$target.UseDefault
    Write-Host "Using installed WSL distribution: $selected"
    Write-Host "Selection source: $($target.Source)"

    $wslVersion = Get-WslDistroVersion $selected
    if ($wslVersion -eq 1) {
        Write-Host "Converting $selected from WSL1 to WSL2. This may take a few minutes..."
        $conversionExitCode = Invoke-WslConsole @('--set-version', $selected, '2')
        if ($conversionExitCode -ne 0) {
            throw "Could not convert '$selected' to WSL2. Installed distributions: $(Get-InstalledDistroSummary)"
        }
    }
    elseif ($wslVersion -eq 2) {
        Write-Host "$selected is already registered as WSL2. Conversion is not required."
    }
    else {
        Write-Host 'The WSL version could not be read reliably; automatic conversion is being skipped.'
    }

    if ($useDefault) {
        $launchProbe = Invoke-WslCapture @('-u', 'root', '--', '/bin/echo', 'BACTERIAL_RNA_WSL_READY') 60000
    }
    else {
        $launchProbe = Invoke-WslCapture @('-d', $selected, '-u', 'root', '--', '/bin/echo', 'BACTERIAL_RNA_WSL_READY') 60000
    }
    if ($launchProbe.ExitCode -eq 0 -and $launchProbe.StandardOutput -match 'BACTERIAL_RNA_WSL_READY') {
        Write-Host 'WSL startup test passed.'
    }
    else {
        Write-Host 'The quick WSL startup test was inconclusive; continuing with the full setup command.'
        $probeText = Normalize-WslName (($launchProbe.StandardError, $launchProbe.StandardOutput) -join ' ')
        if ($probeText) { Write-Host "Probe detail: $probeText" }
    }

    $linuxApp = Convert-WindowsPathToWsl $appRoot
    $setupName = if ($RepairPythonPackages) { 'repair_core_python_packages.sh' } else { 'setup_linux.sh' }
    $setup = "$linuxApp/environment/$setupName"
    $bashPath = Resolve-WslBashPath -Distro $selected -UseDefault $useDefault
    if (-not $bashPath) {
        # Do not reject a working distribution because a lightweight shell probe
        # was misparsed by Windows PowerShell. The full setup call below is the
        # authoritative test and can retry alternate Bash entry points on 126/127.
        $bashPath = '/bin/bash'
        Write-Host 'Bash preflight was inconclusive; continuing with the full setup command.'
    }
    else { Write-Host "Linux shell preflight passed: $bashPath" }

    if ($useDefault) {
        $scriptProbe = Invoke-WslCapture @('-u', 'root', '--', '/bin/sh', '-c', 'test -r "$1"', 'rna-setup-probe', $setup) 30000
    }
    else {
        $scriptProbe = Invoke-WslCapture @('-d', $selected, '-u', 'root', '--', '/bin/sh', '-c', 'test -r "$1"', 'rna-setup-probe', $setup) 30000
    }
    if ($scriptProbe.ExitCode -ne 0) {
        throw "The Linux setup script is not readable at '$setup'. Extract the software to a local Windows drive and retry."
    }

    $shellCandidates = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($bashPath, '/bin/bash', '/usr/bin/bash', 'bash')) {
        if ($candidate -and -not $shellCandidates.Contains([string]$candidate)) { [void]$shellCandidates.Add([string]$candidate) }
    }

    $setupExitCode = 127
    foreach ($shell in $shellCandidates) {
        Write-Host "Starting Linux setup with: $shell"
        if ($useDefault) {
            $setupExitCode = Invoke-WslConsole @('-u', 'root', '--', $shell, $setup, '--analysis-type', $AnalysisType)
        }
        else {
            $setupExitCode = Invoke-WslConsole @('-d', $selected, '-u', 'root', '--', $shell, $setup, '--analysis-type', $AnalysisType)
        }
        if ($setupExitCode -notin @(126, 127)) {
            $bashPath = $shell
            break
        }
        Write-Host "The shell entry point '$shell' returned $setupExitCode; trying the next Bash entry point."
    }

    if (-not $useDefault -and $setupExitCode -in @(126, 127)) {
        $defaultRetry = Invoke-WslCapture @('-u', 'root', '--', '/usr/bin/printenv', 'WSL_DISTRO_NAME') 60000
        if ($defaultRetry.ExitCode -eq 0) {
            $retryName = Get-WslNameFromProbeOutput $defaultRetry.StandardOutput
            if ($retryName) {
                foreach ($shell in $shellCandidates) {
                    Write-Host "Named launch failed; retrying through the default WSL distribution '$retryName' with $shell"
                    $setupExitCode = Invoke-WslConsole @('-u', 'root', '--', $shell, $setup, '--analysis-type', $AnalysisType)
                    if ($setupExitCode -notin @(126, 127)) {
                        $selected = $retryName
                        $useDefault = $true
                        $bashPath = $shell
                        break
                    }
                }
            }
        }
    }
    if ($setupExitCode -ne 0) {
        $diagnostic = Invoke-WslSetupDiagnostic -Distro $selected -UseDefault $useDefault -SetupPath $setup
        $detail = (($diagnostic.StandardOutput, $diagnostic.StandardError) -join "`r`n").Trim()
        if ($detail) {
            throw "Linux setup exited with code $setupExitCode.`r`n`r`nDiagnostic:`r`n$detail`r`n`r`nWSL reported distributions: $($listed -join ', '). Selected technical identifier: '$selected'."
        }
        throw "Linux setup exited with code $setupExitCode. WSL reported distributions: $($listed -join ', '). Selected technical identifier: '$selected'."
    }

    [System.IO.File]::WriteAllText($corePreferenceFile, $selected, (New-Object System.Text.UTF8Encoding($false)))
    if ($RepairPythonPackages) {
        Show-Message "The OpenPyXL upgrade dependency was repaired and the core environment is ready for $AnalysisType mode. Return to the application and select Check environment for read type." 'RNA-seq dependency repair complete'
    }
    else {
        Show-Message "The core Linux RNA-seq environment is ready for $AnalysisType mode. Return to the application and select Check environment for read type." 'RNA-seq setup complete'
    }
}
catch {
    if ($_.Exception.Message -match '(?i)canceled|cancelled|operation was canceled') {
        Show-Message 'Setup was canceled. No further installation steps were run. You can start Install or Repair again whenever you are ready.' 'RNA-seq setup canceled'
        exit 0
    }
    Show-Message ("Setup could not finish.`r`n`r`n" + $_.Exception.Message) 'RNA-seq setup error' 'Error'
    exit 1
}
