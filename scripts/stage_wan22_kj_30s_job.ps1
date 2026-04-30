param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$ImagePath = ".\素材资产\美女图无背景纯色\纯色站着.png",

    [string]$VideoPath = ".\素材资产\原视频\光伏30s.mp4",

    [string]$Prompt = "女孩在光伏发电场景中自然口播介绍产品，保持人物身份一致，参考视频中的动作、表情和节奏，画面稳定，真实自然。",

    [string]$WorkflowSource = ".\workflows\书墨-30s长视频-wan2-2AnimateKJ版_v2版-参考动作、表情.json",

    [ValidateSet("sdpa", "sageattn", "comfy")]
    [string]$AttentionMode = "sdpa",

    [switch]$UploadToR2,

    [string]$R2Prefix = $(if ($env:ASSET_S3_PREFIX) { $env:ASSET_S3_PREFIX.TrimEnd("/") + "/wan22_kj_30s" } elseif ($env:R2_PREFIX) { $env:R2_PREFIX.TrimEnd("/") + "/wan22_kj_30s" } else { "runcomfy-inputs/wan22_kj_30s" }),

    [string]$R2Bucket = $(if ($env:ASSET_S3_BUCKET) { $env:ASSET_S3_BUCKET } elseif ($env:R2_BUCKET) { $env:R2_BUCKET } else { "runcomfy" }),

    [string]$R2PublicBaseUrl = $(if ($env:ASSET_S3_PUBLIC_BASE_URL) { $env:ASSET_S3_PUBLIC_BASE_URL } elseif ($env:R2_PUBLIC_BASE_URL) { $env:R2_PUBLIC_BASE_URL } else { "https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev" }),

    [string]$R2AccountId = $(if ($env:CLOUDFLARE_ACCOUNT_ID) { $env:CLOUDFLARE_ACCOUNT_ID } elseif ($env:ASSET_S3_ACCOUNT_ID) { $env:ASSET_S3_ACCOUNT_ID } else { "" }),

    [string]$R2AccessKeyId = $(if ($env:R2_ACCESS_KEY_ID) { $env:R2_ACCESS_KEY_ID } elseif ($env:ASSET_S3_ACCESS_KEY_ID) { $env:ASSET_S3_ACCESS_KEY_ID } else { "" }),

    [string]$R2SecretAccessKey = $(if ($env:R2_SECRET_ACCESS_KEY) { $env:R2_SECRET_ACCESS_KEY } elseif ($env:ASSET_S3_SECRET_ACCESS_KEY) { $env:ASSET_S3_SECRET_ACCESS_KEY } else { "" })
)

$ErrorActionPreference = "Stop"

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

$ffprobeCandidates = @(
    (Join-Path $repoRoot "node_modules\ffprobe-static\bin\win32\x64\ffprobe.exe"),
    "D:\code\KuangJia\ffmpeg\ffprobe.exe"
)
$ffprobePath = $ffprobeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($ffprobePath)) {
    throw "Missing ffprobe. Checked: $($ffprobeCandidates -join ', ')"
}
$prepareScript = Join-Path $repoRoot "scripts\prepare_wan22_kj_30s_prompt.mjs"
$validateScript = Join-Path $repoRoot "scripts\validate_wan22_kj_30s_runtime.mjs"
$bootstrapScript = Join-Path $repoRoot "scripts\bootstrap_wan22_kj_30s.sh"
$remoteSubmitScript = Join-Path $repoRoot "scripts\remote_submit_wan22_kj_30s.sh"
$warmstartInspectorScript = Join-Path $repoRoot "scripts\inspect_wan22_kj_30s_warmstart.py"
$uploadScript = Join-Path $repoRoot "scripts\r2_upload.py"

foreach ($required in @($ffprobePath, $prepareScript, $validateScript, $bootstrapScript, $remoteSubmitScript, $warmstartInspectorScript, $WorkflowSource, $ImagePath, $VideoPath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required file: $required"
    }
}

$resolvedWorkflow = (Resolve-Path -LiteralPath $WorkflowSource).Path
$resolvedImage = (Resolve-Path -LiteralPath $ImagePath).Path
$resolvedVideo = (Resolve-Path -LiteralPath $VideoPath).Path

$videoDurationRaw = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $resolvedVideo
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($videoDurationRaw)) {
    throw "Failed to read video duration with ffprobe: $resolvedVideo"
}

