param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$Profile = "wan_2_2_animate",

    [string]$ProfileConfigPath = ".\config\vast-workflow-profiles.json",

    [string]$LogPath,

    [string]$OutputPath,

    [switch]$FetchLog,

    [int]$LogTail = 4000
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
if (Test-Path -LiteralPath $r2HelperPath) {
    . $r2HelperPath
    Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")
}

function Get-ProfileDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Profile,

        [Parameter(Mandatory = $true)]
        [string]$ProfileConfigPath
    )

    $resolvedPath = (Resolve-Path -LiteralPath $ProfileConfigPath).Path
    $config = Get-Content -Raw $resolvedPath | ConvertFrom-Json -AsHashtable
    if (-not $config.profiles.ContainsKey($Profile)) {
        throw "Unknown profile '$Profile' in $resolvedPath"
    }

    [pscustomobject]@{
        ConfigPath = $resolvedPath
        Definition = $config.profiles[$Profile]
    }
}

function Get-JobPaths {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ProfileDefinition,

        [Parameter(Mandatory = $true)]
        [string]$JobName
    )

    $repoRoot = (Resolve-Path ".").Path
    $jobRoot = Join-Path $repoRoot $ProfileDefinition.job_root
    $jobDir = Join-Path $jobRoot $JobName
    if (-not (Test-Path -LiteralPath $jobDir)) {
        throw "Missing job directory: $jobDir"
    }

    [pscustomobject]@{
        RepoRoot = $repoRoot
        JobDir = $jobDir
        ManifestPath = Join-Path $jobDir $ProfileDefinition.manifest_file
        InstancePath = Join-Path $jobDir $ProfileDefinition.instance_file
        RunReportPath = Join-Path $jobDir "run-report.json"
        HistoryApiPath = Join-Path $jobDir "history.api.json"
        DefaultOutputPath = Join-Path $jobDir "timing-summary.json"
    }
}

function Parse-IsoTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    [datetimeoffset]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-IsoDurationSeconds {
    param(
        [datetimeoffset]$Start,
        [datetimeoffset]$End
    )

    if ($null -eq $Start -or $null -eq $End) {
        return $null
    }

    [math]::Round(($End - $Start).TotalSeconds, 3)
}

function Get-StageEventsFromLog {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines
    )

    $events = @()
    $lineIndex = 0
    foreach ($line in $Lines) {
        $lineIndex += 1
        if ($line -match '^\[stage\]\s+(?<ts>\S+)\s+(?<name>\S+)\s+(?<status>start|end|skip)$') {
            $events += [pscustomobject]@{
                source = "stage_marker"
                stage = $matches.name
                status = $matches.status
                timestamp = $matches.ts
                sequence = $lineIndex
                line = $line
            }
            continue
        }

        if ($line -match '^\[onstart\]\s+started at\s+(?<ts>\S+)$') {
            $events += [pscustomobject]@{
                source = "log_line"
                stage = "onstart.lifecycle"
                status = "start"
                timestamp = $matches.ts
                sequence = $lineIndex
                line = $line
            }
            continue
        }

        if ($line -match '^\[onstart\]\s+finished at\s+(?<ts>\S+)$') {
            $events += [pscustomobject]@{
                source = "log_line"
                stage = "onstart.lifecycle"
                status = "end"
                timestamp = $matches.ts
                sequence = $lineIndex
                line = $line
            }
            continue
        }

        if ($line -match '^\[remote-run\]\s+started at\s+(?<ts>\S+)$') {
            $events += [pscustomobject]@{
                source = "log_line"
                stage = "remote.lifecycle"
                status = "start"
                timestamp = $matches.ts
                sequence = $lineIndex
                line = $line
            }
            continue
        }

        if ($line -match '^\[remote-run\]\s+finished at\s+(?<ts>\S+)$') {
            $events += [pscustomobject]@{
                source = "log_line"
                stage = "remote.lifecycle"
                status = "end"
                timestamp = $matches.ts
                sequence = $lineIndex
                line = $line
            }
            continue
        }
    }

    $events
}

