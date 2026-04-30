param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$ImagePath = ".\素材资产\美女图无背景纯色\纯色坐着.png",

    [string]$VideoPath = ".\素材资产\原视频\光伏60s.mp4",

    [string]$Prompt = "固定同一个女性IP，在现代户外光伏发电场景中自然口播介绍产品。画面中只有一个女性主体，保持参考视频中的动作、表情、口型节奏、身体姿态和关键道具关系；背景和道具根据视频反推提示词重绘，不额外强加视频里没有的物体。镜头稳定，人物边缘干净，身份和五官稳定。 one person only, same character, prompt-guided scene and props, no background people.",

    [string]$NegativePrompt = "色调艳丽，过曝，静态，细节模糊不清，字幕，风格，作品，画作，画面，静止，整体发灰，最差质量，低质量，JPEG压缩残留，丑陋的，残缺的，多余的手指，画得不好的手部，画得不好的脸部，畸形的，毁容的，形态畸形的肢体，手指融合，静止不动的画面，杂乱的背景，三条腿，背景人很多，倒着走，第二个人，双人，两个女人，重复人物，重复身体，重复头部，额外身体，额外躯干，背景里的大人物，身后站人，幽灵人影，残影，透明人，双曝光，镜像身体，倒影身体，影子人物，多个人，multiple people, second person, duplicate body, duplicate woman, person behind, background person, ghost, double exposure, extra torso, extra head",

    [Int64]$Seed = 387956277078883,

    [string]$WorkflowSource = ".\workflows\书墨-30s长视频-wan2-2AnimateKJ版_v2版-参考动作、表情.json",

    [string]$BackgroundImagePath = "",

    [int]$BackgroundMaskGrow = 12,

    [ValidateSet("sdpa", "sageattn", "comfy")]
    [string]$AttentionMode = "sdpa",

    [int]$SegmentSeconds = 30,

    [int]$MaxSegments = 0,

    [switch]$UploadToR2,

    [string]$R2Prefix = $(if ($env:ASSET_S3_PREFIX) { $env:ASSET_S3_PREFIX.TrimEnd("/") + "/wan22_kj_30s_segmented" } elseif ($env:R2_PREFIX) { $env:R2_PREFIX.TrimEnd("/") + "/wan22_kj_30s_segmented" } else { "runcomfy-inputs/wan22_kj_30s_segmented" }),

    [string]$R2Bucket = $(if ($env:ASSET_S3_BUCKET) { $env:ASSET_S3_BUCKET } elseif ($env:R2_BUCKET) { $env:R2_BUCKET } else { "runcomfy" }),

    [string]$R2PublicBaseUrl = $(if ($env:ASSET_S3_PUBLIC_BASE_URL) { $env:ASSET_S3_PUBLIC_BASE_URL } elseif ($env:R2_PUBLIC_BASE_URL) { $env:R2_PUBLIC_BASE_URL } else { "https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev" }),

    [string]$R2AccountId = $(if ($env:CLOUDFLARE_ACCOUNT_ID) { $env:CLOUDFLARE_ACCOUNT_ID } elseif ($env:ASSET_S3_ACCOUNT_ID) { $env:ASSET_S3_ACCOUNT_ID } else { "" }),

    [string]$R2AccessKeyId = $(if ($env:R2_ACCESS_KEY_ID) { $env:R2_ACCESS_KEY_ID } elseif ($env:ASSET_S3_ACCESS_KEY_ID) { $env:ASSET_S3_ACCESS_KEY_ID } else { "" }),

    [string]$R2SecretAccessKey = $(if ($env:R2_SECRET_ACCESS_KEY) { $env:R2_SECRET_ACCESS_KEY } elseif ($env:ASSET_S3_SECRET_ACCESS_KEY) { $env:ASSET_S3_SECRET_ACCESS_KEY } else { "" })
)

$ErrorActionPreference = "Stop"

if ($SegmentSeconds -le 0) {
    throw "SegmentSeconds must be greater than 0."
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "node not found. Install Node.js first."
}

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
if (Test-Path -LiteralPath $r2HelperPath) {
    . $r2HelperPath
    Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")
}
if ([string]::IsNullOrWhiteSpace($R2AccessKeyId) -and $env:ASSET_S3_ACCESS_KEY_ID) {
    $R2AccessKeyId = $env:ASSET_S3_ACCESS_KEY_ID
}
if ([string]::IsNullOrWhiteSpace($R2SecretAccessKey) -and $env:ASSET_S3_SECRET_ACCESS_KEY) {
    $R2SecretAccessKey = $env:ASSET_S3_SECRET_ACCESS_KEY
}
if (Get-Command Resolve-R2AccountId -ErrorAction SilentlyContinue) {
    $R2AccountId = Resolve-R2AccountId -CloudflareAccountId $R2AccountId -AssetAccountId $env:ASSET_S3_ACCOUNT_ID -Endpoint $env:ASSET_S3_ENDPOINT
}

