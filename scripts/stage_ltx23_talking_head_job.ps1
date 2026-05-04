param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [Parameter(Mandatory = $true)]
    [string]$ImagePath,

    [Parameter(Mandatory = $true)]
    [string]$AudioPath,

    [string]$ReferenceVideoPath = "",

    [switch]$ActionMimic,

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

    [switch]$NoTrimAudio,

    [string]$R2Prefix = $(if ($env:ASSET_S3_PREFIX) { $env:ASSET_S3_PREFIX.TrimEnd('/') + "/ltx23_talking_head_smoke" } elseif ($env:R2_PREFIX) { $env:R2_PREFIX } else { "runcomfy-inputs/ltx23_talking_head_smoke" }),

    [string]$R2Bucket = $(if ($env:ASSET_S3_BUCKET) { $env:ASSET_S3_BUCKET } elseif ($env:R2_BUCKET) { $env:R2_BUCKET } else { "runcomfy" }),

    [string]$R2PublicBaseUrl = $(if ($env:ASSET_S3_PUBLIC_BASE_URL) { $env:ASSET_S3_PUBLIC_BASE_URL } elseif ($env:R2_PUBLIC_BASE_URL) { $env:R2_PUBLIC_BASE_URL } else { "https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev" }),

    [string]$R2AccountId = $(if ($env:CLOUDFLARE_ACCOUNT_ID) { $env:CLOUDFLARE_ACCOUNT_ID } elseif ($env:ASSET_S3_ACCOUNT_ID) { $env:ASSET_S3_ACCOUNT_ID } else { "" }),

    [string]$R2AccessKeyId = $(if ($env:R2_ACCESS_KEY_ID) { $env:R2_ACCESS_KEY_ID } elseif ($env:ASSET_S3_ACCESS_KEY_ID) { $env:ASSET_S3_ACCESS_KEY_ID } else { "" }),

    [string]$R2SecretAccessKey = $(if ($env:R2_SECRET_ACCESS_KEY) { $env:R2_SECRET_ACCESS_KEY } elseif ($env:ASSET_S3_SECRET_ACCESS_KEY) { $env:ASSET_S3_SECRET_ACCESS_KEY } else { "" }),

    [switch]$UploadToR2
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "node not found. Install Node.js first."
}

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
$profileConfigPath = Join-Path $repoRoot "config\vast-workflow-profiles.json"
if (-not (Test-Path -LiteralPath $r2HelperPath)) {
    throw "Missing R2 helper: $r2HelperPath"
}
if (-not (Test-Path -LiteralPath $profileConfigPath)) {
    throw "Missing profile config: $profileConfigPath"
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

$profileConfig = Get-Content -Raw -LiteralPath $profileConfigPath | ConvertFrom-Json
$profileDefinition = $profileConfig.profiles."ltx23_talking_head_smoke"
$workflowSourceRel = [string]$profileDefinition.workflow_source
if ([string]::IsNullOrWhiteSpace($workflowSourceRel)) {
    $workflowSourceRel = "workflows\LTX2.3单图音频对口型-smoke.json"
}
$sourceWorkflowId = [string]$profileDefinition.source_workflow_id
if ([string]::IsNullOrWhiteSpace($sourceWorkflowId)) {
    $sourceWorkflowId = "2043593704170070018"
}

if ($ActionMimic -or -not [string]::IsNullOrWhiteSpace($ReferenceVideoPath)) {
    $ActionMimic = $true
    $workflowSourceRel = "workflows\LTX2.3动作模仿+音频对口型-V3候选.json"
    $sourceWorkflowId = "2044017351640748034"
    if ([string]::IsNullOrWhiteSpace($ReferenceVideoPath)) {
        throw "ReferenceVideoPath is required when ActionMimic is enabled."
    }
}

$sourceWorkflow = Join-Path $repoRoot $workflowSourceRel
$bootstrapScript = Join-Path $repoRoot "scripts\bootstrap_ltx23_talking_head.sh"
$remoteSubmitScript = Join-Path $repoRoot "scripts\remote_submit_ltx23_talking_head.sh"
$prepareScript = Join-Path $repoRoot "scripts\prepare_ltx23_talking_head_prompt.mjs"
$actionPrepareScript = Join-Path $repoRoot "scripts\prepare_ltx23_action_mimic_prompt.mjs"
$generateOnstartScript = Join-Path $repoRoot "scripts\generate_ltx23_talking_head_onstart.mjs"
$r2UploadScript = Join-Path $repoRoot "scripts\r2_upload.py"

foreach ($required in @($sourceWorkflow, $bootstrapScript, $remoteSubmitScript, $prepareScript, $actionPrepareScript, $generateOnstartScript, $r2UploadScript)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required file: $required"
    }
}