function Get-PromptExecutionFromHistory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HistoryApiPath
    )

    if (-not (Test-Path -LiteralPath $HistoryApiPath)) {
        return $null
    }

    $history = Get-Content -Raw $HistoryApiPath | ConvertFrom-Json
    foreach ($entryProperty in $history.PSObject.Properties) {
        $startMs = $null
        $endMs = $null
        $entry = $entryProperty.Value
        if (-not $entry.status -or -not $entry.status.messages) {
            continue
        }

        foreach ($message in $entry.status.messages) {
            if ($message.Count -lt 2 -or -not $message[1].timestamp) {
                continue
            }

            $timestamp = [int64]$message[1].timestamp
            if ($message[0] -eq "execution_start") {
                $startMs = $timestamp
            }
            elseif ($message[0] -eq "execution_success") {
                $endMs = $timestamp
            }
        }

        if ($startMs -and $endMs -and $endMs -ge $startMs) {
            $seconds = [math]::Round(($endMs - $startMs) / 1000, 3)
            return [pscustomobject]@{
                prompt_id = $entryProperty.Name
                seconds = $seconds
                duration = ([timespan]::FromSeconds($seconds)).ToString("c")
                source = "history_api"
            }
        }
    }

    $null
}

function Build-StageSummary {
    param(
        $Events = @()
    )

    if ($null -eq $Events) {
        $Events = @()
    }

    $openStages = @{}
    $summary = @()
    $warnings = @()

    foreach ($event in $Events | Sort-Object timestamp, sequence) {
        $stageName = [string]$event.stage
        $eventTime = Parse-IsoTimestamp $event.timestamp

        if ($event.status -eq "skip") {
            $summary += [pscustomobject]@{
                stage = $stageName
                status = "skipped"
                start = $event.timestamp
                end = $event.timestamp
                duration_seconds = 0
                source = $event.source
            }
            continue
        }

        if ($event.status -eq "start") {
            $openStages[$stageName] = $eventTime
            continue
        }

        if ($event.status -eq "end") {
            if (-not $openStages.ContainsKey($stageName)) {
                $warnings += "Missing start marker for stage '$stageName'"
                $summary += [pscustomobject]@{
                    stage = $stageName
                    status = "ended_without_start"
                    start = $null
                    end = $event.timestamp
                    duration_seconds = $null
                    source = $event.source
                }
                continue
            }

            $startTime = [datetimeoffset]$openStages[$stageName]
            $openStages.Remove($stageName) | Out-Null
            $summary += [pscustomobject]@{
                stage = $stageName
                status = "completed"
                start = $startTime.ToString("o")
                end = $eventTime.ToString("o")
                duration_seconds = Get-IsoDurationSeconds -Start $startTime -End $eventTime
                source = $event.source
            }
        }
    }

    foreach ($pending in $openStages.GetEnumerator() | Sort-Object Name) {
        $warnings += "Stage '$($pending.Name)' has a start marker but no end marker"
        $summary += [pscustomobject]@{
            stage = $pending.Name
            status = "open"
            start = ([datetimeoffset]$pending.Value).ToString("o")
            end = $null
            duration_seconds = $null
            source = "stage_marker"
        }
    }

    [pscustomobject]@{
        Stages = $summary
        Warnings = $warnings
    }
}

$profileInfo = Get-ProfileDefinition -Profile $Profile -ProfileConfigPath $ProfileConfigPath
$paths = Get-JobPaths -ProfileDefinition $profileInfo.Definition -JobName $JobName

$manifest = @{}
if (Test-Path -LiteralPath $paths.ManifestPath) {
    $manifest = Get-Content -Raw $paths.ManifestPath | ConvertFrom-Json -AsHashtable
}

$instance = $null
if (Test-Path -LiteralPath $paths.InstancePath) {
    $instance = Get-Content -Raw $paths.InstancePath | ConvertFrom-Json
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    if ($instance -and $instance.id) {
        $LogPath = Join-Path $paths.JobDir ("vast-{0}.log" -f $instance.id)
    } else {
        throw "LogPath not provided and instance metadata does not contain an id."
    }
}