$videoDurationSeconds = [double]$videoDurationRaw
$videoFrameRate = 16
$frameLoadCap = ([math]::Max(1, [int][math]::Ceiling($videoDurationSeconds * $videoFrameRate))) + 1

$jobDir = Join-Path $repoRoot ("output\wan22_kj_30s\" + $JobName)
$inputDir = Join-Path $jobDir "input"
New-Item -ItemType Directory -Force -Path $inputDir | Out-Null

$stagedImageName = "ip_image.png"
$stagedVideoName = "reference_30s.mp4"
$stagedImage = Join-Path $inputDir $stagedImageName
$stagedVideo = Join-Path $inputDir $stagedVideoName
$canvasOut = Join-Path $jobDir "workflow_canvas.json"
$runtimeOut = Join-Path $jobDir "workflow_runtime.json"
$manifestOut = Join-Path $jobDir "manifest.json"
$bootstrapOut = Join-Path $jobDir "bootstrap_wan22_kj_30s.sh"
$remoteSubmitOut = Join-Path $jobDir "remote_submit_wan22_kj_30s.sh"
$warmstartInspectorOut = Join-Path $jobDir "inspect_wan22_kj_30s_warmstart.py"

Copy-Item -LiteralPath $resolvedImage -Destination $stagedImage -Force
Copy-Item -LiteralPath $resolvedVideo -Destination $stagedVideo -Force
Copy-Item -LiteralPath $resolvedWorkflow -Destination $canvasOut -Force
Copy-Item -LiteralPath $bootstrapScript -Destination $bootstrapOut -Force
Copy-Item -LiteralPath $remoteSubmitScript -Destination $remoteSubmitOut -Force
Copy-Item -LiteralPath $warmstartInspectorScript -Destination $warmstartInspectorOut -Force

& node $prepareScript `
    --input $canvasOut `
    --output $runtimeOut `
    --image-name $stagedImageName `
    --video-name $stagedVideoName `
    --prompt $Prompt `
    --frame-load-cap "$frameLoadCap" `
    --attention-mode $AttentionMode `
    --output-prefix ("wan22_kj_30s-" + $JobName)

if ($LASTEXITCODE -ne 0) {
    throw "Failed to prepare KJ 30s workflow runtime json."
}

& node $validateScript --input $runtimeOut
if ($LASTEXITCODE -ne 0) {
    throw "Failed to validate KJ 30s workflow runtime json."
}

$manifest = [ordered]@{
    profile = "wan22_kj_30s"
    job_name = $JobName
    created_at = (Get-Date).ToString("s")
    workflow = [ordered]@{
        canvas_source = $resolvedWorkflow
        canvas_name = [System.IO.Path]::GetFileName($resolvedWorkflow)
        prepare_script = $prepareScript
        source_video_duration_seconds = [math]::Round($videoDurationSeconds, 3)
        force_rate = $videoFrameRate
        frame_load_cap = $frameLoadCap
        attention_mode = $AttentionMode
        final_video_node_id = "156"
        prompt_node_id = "164"
        image_node_id = "163"
        video_node_id = "178"
    }
    local = [ordered]@{
        job_dir = $jobDir
        input_image = $stagedImage
        input_video = $stagedVideo
        prompt = $Prompt
        workflow_canvas = $canvasOut
        workflow_runtime = $runtimeOut
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

$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestOut -Encoding UTF8

if ($UploadToR2) {
    if ([string]::IsNullOrWhiteSpace($R2AccountId) -or [string]::IsNullOrWhiteSpace($R2AccessKeyId) -or [string]::IsNullOrWhiteSpace($R2SecretAccessKey)) {
        throw "R2 credentials missing for KJ 30s stage upload."
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
        throw "Failed to upload KJ 30s staged job to R2."
    }
}

Write-Host "job staged: $jobDir"
Write-Host "runtime: $runtimeOut"
Write-Host "image_name=$stagedImageName"
Write-Host "video_name=$stagedVideoName"
Write-Host "video_duration_seconds=$([math]::Round($videoDurationSeconds, 3))"
Write-Host "frame_load_cap=$frameLoadCap"
Write-Host "attention_mode=$AttentionMode"
if ($UploadToR2) {
    Write-Host "r2_prefix=$($R2Prefix.TrimEnd('/'))/$JobName"
}
