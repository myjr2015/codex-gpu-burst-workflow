param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$ImagePath,

    [string]$AudioPath = ".\output\ltx23_runninghub\_inputs\audio_30s.wav",

    [string]$ReferenceVideoPath = "",

    [switch]$ActionMimic,

    [string]$ActionMimicWorkflowSource = "",

    [string]$ActionMimicWorkflowId = "",

    [string]$OfferId,

    [string]$SearchQuery = "gpu_name=RTX_3090 num_gpus=1 gpu_ram>=24 cuda_max_good>=12.8 disk_space>180 direct_port_count>=4 rented=False geolocation notin [CN]",

    [double]$MaxDphTotal = 0.20,

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [string]$Label = "ltx23-talking-head-smoke-job",

    [int]$DiskGb = 180,

    [int]$OutputWidth = 512,

    [int]$OutputHeight = 896,

    [double]$DurationSeconds = 10,

    [int]$Fps = 24,

    [string]$PositivePrompt = "",

    [string]$SpeakerPrompt = "A woman is speaking naturally to the camera. Stable face identity, natural lip sync, subtle natural upper-body motion.",

    [string]$BackgroundPrompt = "modern photovoltaic technology scene, clean solar panel field or rooftop solar installation, bright professional product-demo environment, no readable signs or background text",

    [string]$CameraPrompt = "portrait vertical talking-head framing, natural professional lighting, clean camera frame, realistic digital human video",

    [string]$PromptGuardrails = "single person only, same character throughout the clip, no on-screen graphics, no subtitles, no captions",

    [string]$NegativePrompt = "subtitles, captions, Chinese subtitles, pseudo Chinese text, fake Chinese characters, karaoke lyrics, transcribed words, bottom text, lower third captions, text overlay, watermark, logo, news ticker, speech bubble, comic text, blurry, out of focus, flickering, motion blur, deformed face, distorted mouth, mismatched lip sync, extra limbs, extra fingers, disfigured hands, duplicated person, bad anatomy, cartoon, CGI, uncanny, low quality, noisy, artifacts",

    [int64]$Seed = -1,

    [string]$MotionLoraName = "",

    [double]$MotionLoraStrength = 0.35,

    [double]$ActionGuideStrength = 0.55,

    [double]$ActionLoraStrength = 0.75,

    [double]$IdentityLoraStrength = 0.75,

    [double]$IdentityGuidanceScale = 2.5,

    [int]$DwposeResolution = 512,

    [string[]]$MountArgs = @(),

    [string]$R2Prefix = $(if ($env:ASSET_S3_PREFIX) { $env:ASSET_S3_PREFIX.TrimEnd('/') + "/ltx23_talking_head_smoke" } elseif ($env:R2_PREFIX) { $env:R2_PREFIX } else { "runcomfy-inputs/ltx23_talking_head_smoke" }),

    [string]$R2Bucket = $(if ($env:ASSET_S3_BUCKET) { $env:ASSET_S3_BUCKET } elseif ($env:R2_BUCKET) { $env:R2_BUCKET } else { "runcomfy" }),

    [string]$R2PublicBaseUrl = $(if ($env:ASSET_S3_PUBLIC_BASE_URL) { $env:ASSET_S3_PUBLIC_BASE_URL } elseif ($env:R2_PUBLIC_BASE_URL) { $env:R2_PUBLIC_BASE_URL } else { "https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev" }),

    [string]$R2AccountId = $(if ($env:CLOUDFLARE_ACCOUNT_ID) { $env:CLOUDFLARE_ACCOUNT_ID } elseif ($env:ASSET_S3_ACCOUNT_ID) { $env:ASSET_S3_ACCOUNT_ID } else { "" }),

    [string]$R2AccessKeyId = $(if ($env:R2_ACCESS_KEY_ID) { $env:R2_ACCESS_KEY_ID } elseif ($env:ASSET_S3_ACCESS_KEY_ID) { $env:ASSET_S3_ACCESS_KEY_ID } else { "" }),

    [string]$R2SecretAccessKey = $(if ($env:R2_SECRET_ACCESS_KEY) { $env:R2_SECRET_ACCESS_KEY } elseif ($env:ASSET_S3_SECRET_ACCESS_KEY) { $env:ASSET_S3_SECRET_ACCESS_KEY } else { "" }),

    [switch]$SkipStage,

    [switch]$SkipLaunch,

    [switch]$SkipDownload,

    [switch]$SkipPublish,

    [switch]$DestroyInstance,

    [switch]$CancelUnavail,

    [int]$DownloadIntervalSeconds = 30,

    [int]$DownloadMaxChecks = 240
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$runnerPath = Join-Path $repoRoot "scripts\run_vast_workflow_job.ps1"
$selectorPath = Join-Path $repoRoot "scripts\select_wan_2_2_animate_vast_offer.ps1"
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
if (-not (Test-Path -LiteralPath $runnerPath)) {
    throw "Missing runner: $runnerPath"
}
if (-not (Test-Path -LiteralPath $selectorPath)) {
    throw "Missing selector: $selectorPath"
}
if (-not (Test-Path -LiteralPath $r2HelperPath)) {
    throw "Missing R2 helper: $r2HelperPath"
}

