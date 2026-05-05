param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$SourceVideoPath = ".\素材资产\原视频\光伏10s.mp4",

    [string]$SpeakerImagePath = ".\素材资产\美女图无背景纯色\纯色坐着.png",

    [string]$AudioPath = ".\output\ltx23_runninghub\_inputs\audio_30s.wav",

    [double]$StartSeconds = 0.0,

    [double]$DurationSeconds = 10.0,

    [int]$Fps = 24,

    [int]$OutputWidth = 512,

    [int]$OutputHeight = 896,

    [double]$ActionGuideStrength = 0.52,

    [double]$ActionLoraStrength = 0.68,

    [double]$IdentityLoraStrength = 0.75,

    [double]$IdentityGuidanceScale = 2.5,

    [string]$BackgroundPrompt = "",

    [string]$OfferId = "",

    [string]$SearchQuery = "gpu_name=RTX_3090 num_gpus=1 gpu_ram>=24 cuda_max_good>=12.8 disk_space>180 direct_port_count>=4 rented=False geolocation notin [CN]",

    [double]$PreferredMaxDphTotal = 0.15,

    [double]$FallbackMaxDphTotal = 0.16,

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [string]$Label = "ltx23-matte-action-job",

    [int]$DiskGb = 180,

    [switch]$CancelUnavail,

    [switch]$SkipLaunch,

    [switch]$SkipDownload,

    [switch]$SkipPublish,

    [switch]$KeepInstance,

    [int]$DownloadIntervalSeconds = 30,

    [int]$DownloadMaxChecks = 240
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$prepareScript = Join-Path $repoRoot "scripts\prepare_ltx23_matte_action_job.ps1"
$runnerPath = Join-Path $repoRoot "scripts\run_vast_workflow_job.ps1"
$selectorPath = Join-Path $repoRoot "scripts\select_wan_2_2_animate_vast_offer.ps1"

foreach ($required in @($prepareScript, $runnerPath, $selectorPath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required file: $required"
    }
}

function Select-OfferWithCeiling {
    param(
        [Parameter(Mandatory = $true)]
        [double]$MaxDphTotal
    )

    $selectionJson = & pwsh -File $selectorPath `
        -SearchQuery $SearchQuery `
        -Storage $DiskGb `
        -MaxDphTotal $MaxDphTotal
    if ($LASTEXITCODE -ne 0) {
        throw "Automatic Vast offer selection failed for max_dph_total=$MaxDphTotal."
    }

    $selection = $selectionJson | ConvertFrom-Json
    if (-not $selection.offer_id) {
        throw "Automatic Vast offer selection returned no offer_id for max_dph_total=$MaxDphTotal."
    }
    return $selection
}

Write-Host "stage=local_matte_prepare"
Write-Host "source_video=$SourceVideoPath"
Write-Host "speaker_image=$SpeakerImagePath"
Write-Host "resolution=${OutputWidth}x${OutputHeight}"
Write-Host "duration_seconds=$DurationSeconds"
Write-Host "fps=$Fps"

$prepareArgs = @(
    "-JobName", $JobName,
    "-SourceVideoPath", $SourceVideoPath,
    "-SpeakerImagePath", $SpeakerImagePath,
    "-AudioPath", $AudioPath,
    "-StartSeconds", $StartSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-DurationSeconds", $DurationSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-Fps", $Fps.ToString(),
    "-OutputWidth", $OutputWidth.ToString(),
    "-OutputHeight", $OutputHeight.ToString(),
    "-ActionGuideStrength", $ActionGuideStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-ActionLoraStrength", $ActionLoraStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-IdentityLoraStrength", $IdentityLoraStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-IdentityGuidanceScale", $IdentityGuidanceScale.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-UploadToR2"
)
if (-not [string]::IsNullOrWhiteSpace($BackgroundPrompt)) {
    $prepareArgs += @("-BackgroundPrompt", $BackgroundPrompt)
}

& pwsh -File $prepareScript @prepareArgs
if ($LASTEXITCODE -ne 0) {
    throw "Failed to prepare LTX2.3 matte action job."
}

$jobDir = Join-Path $repoRoot ("output\ltx23_talking_head_smoke\" + $JobName)
$assetManifestPath = Join-Path $repoRoot ("output\ltx23_talking_head_smoke\_matte_action_assets\" + $JobName + "\matte_action_assets_manifest.json")
if (-not (Test-Path -LiteralPath $assetManifestPath)) {
    throw "Missing matte asset manifest after prepare: $assetManifestPath"
}
$assetManifest = Get-Content -Raw -LiteralPath $assetManifestPath | ConvertFrom-Json
Write-Host "matte_method=$($assetManifest.method)"
Write-Host "local_self_check=passed"

$selected = $null
if (-not $SkipLaunch) {
    Write-Host "stage=launch"
    Write-Host "search_storage_gb=$DiskGb"
    Write-Host "cn_candidates=excluded"
    Write-Host "preferred_max_dph_total=$PreferredMaxDphTotal"
    Write-Host "fallback_max_dph_total=$FallbackMaxDphTotal"

    if ([string]::IsNullOrWhiteSpace($OfferId)) {
        try {
            $selected = Select-OfferWithCeiling -MaxDphTotal $PreferredMaxDphTotal
        }
        catch {
            Write-Host "preferred_selection_failed=$($_.Exception.Message)"
            $selected = Select-OfferWithCeiling -MaxDphTotal $FallbackMaxDphTotal
        }
        $OfferId = [string]$selected.offer_id
        Write-Host "selection_mode=$($selected.selection_mode)"
        Write-Host "selection_reason=$($selected.selection_reason)"
        Write-Host "selected_offer_id=$OfferId"
        Write-Host "selected_machine_id=$($selected.machine_id)"
        Write-Host "selected_host_id=$($selected.host_id)"
    }
    else {
        Write-Host "selected_offer_id=$OfferId"
    }
}

$launchArgs = @()
if (-not $SkipLaunch) {
    $launchArgs += @(
        "-OfferId", $OfferId,
        "-Image", $Image,
        "-Label", $Label,
        "-DiskGb", $DiskGb.ToString(),
        "-ExtraEnv", "LTX23_ENABLE_ACTION_MIMIC=1"
    )
    if ($CancelUnavail) {
        $launchArgs += "-CancelUnavail"
    }
}

$runnerParams = @{
    Profile = "ltx23_talking_head_smoke"
    JobName = $JobName
    SkipStage = $true
    SkipLaunch = [bool]$SkipLaunch
    SkipDownload = [bool]$SkipDownload
    SkipPublish = [bool]$SkipPublish
    DestroyInstance = -not [bool]$KeepInstance
    DownloadIntervalSeconds = $DownloadIntervalSeconds
    DownloadMaxChecks = $DownloadMaxChecks
}
if ($launchArgs.Count -gt 0) {
    $runnerParams.LaunchArgs = $launchArgs
}

& $runnerPath @runnerParams
if (-not $?) {
    throw "run_vast_workflow_job.ps1 failed."
}

Write-Host "job_dir=$jobDir"
Write-Host "asset_manifest=$assetManifestPath"
