param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$Profile = "wan_2_2_animate",

    [string]$ProfileConfigPath = ".\config\vast-workflow-profiles.json",

    [int]$IntervalSeconds = 20,

    [int]$MaxChecks = 60,

    [int]$LogTail = 80
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

    $config.profiles[$Profile]
}

function Get-JobPaths {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ProfileDefinition,

        [Parameter(Mandatory = $true)]
        [string]$JobName
    )

    $repoRoot = (Resolve-Path ".").Path
    $jobDir = Join-Path (Join-Path $repoRoot $ProfileDefinition.job_root) $JobName
    if (-not (Test-Path -LiteralPath $jobDir)) {
        throw "Missing job directory: $jobDir"
    }

    [pscustomobject]@{
        JobDir = $jobDir
        ManifestPath = Join-Path $jobDir $ProfileDefinition.manifest_file
        InstancePath = Join-Path $jobDir $ProfileDefinition.instance_file
        RunReportPath = Join-Path $jobDir "run-report.json"
        TimingSummaryPath = Join-Path $jobDir "timing-summary.json"
        HistoryApiPath = Join-Path $jobDir "history.api.json"
    }
}

function Get-RelevantLogLines {
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines = @()
    )

    if (-not $Lines -or $Lines.Count -eq 0) {
        return @()
    }

    $patterns = @(
        '^\[onstart\]'
        '^\[onstart-ltx23\]'
        '^\[remote-run\]'
        '^\[remote-ltx23\]'
        '^\[remote-kj30s\]'
        '^\[hf-speedtest\]'
        '^\[bootstrap\]'
        '^\[bootstrap-ltx23\]'
        '^\[stage\]'
        '^Prompt executed in'
        'history-ready'
        'execution_success'
        '\d+%\|'
        'Downloading '
        'Installing collected packages'
        'Successfully installed'
        'cudaGetDeviceCount Error 804'
        'ModuleNotFoundError'
        'curl: \('
    )

    $Lines |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Where-Object {
            $line = $_
            foreach ($pattern in $patterns) {
                if ($line -match $pattern) {
                    return $true
                }
            }
            return $false
        } |
        Select-Object -Last 20
}

function Get-SanitizedVastText {
    param(
        [AllowEmptyString()]
        [string]$Text = ""
    )

    $Text -replace 'api_key=[^&\s]+', 'api_key=<redacted>'
}

$profileDef = Get-ProfileDefinition -Profile $Profile -ProfileConfigPath $ProfileConfigPath
$paths = Get-JobPaths -ProfileDefinition $profileDef -JobName $JobName
$instanceMeta = Get-Content -Raw $paths.InstancePath | ConvertFrom-Json
$instanceId = $instanceMeta.id

for ($check = 1; $check -le $MaxChecks; $check += 1) {
    $now = Get-Date -Format s
    $instanceWarning = $null
    $instanceRaw = @(& vastai show instance $instanceId --raw 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -eq 0) {
        try {
            $instance = ($instanceRaw | Out-String) | ConvertFrom-Json
        }
        catch {
            $instance = $instanceMeta
            $instanceWarning = "vast show instance returned non-JSON output: $(Get-SanitizedVastText -Text (($instanceRaw | Select-Object -Last 3) -join ' '))"
        }
    }
    else {
        $instance = $instanceMeta
        $instanceWarning = "vast show instance failed: $(Get-SanitizedVastText -Text (($instanceRaw | Select-Object -Last 3) -join ' '))"
    }

    $rawLog = @(& vastai logs $instanceId --tail $LogTail 2>&1 | ForEach-Object { Get-SanitizedVastText -Text "$_" })
    if ($LASTEXITCODE -ne 0) {
        $rawLog = @("vast logs failed: $((($rawLog | Select-Object -Last 3) -join ' '))")
    }
    $relevantLines = Get-RelevantLogLines -Lines $rawLog

    $runReport = $null
    if (Test-Path -LiteralPath $paths.RunReportPath) {
        $runReport = Get-Content -Raw $paths.RunReportPath | ConvertFrom-Json
    }

    $latestStep = $null
    if ($runReport -and $runReport.steps -and $runReport.steps.Count -gt 0) {
        $latestStep = $runReport.steps[-1]
    }

    $port8188 = $null
    if ($instance.ports -and $instance.ports.'8188/tcp') {
        $port8188 = $instance.ports.'8188/tcp'[0].HostPort
    }

    Write-Host ""
    Write-Host "[$now] check=$check job=$JobName"
    Write-Host "1. instance_id=$instanceId actual_status=$($instance.actual_status) cur_state=$($instance.cur_state) status_msg=$($instance.status_msg)"
    Write-Host "2. host=$($instance.host_id) machine=$($instance.machine_id) driver=$($instance.driver_version) public_ip=$($instance.public_ipaddr) port8188=$port8188"
    if ($instanceWarning) {
        Write-Host "   warning=$instanceWarning"
    }
    if ($latestStep) {
        Write-Host "3. latest_step=$($latestStep.name) status=$($latestStep.status) started_at=$($latestStep.started_at)"
    } else {
        Write-Host "3. latest_step=<none>"
    }
    if (Test-Path -LiteralPath $paths.TimingSummaryPath) {
        Write-Host "4. timing_summary=ready"
    } else {
        Write-Host "4. timing_summary=not_ready"
    }
    Write-Host "5. recent_logs:"
    if ($relevantLines.Count -eq 0) {
        Write-Host "   <no relevant log lines yet>"
    } else {
        foreach ($line in $relevantLines) {
            Write-Host "   $line"
        }
    }

    if ($runReport -and $runReport.status -in @("succeeded", "failed")) {
        break
    }

    if ($check -lt $MaxChecks) {
        Start-Sleep -Seconds $IntervalSeconds
    }
}
