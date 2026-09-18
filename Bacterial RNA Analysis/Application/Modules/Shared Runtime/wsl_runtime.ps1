# Bacterial RNA Analysis shared WSL runtime resolver.
# Windows PowerShell 5.1 compatible.
# Important: never reject a distro because of its NAME.  A distro is usable when
# it actually starts and contains the requested environment.

function Normalize-BraWslDistroName([string]$Value) {
    if ($null -eq $Value) { return '' }
    $clean = [string]$Value
    $clean = [System.Text.RegularExpressions.Regex]::Replace($clean, '[\p{Cc}\p{Cf}]', '')
    try { $clean = $clean.Normalize([System.Text.NormalizationForm]::FormKC) } catch { }
    $clean = $clean.Trim()
    if ($clean.StartsWith('*')) { $clean = $clean.Substring(1).Trim() }
    return $clean
}

function ConvertTo-BraWindowsCommandLineArgument([string]$Value) {
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\\') { $slashes++; continue }
        if ($ch -eq '"') {
            if ($slashes -gt 0) { [void]$sb.Append(('\\' * ($slashes * 2))) }
            [void]$sb.Append('\\"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$sb.Append(('\\' * $slashes)); $slashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($slashes -gt 0) { [void]$sb.Append(('\\' * ($slashes * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-BraWslCapture {
    param(
        [string[]]$Arguments,
        [int]$TimeoutMilliseconds = 20000
    )
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ ExitCode=-1; Output='wsl.exe was not found.'; StandardOutput=''; StandardError='wsl.exe was not found.'; TimedOut=$false }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = ((@($Arguments) | ForEach-Object { ConvertTo-BraWindowsCommandLineArgument ([string]$_) }) -join ' ')
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) {
            return [pscustomobject]@{ ExitCode=-1; Output='wsl.exe could not be started.'; StandardOutput=''; StandardError='wsl.exe could not be started.'; TimedOut=$false }
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            try { $process.WaitForExit() } catch { }
            $out = try { [string]$stdoutTask.Result } catch { '' }
            $err = try { [string]$stderrTask.Result } catch { '' }
            return [pscustomobject]@{ ExitCode=-2; Output=(($out+"`r`n"+$err).Trim()); StandardOutput=$out.Trim(); StandardError=$err.Trim(); TimedOut=$true }
        }
        $process.WaitForExit()
        $out = [string]$stdoutTask.Result
        $err = [string]$stderrTask.Result
        return [pscustomobject]@{ ExitCode=[int]$process.ExitCode; Output=(($out+"`r`n"+$err).Trim()); StandardOutput=$out.Trim(); StandardError=$err.Trim(); TimedOut=$false }
    } catch {
        return [pscustomobject]@{ ExitCode=-1; Output=$_.Exception.Message; StandardOutput=''; StandardError=$_.Exception.Message; TimedOut=$false }
    } finally {
        try { $process.Dispose() } catch { }
    }
}

function Invoke-BraWslDirectText {
    param([string[]]$Arguments)
    try {
        $output = & wsl.exe @Arguments 2>$null
        $code = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode=[int]$code; Text=((@($output) | ForEach-Object { [string]$_ }) -join "`n") }
    } catch {
        return [pscustomobject]@{ ExitCode=-1; Text=$_.Exception.Message }
    }
}

function Get-BraWslRegistryEntries {
    $result = @()
    try {
        $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        if (-not (Test-Path -LiteralPath $root)) { return @() }
        $rootProps = Get-ItemProperty -LiteralPath $root -ErrorAction SilentlyContinue
        $defaultId = [string]$rootProps.DefaultDistribution
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            $name = Normalize-BraWslDistroName ([string]$props.DistributionName)
            if (-not $name) { continue }
            $version = 0
            try { if ($null -ne $props.Version) { $version = [int]$props.Version } } catch { }
            $result += [pscustomobject]@{ Name=$name; Version=$version; IsDefault=([string]$key.PSChildName -eq $defaultId) }
        }
    } catch { }
    return @($result)
}

