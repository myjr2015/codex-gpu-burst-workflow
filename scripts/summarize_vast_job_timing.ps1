param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$Profile = "001skills",

    [string]$ProfileConfigPath = ".\config\vast-workflow-profiles.json",

    [string]$LogPath,

    [string]$OutputPath,

    [switch]$FetchLog,

    [int]$LogTail = 4000
)

$ErrorActionPreference = "Stop"

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
    foreach ($line in $Lines) {
        if ($line -match '^\[stage\]\s+(?<ts>\S+)\s+(?<name>\S+)\s+(?<status>start|end|skip)$') {
            $events += [pscustomobject]@{
                source = "stage_marker"
                stage = $matches.name
                status = $matches.status
                timestamp = $matches.ts
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
                line = $line
            }
            continue
        }
    }

    $events
}

function Build-StageSummary {
    param(
        [Parameter(Mandatory = $true)]
        $Events
    )

    $openStages = @{}
    $summary = @()
    $warnings = @()

    foreach ($event in $Events | Sort-Object timestamp) {
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
    $rawLog = & vastai logs $instance.id --tail $LogTail 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch Vast logs for instance $($instance.id): $($rawLog | Out-String)"
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
$events = Get-StageEventsFromLog -Lines $lines
$stageSummary = Build-StageSummary -Events $events

$promptExecution = $null
foreach ($line in $lines) {
    if ($line -match '^Prompt executed in\s+(?<duration>\S+)$') {
        $promptExecution = $matches.duration
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
    lifecycle = $lifeCycle
    stages = @($stageSummary.Stages)
    warnings = @($stageSummary.Warnings)
}

$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "timing_summary=$OutputPath"
Write-Host "markers_found=$($events.Count)"
