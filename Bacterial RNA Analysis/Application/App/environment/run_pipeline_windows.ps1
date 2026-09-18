param(
    [Parameter(Mandatory = $true)]
    [string]$RequestPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$request = $null

function Write-Utf8Line {
    param([string]$Path, [string]$Text)
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        [void][System.IO.Directory]::CreateDirectory($directory)
    }
    [System.IO.File]::AppendAllText(
        $Path,
        $Text + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Format-NativeRecord {
    param($Record)
    if ($null -eq $Record) { return '' }
    if ($Record -is [System.Management.Automation.ErrorRecord]) {
        $message = [string]$Record.Exception.Message
        if (-not [string]::IsNullOrWhiteSpace($message)) { return $message }
    }
    return [string]$Record
}

try {
    if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
        throw "Runner request file does not exist: $RequestPath"
    }
    $request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $pipelineLog = [string]$request.pipeline_log
    $launcherLog = [string]$request.launcher_log
    $distro = [string]$request.distro
    $linuxSupervisor = [string]$request.linux_supervisor
    $jobToken = [string]$request.job_token
    $linuxScript = [string]$request.linux_script
    $linuxConfig = [string]$request.linux_config
    $dryRun = [bool]$request.dry_run

    if ([string]::IsNullOrWhiteSpace($pipelineLog)) { throw 'The pipeline log path is missing from the runner request.' }
    if ([string]::IsNullOrWhiteSpace($launcherLog)) { throw 'The launcher log path is missing from the runner request.' }
    if ([string]::IsNullOrWhiteSpace($distro)) { throw 'The WSL distribution name is missing from the runner request.' }
    if ([string]::IsNullOrWhiteSpace($linuxSupervisor)) { throw 'The Linux process supervisor path is missing from the runner request.' }
    if ([string]::IsNullOrWhiteSpace($jobToken)) { throw 'The managed job token is missing from the runner request.' }
    if ([string]::IsNullOrWhiteSpace($linuxScript)) { throw 'The Linux runner script path is missing from the runner request.' }
    if ([string]::IsNullOrWhiteSpace($linuxConfig)) { throw 'The Linux project configuration path is missing from the runner request.' }

    $wslArguments = @('-d', $distro, '-u', 'root', '--', '/bin/bash', $linuxSupervisor, $jobToken, '/bin/bash', $linuxScript, $linuxConfig)
    if ($dryRun) { $wslArguments += '--dry-run' }

    $displayArguments = @($wslArguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + $value.Replace('"', '\"') + '"' } else { $value }
    }) -join ' '

    Write-Utf8Line $pipelineLog "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] Windows runner started."
    Write-Utf8Line $pipelineLog "WSL distribution: $distro"
    Write-Utf8Line $pipelineLog "Managed Linux job token: $jobToken"
    Write-Utf8Line $pipelineLog "Linux command: wsl.exe $displayArguments"
    Write-Utf8Line $launcherLog "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] wsl.exe $displayArguments"

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $tail = New-Object System.Collections.Generic.Queue[string]
    try {
        & wsl.exe @wslArguments 2>&1 | ForEach-Object {
            $line = Format-NativeRecord $_
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Utf8Line $launcherLog $line
                $tail.Enqueue($line)
                while ($tail.Count -gt 40) { [void]$tail.Dequeue() }
            }
        }
        $nativeExitCode = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    Write-Utf8Line $launcherLog "WSL exit code: $nativeExitCode"
    if ($nativeExitCode -ne 0) {
        Write-Utf8Line $pipelineLog "ERROR: WSL pipeline launcher exited with code $nativeExitCode."
        foreach ($line in @($tail.ToArray())) { Write-Utf8Line $pipelineLog $line }
        Write-Utf8Line $pipelineLog "Detailed Windows launcher log: $launcherLog"
    }
    else {
        # A successful Linux run has already copied the full code-bearing log,
        # verified workbook, manifest, and checksums into analysis_ready. Do not
        # recreate the live runtime log after that cleanup or modify the checked
        # final log. Remove only these exact pipeline-owned runtime paths.
        $logsDirectory = Split-Path -Parent $pipelineLog
        $projectDirectory = Split-Path -Parent $logsDirectory
        $runRoot = Split-Path -Parent $projectDirectory
        $finalLog = Join-Path $runRoot 'analysis_ready\Intermediate files\Complete pipeline log.txt'
        if (Test-Path -LiteralPath $finalLog -PathType Leaf) {
            foreach ($runtimePath in @(
                $projectDirectory,
                (Join-Path $runRoot '.rnaseq_suite'),
                (Join-Path $runRoot 'rnaseq_project.json')
            )) {
                if (Test-Path -LiteralPath $runtimePath) {
                    Remove-Item -LiteralPath $runtimePath -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        else {
            Write-Utf8Line $pipelineLog "Windows runner completed successfully."
        }
    }
    exit $nativeExitCode
}
catch {
    $message = $_.Exception.ToString()
    try {
        $fallbackLog = $null
        if ($request -and $request.pipeline_log) { $fallbackLog = [string]$request.pipeline_log }
        if (-not $fallbackLog) {
            $fallbackLog = Join-Path ([System.IO.Path]::GetDirectoryName($RequestPath)) 'windows_pipeline_launcher_error.log'
        }
        Write-Utf8Line $fallbackLog "ERROR: Windows pipeline runner failed before WSL completed."
        Write-Utf8Line $fallbackLog $message
    }
    catch { }
    exit 125
}
