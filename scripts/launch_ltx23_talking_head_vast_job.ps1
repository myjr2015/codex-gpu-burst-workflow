param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [Parameter(Mandatory = $true)]
    [string]$OfferId,

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [string]$Label = "ltx23-talking-head-smoke-job",

    [int]$DiskGb = 180,

    [switch]$CancelUnavail,

    [string[]]$ExtraEnv = @(),

    [string[]]$MountArgs = @()
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
if (Test-Path -LiteralPath $r2HelperPath) {
    . $r2HelperPath
    Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")
}

$jobDir = Join-Path $repoRoot ("output\ltx23_talking_head_smoke\" + $JobName)
$manifestPath = Join-Path $jobDir "manifest.json"
$onstartPath = Join-Path $jobDir "onstart_ltx23_talking_head.sh"
$generator = Join-Path $repoRoot "scripts\generate_ltx23_talking_head_onstart.mjs"
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
$extraEnvItems = @()
foreach ($item in $ExtraEnv) {
    foreach ($part in ([string]$item -split ",")) {
        if (-not [string]::IsNullOrWhiteSpace($part)) {
            $extraEnvItems += $part.Trim()
        }
    }
}
$hasComfyUpdateOverride = @($extraEnvItems | Where-Object { $_ -match "^LTX_UPDATE_COMFYUI=" }).Count -gt 0
$envItems = @(
    "PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu128"
)
if (-not $hasComfyUpdateOverride) {
    $envItems += "LTX_UPDATE_COMFYUI=1"
}
$envItems += $extraEnvItems

$createArgs = @(
    "-File", $createScript,
    "-OfferId", $OfferId,
    "-Image", $Image,
    "-Label", $fullLabel,
    "-DiskGb", $DiskGb,
    "-Onstart", $onstartPath,
    "-ExtraEnv", ($envItems -join ",")
)
if ($CancelUnavail) {
    $createArgs += "-CancelUnavail"
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
$previousPythonUtf8 = $env:PYTHONUTF8
$previousPythonIoEncoding = $env:PYTHONIOENCODING
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
try {
    for ($attempt = 1; $attempt -le 10; $attempt += 1) {
        $instances = vastai show instances --raw | ConvertFrom-Json
        $instance = $instances | Where-Object { $_.label -eq $fullLabel } | Sort-Object start_date -Descending | Select-Object -First 1
        if ($null -ne $instance) {
            break
        }
        Start-Sleep -Seconds 6
    }
}
finally {
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

if ($null -eq $instance) {
    throw "Instance created but could not be found by label: $fullLabel"
}

$instance | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $jobDir "vast-instance.json") -Encoding UTF8

Write-Host "instance_id=$($instance.id)"
Write-Host "host_id=$($instance.host_id)"
Write-Host "machine_id=$($instance.machine_id)"
Write-Host "driver_version=$($instance.driver_version)"
Write-Host "dph_total=$($instance.dph_total)"
Write-Host "public_ip=$($instance.public_ipaddr)"
Write-Host "jupyter_token=<redacted>"
