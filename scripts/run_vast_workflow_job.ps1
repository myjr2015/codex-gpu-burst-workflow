param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$Profile = "001skills",

    [string]$ProfileConfigPath = ".\config\vast-workflow-profiles.json",

    [string[]]$StageArgs = @(),

    [string[]]$LaunchArgs = @(),

    [string[]]$DownloadArgs = @(),

    [string[]]$PublishArgs = @(),

    [switch]$SkipStage,

    [switch]$SkipLaunch,

    [switch]$SkipDownload,

    [switch]$SkipPublish,

    [switch]$DestroyInstance,

    [switch]$SkipLogFetch,

    [int]$DownloadIntervalSeconds = 30,

    [int]$DownloadMaxChecks = 240,

    [int]$LogTail = 4000
)

$ErrorActionPreference = "Stop"

function Get-SanitizedScriptArgs {
    param(
        [string[]]$ScriptArgs = @()
    )

    $sensitiveNames = @(
        "-R2AccessKeyId",
        "-R2SecretAccessKey",
        "--access-key-id",
        "--secret-access-key",
        "-ApiKey",
        "--api-key",
        "-Token",
        "--token"
    )

    $result = @()
    for ($i = 0; $i -lt $ScriptArgs.Count; $i += 1) {
        $arg = [string]$ScriptArgs[$i]
        $result += $arg
        if ($sensitiveNames -contains $arg -and ($i + 1) -lt $ScriptArgs.Count) {
            $result += "<redacted>"
            $i += 1
        }
    }

    $result
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

    [pscustomobject]@{
        RepoRoot = $repoRoot
        JobDir = $jobDir
        ManifestPath = Join-Path $jobDir $ProfileDefinition.manifest_file
        InstancePath = Join-Path $jobDir $ProfileDefinition.instance_file
        RunReportPath = Join-Path $jobDir "run-report.json"
        TimingSummaryPath = Join-Path $jobDir "timing-summary.json"
    }
}

function Write-RunReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$Report
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $Report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-StepRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string[]]$ScriptArgs
    )

    [ordered]@{
        name = $Name
        script = $ScriptPath
        args = @(Get-SanitizedScriptArgs -ScriptArgs $ScriptArgs)
        started_at = (Get-Date).ToString("s")
        ended_at = $null
        duration_seconds = $null
        status = "running"
        output_tail = @()
    }
}

function Complete-StepRecord {
    param(
        [Parameter(Mandatory = $true)]
        $Step,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [string[]]$OutputTail = @()
    )

    $ended = Get-Date
    $started = [datetime]::Parse($Step.started_at, [System.Globalization.CultureInfo]::InvariantCulture)
    $Step.ended_at = $ended.ToString("s")
    $Step.duration_seconds = [math]::Round(($ended - $started).TotalSeconds, 3)
    $Step.status = $Status
    $Step.output_tail = @($OutputTail | Select-Object -Last 20)
}

function Invoke-PwshScriptStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string[]]$ScriptArgs
    )

    $output = & pwsh -File $ScriptPath @ScriptArgs 2>&1
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output | ForEach-Object { "$_" })
    }
}

function Get-InstanceMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstancePath
    )

    if (-not (Test-Path -LiteralPath $InstancePath)) {
        return $null
    }
    Get-Content -Raw $InstancePath | ConvertFrom-Json
}

$profileInfo = Get-ProfileDefinition -Profile $Profile -ProfileConfigPath $ProfileConfigPath
$profileDef = $profileInfo.Definition
$paths = Get-JobPaths -ProfileDefinition $profileDef -JobName $JobName

$resolvedStageScript = Join-Path $paths.RepoRoot $profileDef.stage_script
$resolvedLaunchScript = Join-Path $paths.RepoRoot $profileDef.launch_script
$resolvedDownloadScript = Join-Path $paths.RepoRoot $profileDef.download_script
$resolvedPublishScript = Join-Path $paths.RepoRoot $profileDef.publish_script
$resolvedDestroyScript = Join-Path $paths.RepoRoot $profileDef.destroy_script
$resolvedTimingScript = Join-Path $paths.RepoRoot "scripts\summarize_vast_job_timing.ps1"

$report = [ordered]@{
    profile = $Profile
    job_name = $JobName
    profile_config = $profileInfo.ConfigPath
    started_at = (Get-Date).ToString("s")
    status = "running"
    steps = @()
    warnings = @()
}

Write-RunReport -Path $paths.RunReportPath -Report $report