$resolvedImage = (Resolve-Path -LiteralPath $ImagePath).Path
$resolvedAudio = (Resolve-Path -LiteralPath $AudioPath).Path
$resolvedReferenceVideo = $null
if ($ActionMimic) {
    $resolvedReferenceVideo = (Resolve-Path -LiteralPath $ReferenceVideoPath).Path
}
$imageExt = [System.IO.Path]::GetExtension($resolvedImage).ToLowerInvariant()
$audioExt = [System.IO.Path]::GetExtension($resolvedAudio).ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($imageExt)) {
    $imageExt = ".png"
}
$referenceExt = ".mp4"
if ($ActionMimic) {
    $candidateExt = [System.IO.Path]::GetExtension($resolvedReferenceVideo).ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($candidateExt)) {
        $referenceExt = $candidateExt
    }
}

$inputImageName = "speaker$imageExt"
$inputAudioName = "speech.wav"
$inputReferenceVideoName = "reference_video$referenceExt"

$ffmpegPath = $null
if (-not $NoTrimAudio) {
    $ffmpegCandidates = @(
        (Join-Path $repoRoot "node_modules\ffmpeg-static\ffmpeg.exe"),
        "D:\code\KuangJia\ffmpeg\ffmpeg.exe",
        "D:\code\KuangJia\ffmpeg\bin\ffmpeg.exe"
    )
    $ffmpegPath = $ffmpegCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($ffmpegPath)) {
        throw "Missing ffmpeg. Checked: $($ffmpegCandidates -join ', ')"
    }
}

$jobDir = Join-Path $repoRoot ("output\ltx23_talking_head_smoke\" + $JobName)
$inputDir = Join-Path $jobDir "input"
New-Item -ItemType Directory -Force -Path $inputDir | Out-Null

foreach ($staleFile in @("onstart_ltx23_talking_head.sh", "vast-create-response.json", "vast-instance.json")) {
    $stalePath = Join-Path $jobDir $staleFile
    if (Test-Path -LiteralPath $stalePath) {
        Remove-Item -LiteralPath $stalePath -Force
    }
}

$stagedImage = Join-Path $inputDir $inputImageName
$stagedAudio = Join-Path $inputDir $inputAudioName
$stagedReferenceVideo = Join-Path $inputDir $inputReferenceVideoName
$canvasOut = Join-Path $jobDir "workflow_canvas.json"
$runtimeOut = Join-Path $jobDir "workflow_runtime.json"
$runtimeMetadataOut = Join-Path $jobDir "workflow_runtime.metadata.json"
$bootstrapOut = Join-Path $jobDir "bootstrap_ltx23_talking_head.sh"
$remoteSubmitOut = Join-Path $jobDir "remote_submit_ltx23_talking_head.sh"
$manifestOut = Join-Path $jobDir "manifest.json"
$onstartOut = Join-Path $jobDir "onstart_ltx23_talking_head.sh"

Copy-Item -LiteralPath $resolvedImage -Destination $stagedImage -Force
if ($ActionMimic) {
    Copy-Item -LiteralPath $resolvedReferenceVideo -Destination $stagedReferenceVideo -Force
}
if ($NoTrimAudio) {
    Copy-Item -LiteralPath $resolvedAudio -Destination $stagedAudio -Force
}
else {
    & $ffmpegPath -y -hide_banner -loglevel error `
        -i $resolvedAudio `
        -t $DurationSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture) `
        -ac 1 `
        -ar 24000 `
        -c:a pcm_s16le `
        $stagedAudio
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $stagedAudio)) {
        throw "Failed to trim/convert staged LTX2.3 audio: $stagedAudio"
    }
}
Copy-Item -LiteralPath $sourceWorkflow -Destination $canvasOut -Force
Copy-Item -LiteralPath $bootstrapScript -Destination $bootstrapOut -Force
Copy-Item -LiteralPath $remoteSubmitScript -Destination $remoteSubmitOut -Force

