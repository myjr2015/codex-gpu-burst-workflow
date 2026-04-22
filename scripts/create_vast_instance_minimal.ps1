param(
    [Parameter(Mandatory = $true)]
    [string]$OfferId,

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [string]$Label = "codex-comfy-minimal",

    [int]$DiskGb = 180,

    [switch]$CancelUnavail,

    [string]$Onstart,

    [string[]]$ExtraEnv = @()
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

$envString = (
    @($envItems | ForEach-Object { "-e $_" }) +
    @(
        "-p 1111:1111"
        "-p 8080:8080"
        "-p 8188:8188"
        "-p 8384:8384"
    )
) -join " "

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
& vastai @arguments
