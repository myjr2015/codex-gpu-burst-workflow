param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [Parameter(Mandatory = $true)]
    [string]$ImagePath,

    [Parameter(Mandatory = $true)]
    [string]$VideoPath,

    [string]$R2Prefix = "runcomfy-inputs/001skills",

    [string]$R2Bucket = "runcomfy",

    [string]$R2PublicBaseUrl = "https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev",

    [string]$R2AccountId = $env:CLOUDFLARE_ACCOUNT_ID,

    [string]$R2AccessKeyId = $env:R2_ACCESS_KEY_ID,

    [string]$R2SecretAccessKey = $env:R2_SECRET_ACCESS_KEY,

    [switch]$UploadToR2
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "node not found. Install Node.js first."
}

$repoRoot = (Resolve-Path ".").Path
$sourceWorkflow = Join-Path $repoRoot "Animate+Wan2.2换风格对口型.json"
$bootstrapScript = Join-Path $repoRoot "scripts\bootstrap_wan22_root_canvas.sh"
$remoteSubmitScript = Join-Path $repoRoot "scripts\remote_submit_wan22_root_canvas.sh"
$prepareScript = Join-Path $repoRoot "scripts\prepare_wan22_root_canvas_prompt.mjs"
$r2UploadScript = Join-Path $repoRoot "scripts\r2_upload.py"
$bundleSourceDir = Join-Path $repoRoot "output\vast-wan22-root-strict-3090b\node-bundles"
$customNodeCacheRoot = Join-Path $repoRoot ".cache\001skills\custom_nodes"

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
    $stagingRoot = Join-Path $env:TEMP ("001skills-bundle-" + $RepoName)

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

foreach ($required in @($sourceWorkflow, $bootstrapScript, $remoteSubmitScript, $prepareScript, $r2UploadScript)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required file: $required"
    }
}
if (-not (Test-Path -LiteralPath $bundleSourceDir)) {
    throw "Missing node bundle directory: $bundleSourceDir"
}

$resolvedImage = (Resolve-Path -LiteralPath $ImagePath).Path
$resolvedVideo = (Resolve-Path -LiteralPath $VideoPath).Path

$jobDir = Join-Path $repoRoot ("output\001skills\" + $JobName)
$inputDir = Join-Path $jobDir "input"
$bundleDir = Join-Path $jobDir "node-bundles"
New-Item -ItemType Directory -Force -Path $inputDir | Out-Null
New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null

foreach ($staleFile in @("onstart_001skills.sh", "vast-create-response.json", "vast-instance.json")) {
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
$manifestOut = Join-Path $jobDir "manifest.json"

Copy-Item -LiteralPath $resolvedImage -Destination $stagedImage -Force
Copy-Item -LiteralPath $resolvedVideo -Destination $stagedVideo -Force
Copy-Item -LiteralPath $sourceWorkflow -Destination $canvasOut -Force
Copy-Item -LiteralPath $bootstrapScript -Destination $bootstrapOut -Force
Copy-Item -LiteralPath $remoteSubmitScript -Destination $remoteSubmitOut -Force
Get-ChildItem -LiteralPath $bundleSourceDir -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $bundleDir $_.Name) -Force
}
New-RepoBundleZip -RepoUrl "https://github.com/city96/ComfyUI-GGUF.git" -RepoName "ComfyUI-GGUF" -DestinationZip (Join-Path $bundleDir "ComfyUI-GGUF.zip")
New-RepoBundleZip -RepoUrl "https://github.com/yolain/ComfyUI-Easy-Use.git" -RepoName "ComfyUI-Easy-Use" -DestinationZip (Join-Path $bundleDir "ComfyUI-Easy-Use.zip")

& node $prepareScript `
    --input $canvasOut `
    --output $runtimeOut `
    --image-name "美女带背景.png" `
    --video-name "光伏2.mp4" `
    --output-prefix ("001skills-" + $JobName)

if ($LASTEXITCODE -ne 0) {
    throw "Failed to prepare workflow runtime json."
}

$manifest = [ordered]@{
    skill = "001skills"
    job_name = $JobName
    created_at = (Get-Date).ToString("s")
    local = [ordered]@{
        job_dir = $jobDir
        input_image = $stagedImage
        input_video = $stagedVideo
        workflow_canvas = $canvasOut
        workflow_runtime = $runtimeOut
        bootstrap = $bootstrapOut
        remote_submit = $remoteSubmitOut
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
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestOut -Encoding UTF8

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
Write-Host "r2 output prefix: $R2Prefix/$JobName/output"
