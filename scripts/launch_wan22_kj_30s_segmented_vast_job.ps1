param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [Parameter(Mandatory = $true)]
    [string]$OfferId,

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [string]$TemplateHash = "",

    [string]$Label = "wan22-kj-30s-segmented-job",

    [int]$DiskGb = 240,

    [switch]$CancelUnavail,

    [switch]$WarmStart,

    [switch]$DisableHfSpeedTest,

    [double]$HfMinMiBps = 15,

    [int]$HfMaxEstimatedDownloadMinutes = 30,

    [int]$HfSpeedTestSampleMiB = 256,

    [int]$HfSpeedTestMaxSeconds = 120,

    [ValidateRange(1, 4)]
    [int]$ModelDownloadParallelism = 3,

    [string[]]$MountArgs = @()
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$jobDir = Join-Path $repoRoot ("output\wan22_kj_30s_segmented\" + $JobName)
$manifestPath = Join-Path $jobDir "manifest.json"
$onstartPath = Join-Path $jobDir "onstart_wan22_kj_30s_segmented.sh"
$generator = Join-Path $repoRoot "scripts\generate_wan22_kj_30s_segmented_onstart.mjs"
$createScript = Join-Path $repoRoot "scripts\create_vast_instance_minimal.ps1"
$helpersPath = Join-Path $repoRoot "scripts\launch_wan_2_2_animate_vast_job_helpers.ps1"

foreach ($required in @($manifestPath, $generator, $createScript, $helpersPath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required file: $required"
    }
}

. $helpersPath

& node $generator --manifest $manifestPath --output $onstartPath
if ($LASTEXITCODE -ne 0) {
    throw "Failed to generate KJ segmented onstart script."
}

$fullLabel = "$Label-$JobName"
$createArgs = @(
    "-File", $createScript,
    "-OfferId", $OfferId,
    "-Image", $Image,
    "-Label", $fullLabel,
    "-DiskGb", "$DiskGb",
    "-Onstart", $onstartPath
)
if (-not [string]::IsNullOrWhiteSpace($TemplateHash)) {
    $createArgs += @("-TemplateHash", $TemplateHash, "-TemplateProvidesStaticEnv")
}
if ($CancelUnavail) {
    $createArgs += "-CancelUnavail"
}
$extraEnvItems = @()
foreach ($extraEnv in (Get-Wan22AnimateLaunchExtraEnv -WarmStart:$WarmStart)) {
    $extraEnvItems += $extraEnv
}
if (-not $DisableHfSpeedTest) {
    $extraEnvItems += "HF_SPEEDTEST=1"
    $extraEnvItems += ("HF_MIN_MIB_PER_SEC={0}" -f $HfMinMiBps)
    $extraEnvItems += ("HF_MAX_ESTIMATED_DOWNLOAD_MINUTES={0}" -f $HfMaxEstimatedDownloadMinutes)
    $extraEnvItems += ("HF_SPEEDTEST_SAMPLE_MIB={0}" -f $HfSpeedTestSampleMiB)
    $extraEnvItems += ("HF_SPEEDTEST_MAX_SECONDS={0}" -f $HfSpeedTestMaxSeconds)
}
$extraEnvItems += ("KJ_MODEL_DOWNLOAD_PARALLELISM={0}" -f $ModelDownloadParallelism)
if ($extraEnvItems.Count -gt 0) {
    $createArgs += @("-ExtraEnv", ($extraEnvItems -join ","))
}
if ($MountArgs.Count -gt 0) {
    $createArgs += @("-MountArgs", $MountArgs)
}

$raw = & pwsh @createArgs
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create Vast instance."
}

$jsonText = ($raw | Out-String).Trim()
$jsonText | Set-Content -LiteralPath (Join-Path $jobDir "vast-create-response.json") -Encoding UTF8

Start-Sleep -Seconds 3
$instance = $null
for ($attempt = 1; $attempt -le 20; $attempt += 1) {
    $previousPythonIoEncoding = $env:PYTHONIOENCODING
    $env:PYTHONIOENCODING = "utf-8"
    try {
        $instances = vastai show instances --raw | ConvertFrom-Json
    }
    finally {
        if ($null -eq $previousPythonIoEncoding) {
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONIOENCODING = $previousPythonIoEncoding
        }
    }
    $instance = $instances | Where-Object { $_.label -eq $fullLabel } | Sort-Object start_date -Descending | Select-Object -First 1
    if ($null -ne $instance) {
        break
    }
    Start-Sleep -Seconds 6
}
if ($null -eq $instance) {
    throw "Instance created but could not be found by label: $fullLabel"
}

$safeInstance = $instance | Select-Object * -ExcludeProperty @("instance_api_key", "jupyter_token", "onstart", "ssh_key", "extra_env")
$safeInstance | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $jobDir "vast-instance.json") -Encoding UTF8

Write-Host "instance_id=$($safeInstance.id)"
Write-Host "public_ip=$($safeInstance.public_ipaddr)"
Write-Host "host_id=$($safeInstance.host_id)"
Write-Host "machine_id=$($safeInstance.machine_id)"
Write-Host "warm_start=$([bool]$WarmStart)"
Write-Host "hf_speedtest=$(-not $DisableHfSpeedTest)"
if (-not $DisableHfSpeedTest) {
    Write-Host "hf_min_mib_per_sec=$HfMinMiBps"
    Write-Host "hf_max_estimated_download_minutes=$HfMaxEstimatedDownloadMinutes"
}
Write-Host "model_download_parallelism=$ModelDownloadParallelism"