$selectedPrepareScript = if ($ActionMimic) { $actionPrepareScript } else { $prepareScript }

$prepareArgs = @(
    $selectedPrepareScript,
    "--input", $canvasOut,
    "--output", $runtimeOut,
    "--metadata-output", $runtimeMetadataOut,
    "--image-name", $inputImageName,
    "--audio-name", $inputAudioName,
    "--output-prefix", ("ltx23_talking_head_smoke-" + $JobName),
    "--output-width", "$OutputWidth",
    "--output-height", "$OutputHeight",
    "--duration-seconds", $DurationSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "--fps", "$Fps",
    "--negative-prompt", $NegativePrompt
)
if ($ActionMimic) {
    $prepareArgs += @(
        "--reference-video-name", $inputReferenceVideoName,
        "--action-guide-strength", $ActionGuideStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        "--action-lora-strength", $ActionLoraStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        "--identity-lora-strength", $IdentityLoraStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        "--identity-guidance-scale", $IdentityGuidanceScale.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        "--dwpose-resolution", "$DwposeResolution"
    )
}
if (-not [string]::IsNullOrWhiteSpace($PositivePrompt)) {
    $prepareArgs += @("--positive-prompt", $PositivePrompt)
}
else {
    $prepareArgs += @(
        "--speaker-prompt", $SpeakerPrompt,
        "--background-prompt", $BackgroundPrompt,
        "--camera-prompt", $CameraPrompt,
        "--prompt-guardrails", $PromptGuardrails
    )
}
if ($Seed -ge 0) {
    $prepareArgs += @("--seed", "$Seed")
}
if (-not [string]::IsNullOrWhiteSpace($MotionLoraName)) {
    $prepareArgs += @(
        "--motion-lora-name", $MotionLoraName,
        "--motion-lora-strength", $MotionLoraStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    )
}

& node @prepareArgs
if ($LASTEXITCODE -ne 0) {
    throw "Failed to prepare LTX2.3 workflow runtime JSON."
}

$runtimeMetadata = Get-Content -Raw -LiteralPath $runtimeMetadataOut | ConvertFrom-Json

