param(
    [Parameter(Mandatory = $true)]
    [string]$OfferId,

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [string]$Label = "codex-comfy-minimal",

    [int]$DiskGb = 180
)

$ErrorActionPreference = "Stop"

$envParts = @(
    "-e DATA_DIRECTORY=/workspace/",
    "-e JUPYTER_DIR=/",
    "-e OPEN_BUTTON_PORT=8188",
    "-e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/vast-ai/base-image/refs/heads/main/derivatives/pytorch/derivatives/comfyui/provisioning_scripts/default.sh",
    "-p 1111:1111",
    "-p 8080:8080",
    "-p 8188:8188",
    "-p 8384:8384"
)

$envString = $envParts -join " "

$command = @(
    "vastai create instance $OfferId",
    "--image $Image",
    "--disk $DiskGb",
    "--label $Label",
    "--jupyter",
    "--direct",
    "--env '$envString'",
    "--raw"
) -join " "

Write-Host "Creating Vast instance with minimal environment..."
Write-Host $command
Invoke-Expression $command