function Get-BraWslListedDistroNames {
    # Keep the raw-byte decoding that was proven in the 1.9.3 line.
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath 'wsl.exe' -ArgumentList @('--list','--quiet') -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if ($p.ExitCode -ne 0) { return @() }
        $bytes = [System.IO.File]::ReadAllBytes($stdoutPath)
        if ($bytes.Length -eq 0) { return @() }
        $unicode = ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes.Length -ge 4 -and ($bytes[1] -eq 0 -or $bytes[3] -eq 0))
        if ($unicode) {
            if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $output=[System.Text.Encoding]::Unicode.GetString($bytes,2,$bytes.Length-2) }
            else { $output=[System.Text.Encoding]::Unicode.GetString($bytes) }
        } else {
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $output=[System.Text.Encoding]::UTF8.GetString($bytes,3,$bytes.Length-3) }
            else { $output=[System.Text.Encoding]::UTF8.GetString($bytes) }
        }
        $result=@()
        foreach ($line in ([string]$output -split '[\r\n]+')) {
            $name=Normalize-BraWslDistroName $line
            if (-not $name) { continue }
            if ($name -match '(?i)there is no distribution|error code|windows subsystem') { continue }
            $result += $name
        }
        return @($result)
    } catch { return @() }
    finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-BraDefaultWslDistroName {
    # Use ProcessStartInfo capture instead of PowerShell native-command error handling.
    # WSL can emit a harmless localhost-proxy warning on stderr even when the command
    # succeeds. With $ErrorActionPreference=Stop that warning must never make distro
    # discovery look like a failure.
    $probe = Invoke-BraWslCapture -Arguments @('-u','root','--','/usr/bin/printenv','WSL_DISTRO_NAME') -TimeoutMilliseconds 30000
    if ($probe.ExitCode -eq 0) {
        foreach ($line in ([string]$probe.StandardOutput -split '[\r\n]+')) {
            $name=Normalize-BraWslDistroName ([string]$line)
            if ($name) { return $name }
        }
    }
    foreach ($entry in @(Get-BraWslRegistryEntries)) { if ($entry.IsDefault) { return [string]$entry.Name } }
    return ''
}

function Test-BraWslDistroRunnable([string]$Distro) {
    $name=Normalize-BraWslDistroName $Distro
    if (-not $name) { return $false }

    # Probe root first because all scientific environments are installed under
    # /root/.local/share/prok-rnaseq.  Do the two probes explicitly instead of
    # iterating nested PowerShell arrays; nested arrays can be pipeline-unrolled
    # and accidentally pass one token at a time to wsl.exe.
    $probe = Invoke-BraWslCapture -Arguments @('-d',$name,'-u','root','--','/bin/echo','BACTERIAL_RNA_WSL_READY') -TimeoutMilliseconds 45000
    if ($probe.ExitCode -eq 0 -and ([string]$probe.StandardOutput -match 'BACTERIAL_RNA_WSL_READY')) { return $true }

    # A distribution without a configured root user may still be runnable with
    # its default user.  This second probe lets the resolver distinguish that
    # case from a missing or broken WSL registration.
    $probe = Invoke-BraWslCapture -Arguments @('-d',$name,'--','/bin/echo','BACTERIAL_RNA_WSL_READY') -TimeoutMilliseconds 45000
    return ($probe.ExitCode -eq 0 -and ([string]$probe.StandardOutput -match 'BACTERIAL_RNA_WSL_READY'))
}

function Test-BraCoreRnaEnvironment([string]$Distro) {
    $name=Normalize-BraWslDistroName $Distro
    if (-not $name -or -not (Test-BraWslDistroRunnable $name)) { return $false }
    $probe = Invoke-BraWslCapture -Arguments @('-d',$name,'-u','root','--','/usr/bin/test','-x','/root/.local/share/prok-rnaseq/miniforge3/envs/prok-rnaseq/bin/python') -TimeoutMilliseconds 30000
    return ($probe.ExitCode -eq 0)
}

function Test-BraDownstreamEnvironment([string]$Distro) {
    $name=Normalize-BraWslDistroName $Distro
    if (-not $name -or -not (Test-BraWslDistroRunnable $name)) { return $false }
    $probe = Invoke-BraWslCapture -Arguments @('-d',$name,'-u','root','--','/usr/bin/test','-x','/root/.local/share/prok-rnaseq/miniforge3/envs/prok-rnaseq-downstream/bin/Rscript') -TimeoutMilliseconds 30000
    return ($probe.ExitCode -eq 0)
}

function Test-BraUbuntuDebianDistro([string]$Distro) {
    $name=Normalize-BraWslDistroName $Distro
    if (-not $name -or -not (Test-BraWslDistroRunnable $name)) { return $false }
    $bash = Invoke-BraWslCapture -Arguments @('-d',$name,'-u','root','--','/usr/bin/test','-x','/bin/bash') -TimeoutMilliseconds 30000
    if ($bash.ExitCode -ne 0) { return $false }
    $apt = Invoke-BraWslCapture -Arguments @('-d',$name,'-u','root','--','/usr/bin/test','-x','/usr/bin/apt-get') -TimeoutMilliseconds 30000
    return ($apt.ExitCode -eq 0)
}