$manifest = [ordered]@{
    profile = "ltx23_talking_head_smoke"
    skill = "ltx23_talking_head"
    job_name = $JobName
    created_at = (Get-Date).ToString("s")
    workflow = [ordered]@{
        mode = $(if ($ActionMimic) { "action_mimic" } else { "talking_head" })
        canvas_source = $sourceWorkflow
        canvas_name = [System.IO.Path]::GetFileName($sourceWorkflow)
        source_workflow_id = $sourceWorkflowId
        prepare_script = $selectedPrepareScript
        input_image_name = $inputImageName
        input_audio_name = $inputAudioName
        input_reference_video_name = $(if ($ActionMimic) { $inputReferenceVideoName } else { $null })
        audio_trimmed_to_duration = -not [bool]$NoTrimAudio
        output_width = $runtimeMetadata.output_width
        output_height = $runtimeMetadata.output_height
        base_width = $(if ($runtimeMetadata.base_width) { $runtimeMetadata.base_width } else { $runtimeMetadata.output_width })
        base_height = $(if ($runtimeMetadata.base_height) { $runtimeMetadata.base_height } else { $runtimeMetadata.output_height })
        duration_seconds = $runtimeMetadata.requested_duration_seconds
        fps = $runtimeMetadata.fps
        frame_count = $runtimeMetadata.frame_count
        expected_video_seconds = $runtimeMetadata.expected_video_seconds
        output_container = $runtimeMetadata.output_container
        nag_enabled = $runtimeMetadata.nag_enabled
        motion_lora_enabled = $runtimeMetadata.motion_lora_enabled
        motion_lora_name = $runtimeMetadata.motion_lora_name
        motion_lora_strength = $runtimeMetadata.motion_lora_strength
        action_mimic_enabled = [bool]$ActionMimic
        action_guide_strength = $(if ($ActionMimic) { $runtimeMetadata.action_guide_strength } else { $null })
        action_lora_name = $(if ($ActionMimic) { $runtimeMetadata.action_lora_name } else { $null })
        action_lora_strength = $(if ($ActionMimic) { $runtimeMetadata.action_lora_strength } else { $null })
        identity_lora_name = $(if ($ActionMimic) { $runtimeMetadata.identity_lora_name } else { $null })
        identity_lora_strength = $(if ($ActionMimic) { $runtimeMetadata.identity_lora_strength } else { $null })
        identity_guidance_scale = $(if ($ActionMimic) { $runtimeMetadata.identity_guidance_scale } else { $null })
        dwpose_resolution = $(if ($ActionMimic) { $runtimeMetadata.dwpose_resolution } else { $null })
        positive_prompt_source = $runtimeMetadata.positive_prompt_source
        positive_prompt = $runtimeMetadata.positive_prompt
        speaker_prompt = $runtimeMetadata.speaker_prompt
        background_prompt = $runtimeMetadata.background_prompt
        camera_prompt = $runtimeMetadata.camera_prompt
        prompt_guardrails = $runtimeMetadata.prompt_guardrails
        negative_prompt = $NegativePrompt
        bootstrap_template = $bootstrapScript
        remote_submit_template = $remoteSubmitScript
        onstart_generator = $generateOnstartScript
    }
    local = [ordered]@{
        job_dir = $jobDir
        input_image = $stagedImage
        input_audio = $stagedAudio
        input_reference_video = $(if ($ActionMimic) { $stagedReferenceVideo } else { $null })
        workflow_canvas = $canvasOut
        workflow_runtime = $runtimeOut
        workflow_runtime_metadata = $runtimeMetadataOut
        bootstrap = $bootstrapOut
        remote_submit = $remoteSubmitOut
        onstart = $onstartOut
    }
    r2 = [ordered]@{
        bucket = $R2Bucket
        public_base_url = $R2PublicBaseUrl
        prefix = "$R2Prefix/$JobName"
        input = "$R2Prefix/$JobName/input"
        output = "$R2Prefix/$JobName/output"
    }
    remote = [ordered]@{
        comfy_input_image = "/workspace/ComfyUI/input/$inputImageName"
        comfy_input_audio = "/workspace/ComfyUI/input/$inputAudioName"
        comfy_input_reference_video = $(if ($ActionMimic) { "/workspace/ComfyUI/input/$inputReferenceVideoName" } else { $null })
        run_dir = "/workspace/ltx23-talking-head-run"
    }
    automation = [ordered]@{
        profile_config = $profileConfigPath
        run_report = (Join-Path $jobDir "run-report.json")
        timing_summary = (Join-Path $jobDir "timing-summary.json")
    }
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestOut -Encoding UTF8

& node $generateOnstartScript `
    --manifest $manifestOut `
    --output $onstartOut
if ($LASTEXITCODE -ne 0) {
    throw "Failed to generate onstart_ltx23_talking_head.sh."
}

if ($UploadToR2) {
    if ([string]::IsNullOrWhiteSpace($R2AccountId) -or [string]::IsNullOrWhiteSpace($R2AccessKeyId) -or [string]::IsNullOrWhiteSpace($R2SecretAccessKey)) {
        throw "R2 credentials missing. Provide -R2AccountId, -R2AccessKeyId, and -R2SecretAccessKey, or set matching environment variables."
    }

    & D:\code\YuYan\python\python.exe $r2UploadScript `
        --account-id $R2AccountId `
        --access-key-id $R2AccessKeyId `
        --secret-access-key $R2SecretAccessKey `
        --bucket $R2Bucket `
        --local-path $jobDir `
        --remote-prefix "$R2Prefix/$JobName" `
        --public-base-url $R2PublicBaseUrl

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload staged LTX2.3 job to R2."
    }
}

Write-Host "job staged: $jobDir"
Write-Host "runtime: $runtimeOut"
Write-Host "resolution=$OutputWidth x $OutputHeight"
Write-Host "frame_count=$($runtimeMetadata.frame_count)"
Write-Host "expected_video_seconds=$($runtimeMetadata.expected_video_seconds)"
Write-Host "r2 output prefix: $R2Prefix/$JobName/output"
