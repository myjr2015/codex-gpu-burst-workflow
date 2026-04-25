param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [Parameter(Mandatory = $true)]
    [string]$OfferId,

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [string]$Label = "wan_2_2_animate-job",

    [int]$DiskGb = 180,

    [switch]$CancelUnavail,

    [switch]$WarmStart,

    [string[]]$MountArgs = @()
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$jobDir = Join-Path $repoRoot ("output\wan_2_2_animate\" + $JobName)
$manifestPath = Join-Path $jobDir "manifest.json"
$onstartPath = Join-Path $jobDir "onstart_wan_2_2_animate.sh"
$generator = Join-Path $repoRoot "scripts\generate_wan_2_2_animate_onstart.mjs"
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
    throw "Failed to generate onstart script."
}

$fullLabel = "$Label-$JobName"
$createArgs = @(
    "-File", $createScript,
    "-OfferId", $OfferId,
    "-Image", $Image,
    "-Label", $fullLabel,
    "-DiskGb", $DiskGb,
    "-Onstart", $onstartPath
)
if ($CancelUnavail) {
    $createArgs += "-CancelUnavail"
}
foreach ($extraEnv in (Get-Wan22AnimateLaunchExtraEnv -WarmStart:$WarmStart)) {
    $createArgs += @("-ExtraEnv", $extraEnv)
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
for ($attempt = 1; $attempt -le 10; $attempt += 1) {
    $instances = vastai show instances --raw | ConvertFrom-Json
    $instance = $instances | Where-Object { $_.label -eq $fullLabel } | Sort-Object start_date -Descending | Select-Object -First 1
    if ($null -ne $instance) {
        break
    }
    Start-Sleep -Seconds 6
}
if ($null -eq $instance) {
    throw "Instance created but could not be found by label: $fullLabel"
}

$instance | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $jobDir "vast-instance.json") -Encoding UTF8

Write-Host "instance_id=$($instance.id)"
Write-Host "public_ip=$($instance.public_ipaddr)"
Write-Host "jupyter_token=<redacted>"