. $r2HelperPath
Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")
if ([string]::IsNullOrWhiteSpace($R2AccessKeyId) -and $env:ASSET_S3_ACCESS_KEY_ID) {
    $R2AccessKeyId = $env:ASSET_S3_ACCESS_KEY_ID
}
if ([string]::IsNullOrWhiteSpace($R2SecretAccessKey) -and $env:ASSET_S3_SECRET_ACCESS_KEY) {
    $R2SecretAccessKey = $env:ASSET_S3_SECRET_ACCESS_KEY
}
$R2AccountId = Resolve-R2AccountId -CloudflareAccountId $R2AccountId -AssetAccountId $env:ASSET_S3_ACCOUNT_ID -Endpoint $env:ASSET_S3_ENDPOINT

if ([string]::IsNullOrWhiteSpace($ImagePath)) {
    $defaultImage = Join-Path $repoRoot "素材资产\美女图带光伏\美女带背景.png"
    if (-not (Test-Path -LiteralPath $defaultImage)) {
        throw "ImagePath is required because default image was not found: $defaultImage"
    }
    $ImagePath = $defaultImage
}

if ($ActionMimic -and [string]::IsNullOrWhiteSpace($ReferenceVideoPath)) {
    $defaultReferenceVideo = Join-Path $repoRoot "素材资产\原视频\光伏10s.mp4"
    if (-not (Test-Path -LiteralPath $defaultReferenceVideo)) {
        throw "ReferenceVideoPath is required because default reference video was not found: $defaultReferenceVideo"
    }
    $ReferenceVideoPath = $defaultReferenceVideo
}

Write-Host "profile=ltx23_talking_head_smoke"
Write-Host "runtime_image=$Image"
Write-Host "resolution=${OutputWidth}x${OutputHeight}"
Write-Host "duration_seconds=$DurationSeconds"
Write-Host "fps=$Fps"
if (-not [string]::IsNullOrWhiteSpace($PositivePrompt)) {
    Write-Host "positive_prompt_source=full_override"
}
else {
    Write-Host "positive_prompt_source=composed_prompt_only"
    Write-Host "background_prompt=$BackgroundPrompt"
}
if (-not [string]::IsNullOrWhiteSpace($MotionLoraName)) {
    Write-Host "motion_lora=$MotionLoraName"
    Write-Host "motion_lora_strength=$MotionLoraStrength"
}
if ($ActionMimic) {
    Write-Host "mode=action_mimic"
    Write-Host "reference_video=$ReferenceVideoPath"
    if (-not [string]::IsNullOrWhiteSpace($ActionMimicWorkflowSource)) {
        Write-Host "action_mimic_workflow_source=$ActionMimicWorkflowSource"
    }
    if (-not [string]::IsNullOrWhiteSpace($ActionMimicWorkflowId)) {
        Write-Host "action_mimic_workflow_id=$ActionMimicWorkflowId"
    }
    Write-Host "action_guide_strength=$ActionGuideStrength"
    Write-Host "action_lora_strength=$ActionLoraStrength"
}

