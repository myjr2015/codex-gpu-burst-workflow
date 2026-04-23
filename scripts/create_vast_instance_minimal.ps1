param(
    [Parameter(Mandatory = $true)]
    [string]$OfferId,

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [string]$Label = "codex-comfy-minimal",

    [int]$DiskGb = 180,

    [switch]$CancelUnavail,

    [string]$Onstart,

    [string[]]$ExtraEnv = @(),

    [string[]]$MountArgs = @()
)

$ErrorActionPreference = "Stop"

$envItems = @(
    "DATA_DIRECTORY=/workspace/"
    "JUPYTER_DIR=/"
    "OPEN_BUTTON_PORT=8188"
    "PROVISIONING_SCRIPT=https://raw.githubusercontent.com/vast-ai/base-image/refs/heads/main/derivatives/pytorch/derivatives/comfyui/provisioning_scripts/default.sh"
)
if ($ExtraEnv.Count -gt 0) {
    foreach ($item in $ExtraEnv) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }
        foreach ($part in ($item -split ",")) {
            if (-not [string]::IsNullOrWhiteSpace($part)) {
                $envItems += $part.Trim()
            }
        }
    }
}

$envParts = @($envItems | ForEach-Object { "-e $_" })
if ($MountArgs.Count -gt 0) {
    foreach ($item in $MountArgs) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }
        foreach ($part in ($item -split ",")) {
            if (-not [string]::IsNullOrWhiteSpace($part)) {
                $envParts += $part.Trim()
            }
        }
    }
}
$envParts += @(
    "-p 1111:1111"
    "-p 8080:8080"
    "-p 8188:8188"
    "-p 8384:8384"
)
$envString = $envParts -join " "

$arguments = @(
    "create", "instance", $OfferId,
    "--image", $Image,
    "--disk", $DiskGb.ToString(),
    "--label", $Label,
    "--jupyter",
    "--direct",
    "--env", $envString,
    "--raw"
)

if ($CancelUnavail) {
    $arguments += "--cancel-unavail"
}

if ($Onstart) {
    $resolvedOnstart = (Resolve-Path -LiteralPath $Onstart).Path
    $arguments += @("--onstart", $resolvedOnstart)
}

Write-Host "Creating Vast instance with minimal environment..."
Write-Host ("vastai " + ($arguments -join " "))
$previousPythonUtf8 = $env:PYTHONUTF8
$previousPythonIoEncoding = $env:PYTHONIOENCODING
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

try {
    & vastai @arguments
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