$ffmpegCandidates = @(
    (Join-Path $repoRoot "node_modules\ffmpeg-static\ffmpeg.exe"),
    "D:\code\KuangJia\ffmpeg\ffmpeg.exe"
)
$ffprobeCandidates = @(
    (Join-Path $repoRoot "node_modules\ffprobe-static\bin\win32\x64\ffprobe.exe"),
    "D:\code\KuangJia\ffmpeg\ffprobe.exe"
)
$ffmpegPath = $ffmpegCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$ffprobePath = $ffprobeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($ffmpegPath)) {
    throw "Missing ffmpeg. Checked: $($ffmpegCandidates -join ', ')"
}
if ([string]::IsNullOrWhiteSpace($ffprobePath)) {
    throw "Missing ffprobe. Checked: $($ffprobeCandidates -join ', ')"
}

$prepareScript = Join-Path $repoRoot "scripts\prepare_wan22_kj_30s_prompt.mjs"
$validateScript = Join-Path $repoRoot "scripts\validate_wan22_kj_30s_runtime.mjs"
$bootstrapScript = Join-Path $repoRoot "scripts\bootstrap_wan22_kj_30s.sh"
$remoteSubmitScript = Join-Path $repoRoot "scripts\remote_submit_wan22_kj_30s.sh"
$warmstartInspectorScript = Join-Path $repoRoot "scripts\inspect_wan22_kj_30s_warmstart.py"
$uploadScript = Join-Path $repoRoot "scripts\r2_upload.py"

foreach ($required in @($ffmpegPath, $ffprobePath, $prepareScript, $validateScript, $bootstrapScript, $remoteSubmitScript, $warmstartInspectorScript, $WorkflowSource, $ImagePath, $VideoPath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required file: $required"
    }
}
if (-not [string]::IsNullOrWhiteSpace($BackgroundImagePath) -and -not (Test-Path -LiteralPath $BackgroundImagePath)) {
    throw "Missing background image file: $BackgroundImagePath"
}

function Get-VideoDurationSeconds {
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $Path
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        throw "Failed to read video duration with ffprobe: $Path"
    }
    [double]$raw
}

function New-VideoSegment {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][double]$StartSeconds,
        [Parameter(Mandatory = $true)][double]$DurationSeconds,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    & $ffmpegPath `
        -y `
        -ss $StartSeconds.ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture) `
        -i $InputPath `
        -t $DurationSeconds.ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture) `
        -c:v libx264 `
        -preset veryfast `
        -crf 18 `
        -c:a aac `
        -movflags +faststart `
        $OutputPath | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg split failed: $OutputPath"
    }
}

$resolvedWorkflow = (Resolve-Path -LiteralPath $WorkflowSource).Path
$resolvedImage = (Resolve-Path -LiteralPath $ImagePath).Path
$resolvedVideo = (Resolve-Path -LiteralPath $VideoPath).Path
$resolvedBackgroundImage = $null
if (-not [string]::IsNullOrWhiteSpace($BackgroundImagePath)) {
    $resolvedBackgroundImage = (Resolve-Path -LiteralPath $BackgroundImagePath).Path
}
$videoDurationSeconds = Get-VideoDurationSeconds -Path $resolvedVideo
$segmentCount = [int][math]::Ceiling($videoDurationSeconds / [double]$SegmentSeconds)
if ($MaxSegments -gt 0) {
    $segmentCount = [math]::Min($segmentCount, $MaxSegments)
}
if ($segmentCount -lt 1) {
    throw "No segments to stage."
}

