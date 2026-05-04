param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [Parameter(Mandatory = $true)]
    [string]$ImagePath,

    [Parameter(Mandatory = $true)]
    [string]$AudioPath,

    [int]$OutputWidth = 512,

    [int]$OutputHeight = 896,

    [double]$DurationSeconds = 10,

    [int]$Fps = 24,

    [string]$PositivePrompt = "A woman is speaking naturally to the camera. Stable face identity, natural lip sync, clean photovoltaic technology background. Clean camera frame, natural professional lighting, no on-screen graphics.",

    [string]$NegativePrompt = "subtitles, captions, Chinese subtitles, pseudo Chinese text, fake Chinese characters, karaoke lyrics, transcribed words, bottom text, lower third captions, text overlay, watermark, logo, news ticker, speech bubble, comic text, blurry, out of focus, flickering, motion blur, deformed face, distorted mouth, mismatched lip sync, extra limbs, extra fingers, disfigured hands, duplicated person, bad anatomy, cartoon, CGI, uncanny, low quality, noisy, artifacts",

    [int64]$Seed = -1,

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

$sourceWorkflow = Join-Path $repoRoot $workflowSourceRel
$bootstrapScript = Join-Path $repoRoot "scripts\bootstrap_ltx23_talking_head.sh"
$remoteSubmitScript = Join-Path $repoRoot "scripts\remote_submit_ltx23_talking_head.sh"
$prepareScript = Join-Path $repoRoot "scripts\prepare_ltx23_talking_head_prompt.mjs"
$generateOnstartScript = Join-Path $repoRoot "scripts\generate_ltx23_talking_head_onstart.mjs"
$r2UploadScript = Join-Path $repoRoot "scripts\r2_upload.py"

foreach ($required in @($sourceWorkflow, $bootstrapScript, $remoteSubmitScript, $prepareScript, $generateOnstartScript, $r2UploadScript)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required file: $required"
    }
}

$resolvedImage = (Resolve-Path -LiteralPath $ImagePath).Path
$resolvedAudio = (Resolve-Path -LiteralPath $AudioPath).Path
$imageExt = [System.IO.Path]::GetExtension($resolvedImage).ToLowerInvariant()
$audioExt = [System.IO.Path]::GetExtension($resolvedAudio).ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($imageExt)) {
    $imageExt = ".png"
}

$inputImageName = "speaker$imageExt"
$inputAudioName = "speech.wav"

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
$canvasOut = Join-Path $jobDir "workflow_canvas.json"
$runtimeOut = Join-Path $jobDir "workflow_runtime.json"
$runtimeMetadataOut = Join-Path $jobDir "workflow_runtime.metadata.json"
$bootstrapOut = Join-Path $jobDir "bootstrap_ltx23_talking_head.sh"
$remoteSubmitOut = Join-Path $jobDir "remote_submit_ltx23_talking_head.sh"
$manifestOut = Join-Path $jobDir "manifest.json"
$onstartOut = Join-Path $jobDir "onstart_ltx23_talking_head.sh"

Copy-Item -LiteralPath $resolvedImage -Destination $stagedImage -Force
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

$prepareArgs = @(
    $prepareScript,
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
    "--positive-prompt", $PositivePrompt,
    "--negative-prompt", $NegativePrompt
)
if ($Seed -ge 0) {
    $prepareArgs += @("--seed", "$Seed")
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
        canvas_source = $sourceWorkflow
        canvas_name = [System.IO.Path]::GetFileName($sourceWorkflow)
        source_workflow_id = $sourceWorkflowId
        prepare_script = $prepareScript
        input_image_name = $inputImageName
        input_audio_name = $inputAudioName
        audio_trimmed_to_duration = -not [bool]$NoTrimAudio
        output_width = $runtimeMetadata.output_width
        output_height = $runtimeMetadata.output_height
        base_width = $runtimeMetadata.base_width
        base_height = $runtimeMetadata.base_height
        duration_seconds = $runtimeMetadata.requested_duration_seconds
        fps = $runtimeMetadata.fps
        frame_count = $runtimeMetadata.frame_count
        expected_video_seconds = $runtimeMetadata.expected_video_seconds
        output_container = $runtimeMetadata.output_container
        nag_enabled = $runtimeMetadata.nag_enabled
        positive_prompt = $PositivePrompt
        negative_prompt = $NegativePrompt
        bootstrap_template = $bootstrapScript
        remote_submit_template = $remoteSubmitScript
        onstart_generator = $generateOnstartScript
    }
    local = [ordered]@{
        job_dir = $jobDir
        input_image = $stagedImage
        input_audio = $stagedAudio
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
