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

    [switch]$UploadToR2
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$pythonPath = "D:\code\YuYan\python\python.exe"
$assetBuilder = Join-Path $repoRoot "scripts\build_ltx23_matte_action_assets.py"
$selfCheckScript = Join-Path $repoRoot "scripts\check_ltx23_matte_action_prepare.py"
$stageScript = Join-Path $repoRoot "scripts\stage_ltx23_talking_head_job.ps1"

foreach ($required in @($pythonPath, $assetBuilder, $selfCheckScript, $stageScript)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required file: $required"
    }
}

$resolvedSourceVideo = (Resolve-Path -LiteralPath $SourceVideoPath).Path
$resolvedSpeakerImage = (Resolve-Path -LiteralPath $SpeakerImagePath).Path
$resolvedAudio = (Resolve-Path -LiteralPath $AudioPath).Path

$assetDir = Join-Path $repoRoot ("output\ltx23_talking_head_smoke\_matte_action_assets\" + $JobName)
New-Item -ItemType Directory -Force -Path $assetDir | Out-Null

$builderArgs = @(
    $assetBuilder,
    "--job-name", $JobName,
    "--source-video", $resolvedSourceVideo,
    "--speaker-image", $resolvedSpeakerImage,
    "--output-dir", $assetDir,
    "--start-seconds", $StartSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "--duration-seconds", $DurationSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "--fps", $Fps.ToString(),
    "--output-width", $OutputWidth.ToString(),
    "--output-height", $OutputHeight.ToString()
)
if (-not [string]::IsNullOrWhiteSpace($BackgroundPrompt)) {
    $builderArgs += @("--background-prompt", $BackgroundPrompt)
}

& $pythonPath @builderArgs
if ($LASTEXITCODE -ne 0) {
    throw "Failed to build LTX2.3 matte action assets."
}

$assetManifestPath = Join-Path $assetDir "matte_action_assets_manifest.json"
if (-not (Test-Path -LiteralPath $assetManifestPath)) {
    throw "Asset manifest was not created: $assetManifestPath"
}

$assetManifest = Get-Content -Raw -LiteralPath $assetManifestPath | ConvertFrom-Json
if ([string]$assetManifest.method -like "fallback_*" -or -not [bool]$assetManifest.segmentation.real_backend) {
    throw "Matte action assets used non-production segmentation backend: $($assetManifest.method)"
}

$anchorPath = [string]$assetManifest.artifacts.anchor_png
$referenceVideoPath = [string]$assetManifest.artifacts.reference_video
$positivePrompt = [string]$assetManifest.positive_prompt

foreach ($artifact in @($anchorPath, $referenceVideoPath)) {
    if (-not (Test-Path -LiteralPath $artifact)) {
        throw "Missing generated artifact: $artifact"
    }
}

$stageArgs = @(
    "-JobName", $JobName,
    "-ImagePath", $anchorPath,
    "-AudioPath", $resolvedAudio,
    "-ActionMimic",
    "-ReferenceVideoPath", $referenceVideoPath,
    "-OutputWidth", $OutputWidth.ToString(),
    "-OutputHeight", $OutputHeight.ToString(),
    "-DurationSeconds", $DurationSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-Fps", $Fps.ToString(),
    "-PositivePrompt", $positivePrompt,
    "-ActionGuideStrength", $ActionGuideStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-ActionLoraStrength", $ActionLoraStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-IdentityLoraStrength", $IdentityLoraStrength.ToString([System.Globalization.CultureInfo]::InvariantCulture),
    "-IdentityGuidanceScale", $IdentityGuidanceScale.ToString([System.Globalization.CultureInfo]::InvariantCulture)
)
if ($UploadToR2) {
    $stageArgs += "-UploadToR2"
}

& pwsh -File $stageScript @stageArgs
if ($LASTEXITCODE -ne 0) {
    throw "Failed to stage LTX2.3 matte action job."
}

$jobDir = Join-Path $repoRoot ("output\ltx23_talking_head_smoke\" + $JobName)
$runtimeMetadataPath = Join-Path $jobDir "workflow_runtime.metadata.json"
$manifestPath = Join-Path $jobDir "manifest.json"
if (-not (Test-Path -LiteralPath $runtimeMetadataPath)) {
    throw "Missing staged runtime metadata: $runtimeMetadataPath"
}
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Missing staged manifest: $manifestPath"
}

$metadata = Get-Content -Raw -LiteralPath $runtimeMetadataPath | ConvertFrom-Json
if (-not [bool]$metadata.action_guide_node_count -or [int]$metadata.action_guide_node_count -lt 1) {
    throw "Prepared runtime is missing LTXAddVideoICLoRAGuide."
}
if ([string]$metadata.input_reference_video_name -ne "reference_video.mp4") {
    throw "Prepared runtime does not point to the staged reference video."
}
if ([string]$metadata.input_audio_name -ne "speech.wav") {
    throw "Prepared runtime does not point to staged speech.wav."
}

& $pythonPath $selfCheckScript --asset-manifest $assetManifestPath --job-dir $jobDir
if ($LASTEXITCODE -ne 0) {
    throw "LTX2.3 matte action prepare self-check failed."
}

Write-Host "matte_action_assets=$assetManifestPath"
Write-Host "ltx23_job_manifest=$manifestPath"
Write-Host "ltx23_runtime_metadata=$runtimeMetadataPath"
Write-Host "reference_video=$referenceVideoPath"
Write-Host "anchor_image=$anchorPath"
Write-Host "ltx23_self_check=passed"
Write-Host "frame_count=$($metadata.frame_count)"
Write-Host "expected_video_seconds=$($metadata.expected_video_seconds)"
Write-Host "action_guide_strength=$($metadata.action_guide_strength)"
Write-Host "action_lora_strength=$($metadata.action_lora_strength)"
