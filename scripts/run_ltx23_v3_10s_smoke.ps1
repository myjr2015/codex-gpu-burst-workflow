param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [Parameter(Mandatory = $true)]
    [string]$BackgroundPromptPath,

    [string]$ImagePath = ".\output\ltx23_talking_head_smoke\_anchors\ltx23_sitting_rgb_anchor_512x896_bgplate_v6_grounded_synthetic_clean.png",

    [string]$AudioPath = ".\素材资产\原音频\10s.wav",

    [string]$ReferenceVideoPath = ".\output\ltx23_talking_head_smoke\_references\光伏10s_clean_reference_v6_skip1.mp4",

    [int64]$Seed = -1,

    [double]$ActionGuideStrength = 0.45,

    [double]$ActionLoraStrength = 0.65,

    [double]$IdentityLoraStrength = 0.75,

    [double]$IdentityGuidanceScale = 2.5,

    [ValidateSet("enable", "disable")]
    [string]$DwposeDetectBody = "enable",

    [ValidateSet("enable", "disable")]
    [string]$DwposeDetectHand = "enable",

    [ValidateSet("enable", "disable")]
    [string]$DwposeDetectFace = "enable",

    [double]$MaxDphTotal = 0.15,

    [int]$DiskGb = 180,

    [switch]$RunPaid,

    [switch]$DestroyInstance,

    [switch]$CancelUnavail
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$stageScript = Join-Path $repoRoot "scripts\stage_ltx23_talking_head_job.ps1"
$runScript = Join-Path $repoRoot "scripts\run_ltx23_talking_head_smoke_end_to_end.ps1"

foreach ($required in @($stageScript, $runScript, $BackgroundPromptPath, $ImagePath, $AudioPath, $ReferenceVideoPath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required file: $required"
    }
}

$backgroundPrompt = (Get-Content -Raw -LiteralPath $BackgroundPromptPath).Trim()
if ([string]::IsNullOrWhiteSpace($backgroundPrompt)) {
    throw "BackgroundPromptPath is empty: $BackgroundPromptPath"
}

$commonArgs = @(
    "-JobName", $JobName,
    "-ImagePath", (Resolve-Path -LiteralPath $ImagePath).Path,
    "-AudioPath", (Resolve-Path -LiteralPath $AudioPath).Path,
    "-ReferenceVideoPath", (Resolve-Path -LiteralPath $ReferenceVideoPath).Path,
    "-ActionMimic",
    "-ActionMimicWorkflowSource", "workflows\LTX2.3动作模仿+音频对口型-V3候选.json",
    "-ActionMimicWorkflowId", "2044017351640748034",
    "-OutputWidth", "512",
    "-OutputHeight", "896",
    "-DurationSeconds", "10",
    "-Fps", "24",
    "-BackgroundPrompt", $backgroundPrompt,
    "-ActionGuideStrength", $ActionGuideStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-ActionLoraStrength", $ActionLoraStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-IdentityLoraStrength", $IdentityLoraStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-IdentityGuidanceScale", $IdentityGuidanceScale.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-DwposeDetectBody", $DwposeDetectBody,
    "-DwposeDetectHand", $DwposeDetectHand,
    "-DwposeDetectFace", $DwposeDetectFace
)

if ($Seed -ge 0) {
    $commonArgs += @("-Seed", "$Seed")
}

Write-Host "ltx23_v3_10s_smoke=1"
Write-Host "job_name=$JobName"
Write-Host "mode=action_mimic_v3"
Write-Host "duration_seconds=10"
Write-Host "resolution=512x896"
Write-Host "background_prompt_source=$((Resolve-Path -LiteralPath $BackgroundPromptPath).Path)"
Write-Host "run_paid=$([bool]$RunPaid)"

if (-not $RunPaid) {
    Write-Host "stage=prepare_only"
    & pwsh -File $stageScript @commonArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Prepare-only stage failed."
    }
    Write-Host "prepare_only_done=1"
    return
}

Write-Host "stage=paid_vast_run"
Write-Host "vast_storage_gb=$DiskGb"
Write-Host "max_dph_total=$MaxDphTotal"
Write-Host "cn_excluded=1"

$paidArgs = $commonArgs + @(
    "-DiskGb", "$DiskGb",
    "-MaxDphTotal", $MaxDphTotal.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-SearchQuery", "gpu_name=RTX_3090 num_gpus=1 gpu_ram>=24 cuda_max_good>=12.8 disk_space>180 direct_port_count>=4 rented=False geolocation notin [CN]"
)

if ($DestroyInstance) {
    $paidArgs += "-DestroyInstance"
}
if ($CancelUnavail) {
    $paidArgs += "-CancelUnavail"
}

& pwsh -File $runScript @paidArgs
if ($LASTEXITCODE -ne 0) {
    throw "Paid LTX2.3 V3 10s smoke run failed."
}