$stageArgs = @()
if (-not $SkipStage) {
    $stageArgs += @(
        "-ImagePath", (Resolve-Path -LiteralPath $ImagePath).Path,
        "-AudioPath", (Resolve-Path -LiteralPath $AudioPath).Path,
        "-OutputWidth", "$OutputWidth",
        "-OutputHeight", "$OutputHeight",
        "-DurationSeconds", $DurationSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        "-Fps", "$Fps",
        "-NegativePrompt", $NegativePrompt,
        "-R2Prefix", $R2Prefix,
        "-R2Bucket", $R2Bucket,
        "-R2PublicBaseUrl", $R2PublicBaseUrl
    )
    if (-not [string]::IsNullOrWhiteSpace($PositivePrompt)) {
        $stageArgs += @("-PositivePrompt", $PositivePrompt)
    }
    else {
        $stageArgs += @(
            "-SpeakerPrompt", $SpeakerPrompt,
            "-BackgroundPrompt", $BackgroundPrompt,
            "-CameraPrompt", $CameraPrompt,
            "-PromptGuardrails", $PromptGuardrails
        )
    }
    if ($Seed -ge 0) {
        $stageArgs += @("-Seed", "$Seed")
    }
    if (-not [string]::IsNullOrWhiteSpace($MotionLoraName)) {
        $stageArgs += @(
            "-MotionLoraName", $MotionLoraName,
            "-MotionLoraStrength", $MotionLoraStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        )
    }
    if ($ActionMimic) {
        $stageArgs += @(
            "-ActionMimic",
            "-ReferenceVideoPath", (Resolve-Path -LiteralPath $ReferenceVideoPath).Path,
            "-ActionGuideStrength", $ActionGuideStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
            "-ActionLoraStrength", $ActionLoraStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
            "-IdentityLoraStrength", $IdentityLoraStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
            "-IdentityGuidanceScale", $IdentityGuidanceScale.ToString([System.Globalization.CultureInfo]::InvariantCulture),
            "-DwposeResolution", "$DwposeResolution"
        )
        if (-not [string]::IsNullOrWhiteSpace($ActionMimicWorkflowSource)) {
            $stageArgs += @("-ActionMimicWorkflowSource", $ActionMimicWorkflowSource)
        }
        if (-not [string]::IsNullOrWhiteSpace($ActionMimicWorkflowId)) {
            $stageArgs += @("-ActionMimicWorkflowId", $ActionMimicWorkflowId)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($R2AccountId)) {
        $stageArgs += @("-R2AccountId", $R2AccountId)
    }
    if (-not [string]::IsNullOrWhiteSpace($R2AccessKeyId)) {
        $stageArgs += @("-R2AccessKeyId", $R2AccessKeyId)
    }
    if (-not [string]::IsNullOrWhiteSpace($R2SecretAccessKey)) {
        $stageArgs += @("-R2SecretAccessKey", $R2SecretAccessKey)
    }
    $stageArgs += "-UploadToR2"
}

$launchArgs = @()
if (-not $SkipLaunch) {
    $extraEnvItems = @()
    $extraEnvItems += @(
        "LTX_UPDATE_COMFYUI=0"
    )
    if ([string]::IsNullOrWhiteSpace($OfferId)) {
        $selectionJson = & pwsh -File $selectorPath `
            -SearchQuery $SearchQuery `
            -Storage $DiskGb `
            -MaxDphTotal $MaxDphTotal
        if ($LASTEXITCODE -ne 0) {
            throw "Automatic Vast offer selection failed."
        }

        $selection = $selectionJson | ConvertFrom-Json
        if (-not $selection.offer_id) {
            throw "Automatic Vast offer selection returned no offer_id."
        }

        $OfferId = [string]$selection.offer_id
        Write-Host "selection_mode=$($selection.selection_mode)"
        Write-Host "selection_reason=$($selection.selection_reason)"
        Write-Host "selected_offer_id=$OfferId"
        Write-Host "selected_machine_id=$($selection.machine_id)"
        Write-Host "selected_host_id=$($selection.host_id)"
    }

    $launchArgs += @(
        "-OfferId", $OfferId,
        "-Image", $Image,
        "-Label", $Label,
        "-DiskGb", $DiskGb.ToString()
    )
    if ($CancelUnavail) {
        $launchArgs += "-CancelUnavail"
    }
    if (-not [string]::IsNullOrWhiteSpace($MotionLoraName)) {
        $extraEnvItems += @(
            "LTX23_DOWNLOAD_VBVR=1",
            "LTX23_MOTION_LORA_NAME=$MotionLoraName"
        )
    }
    if ($ActionMimic) {
        $extraEnvItems += "LTX23_ENABLE_ACTION_MIMIC=1"
    }
    if ($extraEnvItems.Count -gt 0) {
        $launchArgs += @("-ExtraEnv", ($extraEnvItems -join ","))
    }
    if ($MountArgs.Count -gt 0) {
        $launchArgs += @("-MountArgs", $MountArgs)
    }
}

$publishArgs = @()
if (-not $SkipPublish) {
    $publishArgs += @(
        "-R2Prefix", $R2Prefix,
        "-R2Bucket", $R2Bucket,
        "-R2PublicBaseUrl", $R2PublicBaseUrl
    )
    if (-not [string]::IsNullOrWhiteSpace($R2AccountId)) {
        $publishArgs += @("-R2AccountId", $R2AccountId)
    }
    if (-not [string]::IsNullOrWhiteSpace($R2AccessKeyId)) {
        $publishArgs += @("-R2AccessKeyId", $R2AccessKeyId)
    }
    if (-not [string]::IsNullOrWhiteSpace($R2SecretAccessKey)) {
        $publishArgs += @("-R2SecretAccessKey", $R2SecretAccessKey)
    }
}

$runnerParams = @{
    Profile = "ltx23_talking_head_smoke"
    JobName = $JobName
    SkipStage = [bool]$SkipStage
    SkipLaunch = [bool]$SkipLaunch
    SkipDownload = [bool]$SkipDownload
    SkipPublish = [bool]$SkipPublish
    DestroyInstance = [bool]$DestroyInstance
    SkipMachineRegistryUpdate = $true
    DownloadIntervalSeconds = $DownloadIntervalSeconds
    DownloadMaxChecks = $DownloadMaxChecks
}

if ($stageArgs.Count -gt 0) {
    $runnerParams.StageArgs = $stageArgs
}
if ($launchArgs.Count -gt 0) {
    $runnerParams.LaunchArgs = $launchArgs
}
if ($publishArgs.Count -gt 0) {
    $runnerParams.PublishArgs = $publishArgs
}

& $runnerPath @runnerParams
if (-not $?) {
    throw "run_vast_workflow_job.ps1 failed."
}