function Find-BraSuiteRoot([string]$StartPath) {
    if ([string]::IsNullOrWhiteSpace($StartPath)) { return '' }
    try {
        $current=Get-Item -LiteralPath $StartPath -ErrorAction Stop
        if (-not $current.PSIsContainer) { $current=$current.Directory }
        for ($i=0; $i -lt 12 -and $current; $i++) {
            if ((Test-Path -LiteralPath (Join-Path $current.FullName 'App\rnaseq_gui.ps1') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $current.FullName 'Modules') -PathType Container)) { return $current.FullName }
            $current=$current.Parent
        }
    } catch { }
    return ''
}

function Save-BraWslDistroSelection {
    param([string]$SuiteRoot,[string]$Distro)
    $name=Normalize-BraWslDistroName $Distro
    if (-not $name) { return }
    $env:BACTERIAL_RNA_WSL_DISTRO=$name
    # Do NOT overwrite App\environment\.wsl_distro here. RNA Processing owns
    # that marker. Downstream/OpDetect selection is saved separately.
    if ($SuiteRoot) {
        $path=Join-Path $SuiteRoot 'Modules\Shared Analysis State\wsl_distro.txt'
        try {
            [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $path))
            [System.IO.File]::WriteAllText($path,$name+[Environment]::NewLine,(New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
}

function Resolve-BraWslDistro {
    param(
        [string]$SuiteRoot='',
        [ValidateSet('Core','Downstream','Runnable')][string]$Purpose='Core'
    )
    $candidates=@()
    if ($env:BACTERIAL_RNA_WSL_DISTRO) { $candidates += (Normalize-BraWslDistroName $env:BACTERIAL_RNA_WSL_DISTRO) }

    # RNA Processing's own marker is a preference, not an absolute requirement.
    if ($SuiteRoot) {
        foreach ($path in @(
            (Join-Path $SuiteRoot 'App\environment\.wsl_distro'),
            (Join-Path $SuiteRoot 'Modules\Shared Analysis State\wsl_distro.txt'),
            (Join-Path $SuiteRoot 'Modules\Operon Prediction Suite\Applications\OpDetect\App\.opdetect_wsl_distro')
        )) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                try { $v=Normalize-BraWslDistroName ([string](Get-Content -LiteralPath $path -Raw -ErrorAction Stop)); if ($v) { $candidates += $v } } catch { }
            }
        }
    }

    $default=Get-BraDefaultWslDistroName
    if ($default) { $candidates += $default }
    foreach ($entry in @(Get-BraWslRegistryEntries | Sort-Object @{Expression='IsDefault';Descending=$true},Name)) { $candidates += [string]$entry.Name }
    foreach ($name in @(Get-BraWslListedDistroNames)) { $candidates += [string]$name }
    $candidates += @('Ubuntu-24.04','Ubuntu','Ubuntu-22.04','OpDetect-Ubuntu','Debian')

    $ordered=@(); $seen=@{}
    foreach ($value in @($candidates)) {
        $candidate=Normalize-BraWslDistroName ([string]$value)
        if (-not $candidate) { continue }
        if ($candidate -match '(?i)^(docker-desktop|docker-desktop-data|rancher-desktop|podman-machine)') { continue }
        $key=$candidate.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key]=$true
        $ordered += $candidate
    }

    # For downstream modules prefer the distro that already contains the
    # downstream R environment. This may legitimately be named OpDetect-Ubuntu.
    if ($Purpose -eq 'Downstream') {
        foreach ($candidate in @($ordered)) {
            if (Test-BraDownstreamEnvironment $candidate) { Save-BraWslDistroSelection -SuiteRoot $SuiteRoot -Distro $candidate; return $candidate }
        }
        foreach ($candidate in @($ordered)) {
            if (Test-BraCoreRnaEnvironment $candidate) { Save-BraWslDistroSelection -SuiteRoot $SuiteRoot -Distro $candidate; return $candidate }
        }
    } elseif ($Purpose -eq 'Core') {
        foreach ($candidate in @($ordered)) {
            if (Test-BraCoreRnaEnvironment $candidate) { Save-BraWslDistroSelection -SuiteRoot $SuiteRoot -Distro $candidate; return $candidate }
        }
        # OpDetect can be installed into a distro that already owns downstream.
        foreach ($candidate in @($ordered)) {
            if (Test-BraDownstreamEnvironment $candidate) { Save-BraWslDistroSelection -SuiteRoot $SuiteRoot -Distro $candidate; return $candidate }
        }
    }

    foreach ($candidate in @($ordered)) {
        if (Test-BraWslDistroRunnable $candidate) { Save-BraWslDistroSelection -SuiteRoot $SuiteRoot -Distro $candidate; return $candidate }
    }
    return ''
}