$instance = $null

try {
    if (-not $SkipStage) {
        $step = New-StepRecord -Name "stage" -ScriptPath $resolvedStageScript -ScriptArgs (@("-JobName", $JobName) + $StageArgs)
        $report.steps += $step
        $stepIndex = $report.steps.Count - 1
        Write-RunReport -Path $paths.RunReportPath -Report $report

        $result = Invoke-PwshScriptStep -ScriptPath $resolvedStageScript -ScriptArgs (@("-JobName", $JobName) + $StageArgs)
        if ($result.ExitCode -ne 0) {
            Complete-StepRecord -Step $step -Status "failed" -OutputTail $result.Output
            $report.steps[$stepIndex] = $step
            throw "Stage step failed."
        }
        Complete-StepRecord -Step $step -Status "succeeded" -OutputTail $result.Output
        $report.steps[$stepIndex] = $step
        Write-RunReport -Path $paths.RunReportPath -Report $report
    }

    if (-not $SkipLaunch) {
        $step = New-StepRecord -Name "launch" -ScriptPath $resolvedLaunchScript -ScriptArgs (@("-JobName", $JobName) + $LaunchArgs)
        $report.steps += $step
        $stepIndex = $report.steps.Count - 1
        Write-RunReport -Path $paths.RunReportPath -Report $report

        $result = Invoke-PwshScriptStep -ScriptPath $resolvedLaunchScript -ScriptArgs (@("-JobName", $JobName) + $LaunchArgs)
        if ($result.ExitCode -ne 0) {
            Complete-StepRecord -Step $step -Status "failed" -OutputTail $result.Output
            $report.steps[$stepIndex] = $step
            throw "Launch step failed."
        }
        Complete-StepRecord -Step $step -Status "succeeded" -OutputTail $result.Output
        $report.steps[$stepIndex] = $step
        Write-RunReport -Path $paths.RunReportPath -Report $report
    }

    $instance = Get-InstanceMetadata -InstancePath $paths.InstancePath
    if ($instance) {
        $report.instance_id = $instance.id
        $report.public_ip = $instance.public_ipaddr
    }
    Write-RunReport -Path $paths.RunReportPath -Report $report

    if (-not $SkipDownload) {
        $downloadStepArgs = @(
            "-JobName", $JobName,
            "-Wait",
            "-IntervalSeconds", $DownloadIntervalSeconds.ToString(),
            "-MaxChecks", $DownloadMaxChecks.ToString()
        ) + $DownloadArgs

        $step = New-StepRecord -Name "download" -ScriptPath $resolvedDownloadScript -ScriptArgs $downloadStepArgs
        $report.steps += $step
        $stepIndex = $report.steps.Count - 1
        Write-RunReport -Path $paths.RunReportPath -Report $report

        $result = Invoke-PwshScriptStep -ScriptPath $resolvedDownloadScript -ScriptArgs $downloadStepArgs
        if ($result.ExitCode -ne 0) {
            Complete-StepRecord -Step $step -Status "failed" -OutputTail $result.Output
            $report.steps[$stepIndex] = $step
            throw "Download step failed."
        }
        Complete-StepRecord -Step $step -Status "succeeded" -OutputTail $result.Output
        $report.steps[$stepIndex] = $step
        Write-RunReport -Path $paths.RunReportPath -Report $report
    }

    $instance = Get-InstanceMetadata -InstancePath $paths.InstancePath
    if (-not $SkipLogFetch -and $instance -and $instance.id) {
        $logStep = [ordered]@{
            name = "fetch_logs"
            started_at = (Get-Date).ToString("s")
            status = "running"
        }
        $report.steps += $logStep
        $stepIndex = $report.steps.Count - 1
        Write-RunReport -Path $paths.RunReportPath -Report $report

        $logPath = Join-Path $paths.JobDir ("vast-{0}.log" -f $instance.id)
        $logOutput = & vastai logs $instance.id --tail $LogTail 2>&1
        if ($LASTEXITCODE -ne 0) {
            Complete-StepRecord -Step $logStep -Status "failed" -OutputTail @($logOutput | ForEach-Object { "$_" })
            $report.steps[$stepIndex] = $logStep
            throw "Log fetch step failed."
        }
        ($logOutput | Out-String) | Set-Content -LiteralPath $logPath -Encoding UTF8
        Complete-StepRecord -Step $logStep -Status "succeeded" -OutputTail @("saved_log=$logPath")
        $report.steps[$stepIndex] = $logStep
        Write-RunReport -Path $paths.RunReportPath -Report $report

        $timingStep = New-StepRecord -Name "summarize_timings" -ScriptPath $resolvedTimingScript -ScriptArgs @(
            "-Profile", $Profile,
            "-JobName", $JobName,
            "-ProfileConfigPath", $profileInfo.ConfigPath,
            "-LogPath", $logPath,
            "-OutputPath", $paths.TimingSummaryPath
        )
        $report.steps += $timingStep
        $stepIndex = $report.steps.Count - 1
        Write-RunReport -Path $paths.RunReportPath -Report $report

        $timingResult = Invoke-PwshScriptStep -ScriptPath $resolvedTimingScript -ScriptArgs @(
            "-Profile", $Profile,
            "-JobName", $JobName,
            "-ProfileConfigPath", $profileInfo.ConfigPath,
            "-LogPath", $logPath,
            "-OutputPath", $paths.TimingSummaryPath
        )
        if ($timingResult.ExitCode -ne 0) {
            Complete-StepRecord -Step $timingStep -Status "failed" -OutputTail $timingResult.Output
            $report.steps[$stepIndex] = $timingStep
            throw "Timing summary step failed."
        }
        Complete-StepRecord -Step $timingStep -Status "succeeded" -OutputTail $timingResult.Output
        $report.steps[$stepIndex] = $timingStep
        Write-RunReport -Path $paths.RunReportPath -Report $report
    }

    if (-not $SkipPublish) {
        $step = New-StepRecord -Name "publish" -ScriptPath $resolvedPublishScript -ScriptArgs (@("-JobName", $JobName) + $PublishArgs)
        $report.steps += $step
        $stepIndex = $report.steps.Count - 1
        Write-RunReport -Path $paths.RunReportPath -Report $report

        $result = Invoke-PwshScriptStep -ScriptPath $resolvedPublishScript -ScriptArgs (@("-JobName", $JobName) + $PublishArgs)
        if ($result.ExitCode -ne 0) {
            Complete-StepRecord -Step $step -Status "failed" -OutputTail $result.Output
            $report.steps[$stepIndex] = $step
            throw "Publish step failed."
        }
        Complete-StepRecord -Step $step -Status "succeeded" -OutputTail $result.Output
        $report.steps[$stepIndex] = $step
        Write-RunReport -Path $paths.RunReportPath -Report $report
    }

    if ($DestroyInstance) {
        $instance = Get-InstanceMetadata -InstancePath $paths.InstancePath
        if ($instance -and $instance.id) {
            $step = New-StepRecord -Name "destroy" -ScriptPath $resolvedDestroyScript -ScriptArgs @("-InstanceId", "$($instance.id)")
            $report.steps += $step
            $stepIndex = $report.steps.Count - 1
            Write-RunReport -Path $paths.RunReportPath -Report $report

            $result = Invoke-PwshScriptStep -ScriptPath $resolvedDestroyScript -ScriptArgs @("-InstanceId", "$($instance.id)")
            if ($result.ExitCode -ne 0) {
                Complete-StepRecord -Step $step -Status "failed" -OutputTail $result.Output
                $report.steps[$stepIndex] = $step
                throw "Destroy step failed."
            }
            Complete-StepRecord -Step $step -Status "succeeded" -OutputTail $result.Output
            $report.steps[$stepIndex] = $step
            Write-RunReport -Path $paths.RunReportPath -Report $report
        } else {
            $report.warnings += "DestroyInstance requested but instance metadata was unavailable."
        }
    }

    $report.status = "succeeded"
}
catch {
    $report.status = "failed"
    $report.error = $_.Exception.Message
    throw
}
finally {
    $report.ended_at = (Get-Date).ToString("s")
    Write-RunReport -Path $paths.RunReportPath -Report $report
}

Write-Host "run_report=$($paths.RunReportPath)"
if (Test-Path -LiteralPath $paths.TimingSummaryPath) {
    Write-Host "timing_summary=$($paths.TimingSummaryPath)"
}
if (Test-Path -LiteralPath $paths.ManifestPath) {
    $manifest = Get-Content -Raw $paths.ManifestPath | ConvertFrom-Json
    if ($manifest.result -and $manifest.result.local_result_path) {
        Write-Host "local_result=$($manifest.result.local_result_path)"
    }
    if ($manifest.published_result -and $manifest.published_result.public_url) {
        Write-Host "public_url=$($manifest.published_result.public_url)"
    }
}
