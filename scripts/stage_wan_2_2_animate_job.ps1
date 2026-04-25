param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [Parameter(Mandatory = $true)]
    [string]$ImagePath,

    [Parameter(Mandatory = $true)]
    [string]$VideoPath,

    [string]$R2Prefix = $(if ($env:ASSET_S3_PREFIX) { $env:ASSET_S3_PREFIX.TrimEnd('/') + "/wan_2_2_animate" } elseif ($env:R2_PREFIX) { $env:R2_PREFIX } else { "runcomfy-inputs/wan_2_2_animate" }),

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
$workflowSourceRel = [string]$profileConfig.profiles."wan_2_2_animate".workflow_source
if ([string]::IsNullOrWhiteSpace($workflowSourceRel)) {
    $workflowSourceRel = "workflows\Animate+Wan2.2换风格对口型.json"
}
$sourceWorkflow = Join-Path $repoRoot $workflowSourceRel
$bootstrapScript = Join-Path $repoRoot "scripts\bootstrap_wan22_root_canvas.sh"
$remoteSubmitScript = Join-Path $repoRoot "scripts\remote_submit_wan22_root_canvas.sh"
$prepareScript = Join-Path $repoRoot "scripts\prepare_wan22_root_canvas_prompt.mjs"
$generateOnstartScript = Join-Path $repoRoot "scripts\generate_wan_2_2_animate_onstart.mjs"
$warmstartInspectorScript = Join-Path $repoRoot "scripts\inspect_wan22_warmstart.py"
$r2UploadScript = Join-Path $repoRoot "scripts\r2_upload.py"
$ffprobePath = Join-Path $repoRoot "node_modules\ffprobe-static\bin\win32\x64\ffprobe.exe"
$bundleSourceDir = Join-Path $repoRoot "output\vast-wan22-root-strict-3090b\node-bundles"
$customNodeCacheRoot = Join-Path $repoRoot ".cache\wan_2_2_animate\custom_nodes"
$requiredBundledZips = @(
    "ComfyUI-KJNodes.zip"
    "ComfyUI-VideoHelperSuite.zip"
    "ComfyUI-WanAnimatePreprocess.zip"
)

function Update-GitRepoCache {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoUrl,

        [Parameter(Mandatory = $true)]
        [string]$CachePath
    )

    if (-not (Test-Path -LiteralPath $CachePath)) {
        git clone --depth 1 --recurse-submodules --shallow-submodules $RepoUrl $CachePath | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone repo: $RepoUrl"
        }
    }
    else {
        git -C $CachePath fetch --depth 1 origin | Out-Null
        git -C $CachePath pull --ff-only | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to update repo cache: $CachePath"
        }
        git -C $CachePath submodule update --init --recursive --depth 1 | Out-Null
    }
}

function New-RepoBundleZip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoUrl,

        [Parameter(Mandatory = $true)]
        [string]$RepoName,

        [Parameter(Mandatory = $true)]
        [string]$DestinationZip
    )

    $cachePath = Join-Path $customNodeCacheRoot $RepoName
    $stagingRoot = Join-Path $env:TEMP ("wan_2_2_animate-bundle-" + $RepoName)

    New-Item -ItemType Directory -Force -Path $customNodeCacheRoot | Out-Null
    Update-GitRepoCache -RepoUrl $RepoUrl -CachePath $cachePath

    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

    Get-ChildItem -LiteralPath $cachePath -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stagingRoot $_.Name) -Recurse -Force
    }

    Get-ChildItem -LiteralPath $stagingRoot -Recurse -Force | Where-Object { $_.Name -eq ".git" } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }

    if (Test-Path -LiteralPath $DestinationZip) {
        Remove-Item -LiteralPath $DestinationZip -Force
    }
    Compress-Archive -Path (Join-Path $stagingRoot "*") -DestinationPath $DestinationZip -Force
}

foreach ($required in @($sourceWorkflow, $bootstrapScript, $remoteSubmitScript, $prepareScript, $generateOnstartScript, $warmstartInspectorScript, $r2UploadScript)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required file: $required"
    }
}
if (-not (Test-Path -LiteralPath $ffprobePath)) {
    throw "Missing ffprobe: $ffprobePath"
}
if (-not (Test-Path -LiteralPath $bundleSourceDir)) {
    throw "Missing node bundle directory: $bundleSourceDir"
}

foreach ($bundleName in $requiredBundledZips) {
    $bundlePath = Join-Path $bundleSourceDir $bundleName
    if (-not (Test-Path -LiteralPath $bundlePath)) {
        throw "Missing required node bundle: $bundlePath"
    }
}

$resolvedImage = (Resolve-Path -LiteralPath $ImagePath).Path
$resolvedVideo = (Resolve-Path -LiteralPath $VideoPath).Path
$videoDurationRaw = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $resolvedVideo
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($videoDurationRaw)) {
    throw "Failed to read video duration with ffprobe: $resolvedVideo"
}
$videoDurationSeconds = [double]$videoDurationRaw
$videoSecondsRounded = [math]::Max(1, [int][math]::Round($videoDurationSeconds))
$videoFrameRate = 16
$frameLoadCap = ($videoSecondsRounded * $videoFrameRate) + 1