$videoFrameRate = 16
$jobDir = Join-Path $repoRoot ("output\wan22_kj_30s_segmented\" + $JobName)
$inputDir = Join-Path $jobDir "input"
New-Item -ItemType Directory -Force -Path $inputDir | Out-Null

$stagedImageName = "ip_image.png"
$stagedBackgroundImageName = "bg_image.png"
$stagedImage = Join-Path $inputDir $stagedImageName
$stagedBackgroundImage = Join-Path $inputDir $stagedBackgroundImageName
$canvasOut = Join-Path $jobDir "workflow_canvas.json"
$manifestOut = Join-Path $jobDir "manifest.json"
$bootstrapOut = Join-Path $jobDir "bootstrap_wan22_kj_30s.sh"
$remoteSubmitOut = Join-Path $jobDir "remote_submit_wan22_kj_30s.sh"
$warmstartInspectorOut = Join-Path $jobDir "inspect_wan22_kj_30s_warmstart.py"

Copy-Item -LiteralPath $resolvedImage -Destination $stagedImage -Force
if ($resolvedBackgroundImage) {
    Copy-Item -LiteralPath $resolvedBackgroundImage -Destination $stagedBackgroundImage -Force
}
Copy-Item -LiteralPath $resolvedWorkflow -Destination $canvasOut -Force
Copy-Item -LiteralPath $bootstrapScript -Destination $bootstrapOut -Force
Copy-Item -LiteralPath $remoteSubmitScript -Destination $remoteSubmitOut -Force
Copy-Item -LiteralPath $warmstartInspectorScript -Destination $warmstartInspectorOut -Force

$segments = @()
for ($index = 1; $index -le $segmentCount; $index += 1) {
    $segmentId = "{0:d2}" -f $index
    $startSeconds = [double](($index - 1) * $SegmentSeconds)
    $remainingSeconds = [math]::Max(0.0, $videoDurationSeconds - $startSeconds)
    $durationSeconds = [math]::Min([double]$SegmentSeconds, $remainingSeconds)
    if ($durationSeconds -le 0) {
        continue
    }

    $segmentVideoName = "reference_segment_$segmentId.mp4"
    $segmentVideoPath = Join-Path $inputDir $segmentVideoName
    New-VideoSegment -InputPath $resolvedVideo -StartSeconds $startSeconds -DurationSeconds $durationSeconds -OutputPath $segmentVideoPath

    $frameLoadCap = ([math]::Max(1, [int][math]::Ceiling($durationSeconds * $videoFrameRate))) + 1
    $runtimeName = "workflow_segment_$segmentId.json"
    $runtimePath = Join-Path $jobDir $runtimeName
    $outputPrefix = "wan22_kj_30s-$JobName-s$segmentId"

    $prepareArgs = @(
        "--input", $canvasOut,
        "--output", $runtimePath,
        "--image-name", $stagedImageName,
        "--video-name", $segmentVideoName,
        "--prompt", $Prompt,
        "--negative-prompt", $NegativePrompt,
        "--seed", "$Seed",
        "--frame-load-cap", "$frameLoadCap",
        "--attention-mode", $AttentionMode,
        "--output-prefix", $outputPrefix
    )
    if ($resolvedBackgroundImage) {
        $prepareArgs += @(
            "--background-image-name", $stagedBackgroundImageName,
            "--background-repeat-amount", "$frameLoadCap",
            "--mask-grow", "$BackgroundMaskGrow"
        )
    }

    & node $prepareScript @prepareArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to prepare KJ segmented workflow runtime json for segment $segmentId."
    }

    $validateArgs = @(
        "--input", $runtimePath,
        "--image-name", $stagedImageName,
        "--video-name", $segmentVideoName
    )
    if ($resolvedBackgroundImage) {
        $validateArgs += @(
            "--background-image-name", $stagedBackgroundImageName,
            "--mask-grow", "$BackgroundMaskGrow"
        )
    }
    & node $validateScript @validateArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to validate KJ segmented workflow runtime json for segment $segmentId."
    }

    $segments += [ordered]@{
        id = $segmentId
        index = $index
        start_seconds = [math]::Round($startSeconds, 3)
        duration_seconds = [math]::Round($durationSeconds, 3)
        frame_load_cap = $frameLoadCap
        input_video_name = $segmentVideoName
        input_video = $segmentVideoPath
        workflow_runtime_name = $runtimeName
        workflow_runtime = $runtimePath
        output_prefix = $outputPrefix
    }
}

if ($segments.Count -lt 1) {
    throw "No valid segments were staged."
}

