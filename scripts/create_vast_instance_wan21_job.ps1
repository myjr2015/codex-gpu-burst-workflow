param(
    [Parameter(Mandatory = $true)]
    [string]$OfferId,

    [Parameter(Mandatory = $true)]
    [string]$InputImageUrl,

    [Parameter(Mandatory = $true)]
    [string]$InputAudioUrl,

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [string]$Label = "wan21-clean-anchor-job",

    [int]$DiskGb = 180,

    [string]$RepoUrl = "https://github.com/myjr2015/codex-gpu-burst-workflow.git"
)

$ErrorActionPreference = "Stop"

$envParts = @(
    "-e DATA_DIRECTORY=/workspace/",
    "-e JUPYTER_DIR=/",
    "-e OPEN_BUTTON_PORT=8188",
    "-e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/vast-ai/base-image/refs/heads/main/derivatives/pytorch/derivatives/comfyui/provisioning_scripts/default.sh",
    "-e INPUT_IMAGE_URL=$InputImageUrl",
    "-e INPUT_AUDIO_URL=$InputAudioUrl",
    "-e REPO_ROOT=/workspace/codex-gpu-burst-workflow",
    "-e COMFY_ROOT=/opt/workspace-internal/ComfyUI",
    "-p 1111:1111",
    "-p 8080:8080",
    "-p 8188:8188",
    "-p 8384:8384"
)

$envString = $envParts -join " "
$onstart = @(
    "set -e",
    "rm -rf /workspace/codex-gpu-burst-workflow",
    "git clone --depth 1 $RepoUrl /workspace/codex-gpu-burst-workflow",
    "nohup bash /workspace/codex-gpu-burst-workflow/scripts/remote_run_wan21_clean_anchor.sh > /workspace/wan21-onstart.log 2>&1 &"
) -join "; "

$command = @(
    "vastai create instance $OfferId",
    "--image $Image",
    "--disk $DiskGb",
    "--label $Label",
    "--jupyter",
    "--direct",
    "--env '$envString'",
    "--onstart-cmd ""$onstart""",
    "--raw"
) -join " "

Write-Host "Creating Vast instance with Wan 2.1 onstart job..."
Write-Host $command
Invoke-Expression $command