$jobDir = Join-Path $repoRoot ("output\wan_2_2_animate\" + $JobName)
$inputDir = Join-Path $jobDir "input"
$bundleDir = Join-Path $jobDir "node-bundles"
New-Item -ItemType Directory -Force -Path $inputDir | Out-Null
New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null

foreach ($staleFile in @("onstart_wan_2_2_animate.sh", "vast-create-response.json", "vast-instance.json")) {
    $stalePath = Join-Path $jobDir $staleFile
    if (Test-Path -LiteralPath $stalePath) {
        Remove-Item -LiteralPath $stalePath -Force
    }
}

$stagedImage = Join-Path $inputDir "美女带背景.png"
$stagedVideo = Join-Path $inputDir "光伏2.mp4"
$canvasOut = Join-Path $jobDir "workflow_canvas.json"
$runtimeOut = Join-Path $jobDir "workflow_runtime.json"
$bootstrapOut = Join-Path $jobDir "bootstrap_wan22_root_canvas.sh"
$remoteSubmitOut = Join-Path $jobDir "remote_submit_wan22_root_canvas.sh"
$warmstartInspectorOut = Join-Path $jobDir "inspect_wan22_warmstart.py"
$manifestOut = Join-Path $jobDir "manifest.json"
$onstartOut = Join-Path $jobDir "onstart_wan_2_2_animate.sh"

Copy-Item -LiteralPath $resolvedImage -Destination $stagedImage -Force
Copy-Item -LiteralPath $resolvedVideo -Destination $stagedVideo -Force
Copy-Item -LiteralPath $sourceWorkflow -Destination $canvasOut -Force
Copy-Item -LiteralPath $bootstrapScript -Destination $bootstrapOut -Force
Copy-Item -LiteralPath $remoteSubmitScript -Destination $remoteSubmitOut -Force
Copy-Item -LiteralPath $warmstartInspectorScript -Destination $warmstartInspectorOut -Force
Get-ChildItem -LiteralPath $bundleSourceDir -File | ForEach-Object {
    if ($requiredBundledZips -contains $_.Name) {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $bundleDir $_.Name) -Force
    }
}
New-RepoBundleZip -RepoUrl "https://github.com/city96/ComfyUI-GGUF.git" -RepoName "ComfyUI-GGUF" -DestinationZip (Join-Path $bundleDir "ComfyUI-GGUF.zip")

& node $prepareScript `
    --input $canvasOut `
    --output $runtimeOut `
    --image-name "美女带背景.png" `
    --video-name "光伏2.mp4" `
    --frame-load-cap $frameLoadCap `
    --output-prefix ("wan_2_2_animate-" + $JobName)

if ($LASTEXITCODE -ne 0) {
    throw "Failed to prepare workflow runtime json."
}

$manifest = [ordered]@{
    profile = "wan_2_2_animate"
    skill = "wan_2_2_animate"
    job_name = $JobName
    created_at = (Get-Date).ToString("s")
    workflow = [ordered]@{
        canvas_source = $sourceWorkflow
        canvas_name = [System.IO.Path]::GetFileName($sourceWorkflow)
        prepare_script = $prepareScript
        source_video_duration_seconds = [math]::Round($videoDurationSeconds, 3)
        source_video_seconds_rounded = $videoSecondsRounded
        force_rate = $videoFrameRate
        frame_load_cap = $frameLoadCap
        bootstrap_template = $bootstrapScript
        remote_submit_template = $remoteSubmitScript
        warmstart_inspector_template = $warmstartInspectorScript
        onstart_generator = $generateOnstartScript
    }
    local = [ordered]@{
        job_dir = $jobDir
        input_image = $stagedImage
        input_video = $stagedVideo
        workflow_canvas = $canvasOut
        workflow_runtime = $runtimeOut
        bootstrap = $bootstrapOut
        remote_submit = $remoteSubmitOut
        warmstart_inspector = $warmstartInspectorOut
        onstart = $onstartOut
        node_bundles = $bundleDir
    }
    r2 = [ordered]@{
        bucket = $R2Bucket
        public_base_url = $R2PublicBaseUrl
        prefix = "$R2Prefix/$JobName"
        input = "$R2Prefix/$JobName/input"
        output = "$R2Prefix/$JobName/output"
    }
    remote = [ordered]@{
        comfy_input_image = "/workspace/ComfyUI/input/美女带背景.png"
        comfy_input_video = "/workspace/ComfyUI/input/光伏2.mp4"
        run_dir = "/workspace/wan22-root-canvas-run"
    }
    automation = [ordered]@{
        profile_config = $profileConfigPath
        run_report = (Join-Path $jobDir "run-report.json")
        timing_summary = (Join-Path $jobDir "timing-summary.json")
    }
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestOut -Encoding UTF8

& node $generateOnstartScript `
    --manifest $manifestOut `
    --output $onstartOut

if ($LASTEXITCODE -ne 0) {
    throw "Failed to generate onstart_wan_2_2_animate.sh."
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
        throw "Failed to upload staged job to R2."
    }
}

Write-Host "job staged: $jobDir"
Write-Host "runtime: $runtimeOut"
Write-Host "video_duration_seconds=$([math]::Round($videoDurationSeconds, 3))"
Write-Host "frame_load_cap=$frameLoadCap"
Write-Host "r2 output prefix: $R2Prefix/$JobName/output"