if ($FetchLog) {
    if (-not $instance -or -not $instance.id) {
        throw "FetchLog requires a valid instance id."
    }
    $previousPythonUtf8 = $env:PYTHONUTF8
    $previousPythonIoEncoding = $env:PYTHONIOENCODING
    $previousConsoleOutputEncoding = [Console]::OutputEncoding
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    try {
        $rawLog = @(& vastai logs $instance.id --tail $LogTail 2>&1 | ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to fetch Vast logs for instance $($instance.id): $($rawLog | Out-String)"
        }
    }
    finally {
        [Console]::OutputEncoding = $previousConsoleOutputEncoding
        if ($null -eq $previousPythonUtf8) {
            Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONUTF8 = $previousPythonUtf8
        }
        if ($null -eq $previousPythonIoEncoding) {
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONIOENCODING = $previousPythonIoEncoding
        }
    }
    ($rawLog | Out-String) | Set-Content -LiteralPath $LogPath -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $LogPath)) {
    throw "Missing log file: $LogPath"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = $paths.DefaultOutputPath
}

$logText = Get-Content -LiteralPath $LogPath -Raw
$lines = @()
if (-not [string]::IsNullOrWhiteSpace($logText)) {
    $lines = @($logText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
$events = @(Get-StageEventsFromLog -Lines $lines)
$stageSummary = Build-StageSummary -Events $events

$promptExecution = $null
$promptExecutionSeconds = $null
$promptExecutionSource = $null
foreach ($line in $lines) {
    if ($line -match '^Prompt executed in\s+(?<duration>\S+)$') {
        $promptExecution = $matches.duration
        $promptExecutionSource = "log"
    }
}

if ($null -eq $promptExecution) {
    $historyTiming = Get-PromptExecutionFromHistory -HistoryApiPath $paths.HistoryApiPath
    if ($historyTiming) {
        $promptExecution = $historyTiming.duration
        $promptExecutionSeconds = $historyTiming.seconds
        $promptExecutionSource = $historyTiming.source
    }
}

$lifeCycle = [ordered]@{}
if ($manifest.ContainsKey("created_at")) {
    $lifeCycle.created_at = $manifest.created_at
}
if ($instance -and $instance.start_date) {
    $lifeCycle.instance_started_at = ([datetimeoffset]::FromUnixTimeSeconds([int64][math]::Floor($instance.start_date))).ToString("o")
}
if ($manifest.ContainsKey("result") -and $manifest.result.downloaded_at) {
    $lifeCycle.result_downloaded_at = $manifest.result.downloaded_at
}
if ($manifest.ContainsKey("published_result") -and $manifest.published_result.uploaded_at) {
    $lifeCycle.result_published_at = $manifest.published_result.uploaded_at
}

if ($lifeCycle.created_at -and $lifeCycle.result_downloaded_at) {
    $lifeCycle.total_until_download_seconds = Get-IsoDurationSeconds `
        -Start (Parse-IsoTimestamp $lifeCycle.created_at) `
        -End (Parse-IsoTimestamp $lifeCycle.result_downloaded_at)
}
if ($lifeCycle.created_at -and $lifeCycle.result_published_at) {
    $lifeCycle.total_until_publish_seconds = Get-IsoDurationSeconds `
        -Start (Parse-IsoTimestamp $lifeCycle.created_at) `
        -End (Parse-IsoTimestamp $lifeCycle.result_published_at)
}

$resolvedLogPath = (Resolve-Path -LiteralPath $LogPath).Path
$instanceId = $null
if ($instance) {
    $instanceId = $instance.id
}

$result = [ordered]@{
    profile = $Profile
    job_name = $JobName
    generated_at = (Get-Date).ToString("s")
    profile_config = $profileInfo.ConfigPath
    log_path = $resolvedLogPath
    instance_id = $instanceId
    markers_found = $events.Count
    prompt_execution = $promptExecution
    prompt_execution_seconds = $promptExecutionSeconds
    prompt_execution_source = $promptExecutionSource
    lifecycle = $lifeCycle
    stages = @($stageSummary.Stages)
    warnings = @($stageSummary.Warnings)
}

$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "timing_summary=$OutputPath"
Write-Host "markers_found=$($events.Count)"
