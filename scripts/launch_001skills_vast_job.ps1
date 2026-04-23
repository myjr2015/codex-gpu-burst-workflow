param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [Parameter(Mandatory = $true)]
    [string]$OfferId,

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [string]$Label = "001skills-job",

    [int]$DiskGb = 180,

    [switch]$CancelUnavail,

    [switch]$PrewarmedImage,

    [string[]]$MountArgs = @()
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$jobDir = Join-Path $repoRoot ("output\001skills\" + $JobName)
$manifestPath = Join-Path $jobDir "manifest.json"
$onstartPath = Join-Path $jobDir "onstart_001skills.sh"
$generator = Join-Path $repoRoot "scripts\generate_001skills_onstart.mjs"
$createScript = Join-Path $repoRoot "scripts\create_vast_instance_minimal.ps1"

foreach ($required in @($manifestPath, $generator, $createScript)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required file: $required"
    }
}

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
if ($PrewarmedImage) {
    $createArgs += @("-ExtraEnv", "PREWARMED_IMAGE=1")
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
Write-Host "jupyter_token=$($instance.jupyter_token)"