$manifest = [ordered]@{
    profile = "wan22_kj_30s_segmented"
    job_name = $JobName
    created_at = (Get-Date).ToString("s")
    workflow = [ordered]@{
        canvas_source = $resolvedWorkflow
        canvas_name = [System.IO.Path]::GetFileName($resolvedWorkflow)
        prepare_script = $prepareScript
        source_video_duration_seconds = [math]::Round($videoDurationSeconds, 3)
        segment_seconds = $SegmentSeconds
        force_rate = $videoFrameRate
        attention_mode = $AttentionMode
        seed = $Seed
        background_conditioning = [bool]$resolvedBackgroundImage
        background_image_name = if ($resolvedBackgroundImage) { $stagedBackgroundImageName } else { $null }
        background_repeat_strategy = if ($resolvedBackgroundImage) { "RepeatImageBatch frame_load_cap" } else { $null }
        background_mask_source = if ($resolvedBackgroundImage) { "LoadImageMask alpha from ip_image.png -> InvertMask -> GrowMask" } else { $null }
        background_mask_grow = if ($resolvedBackgroundImage) { $BackgroundMaskGrow } else { $null }
        final_video_node_id = "156"
        prompt_node_id = "164"
        image_node_id = "163"
        background_image_node_id = if ($resolvedBackgroundImage) { "901" } else { $null }
        background_repeat_node_id = if ($resolvedBackgroundImage) { "902" } else { $null }
        alpha_mask_node_id = if ($resolvedBackgroundImage) { "903" } else { $null }
        invert_mask_node_id = if ($resolvedBackgroundImage) { "904" } else { $null }
        grow_mask_node_id = if ($resolvedBackgroundImage -and $BackgroundMaskGrow -ne 0) { "905" } else { $null }
        video_node_id = "178"
        merge_strategy = "ffmpeg concat; transcode fallback"
    }
    segments = @($segments)
    local = [ordered]@{
        job_dir = $jobDir
        input_image = $stagedImage
        background_image = if ($resolvedBackgroundImage) { $stagedBackgroundImage } else { $null }
        prompt = $Prompt
        negative_prompt = $NegativePrompt
        workflow_canvas = $canvasOut
        bootstrap = $bootstrapOut
        remote_submit = $remoteSubmitOut
        warmstart_inspector = $warmstartInspectorOut
    }
    r2 = [ordered]@{
        bucket = $R2Bucket
        public_base_url = $R2PublicBaseUrl
        prefix = "$($R2Prefix.TrimEnd('/'))/$JobName"
        output = "$($R2Prefix.TrimEnd('/'))/$JobName/output"
    }
    remote = [ordered]@{
        run_dir = "/workspace/wan22-kj-30s-run"
        input_dir = "/workspace/ComfyUI/input"
        output_dir = "/workspace/ComfyUI/output"
    }
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestOut -Encoding UTF8

if ($UploadToR2) {
    if ([string]::IsNullOrWhiteSpace($R2AccountId) -or [string]::IsNullOrWhiteSpace($R2AccessKeyId) -or [string]::IsNullOrWhiteSpace($R2SecretAccessKey)) {
        throw "R2 credentials missing for KJ segmented stage upload."
    }
    if (-not (Test-Path -LiteralPath $uploadScript)) {
        throw "Missing upload helper: $uploadScript"
    }

    & D:\code\YuYan\python\python.exe $uploadScript `
        --account-id $R2AccountId `
        --access-key-id $R2AccessKeyId `
        --secret-access-key $R2SecretAccessKey `
        --bucket $R2Bucket `
        --local-path $jobDir `
        --remote-prefix "$($R2Prefix.TrimEnd('/'))/$JobName" `
        --public-base-url $R2PublicBaseUrl

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload KJ segmented staged job to R2."
    }
}

Write-Host "job staged: $jobDir"
Write-Host "manifest: $manifestOut"
Write-Host "image_name=$stagedImageName"
if ($resolvedBackgroundImage) {
    Write-Host "background_image_name=$stagedBackgroundImageName"
    Write-Host "background_mask_source=ip_image_alpha_inverted"
    Write-Host "background_mask_grow=$BackgroundMaskGrow"
}
Write-Host "source_video_duration_seconds=$([math]::Round($videoDurationSeconds, 3))"
Write-Host "segment_seconds=$SegmentSeconds"
Write-Host "segment_count=$($segments.Count)"
foreach ($segment in $segments) {
    Write-Host ("segment_{0}: start={1}s duration={2}s frame_load_cap={3} video={4}" -f $segment.id, $segment.start_seconds, $segment.duration_seconds, $segment.frame_load_cap, $segment.input_video_name)
}
Write-Host "attention_mode=$AttentionMode"
if ($UploadToR2) {
    Write-Host "r2_prefix=$($R2Prefix.TrimEnd('/'))/$JobName"
}
