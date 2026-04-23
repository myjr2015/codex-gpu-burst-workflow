param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$ImagePath,

    [string]$VideoPath,

    [string]$OfferId,

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [string]$Label = "001skills-job",

    [int]$DiskGb = 180,

    [string[]]$MountArgs = @(),

    [string]$R2Prefix = $(if ($env:ASSET_S3_PREFIX) { $env:ASSET_S3_PREFIX.TrimEnd('/') + "/001skills" } elseif ($env:R2_PREFIX) { $env:R2_PREFIX } else { "runcomfy-inputs/001skills" }),

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
if (-not (Test-Path -LiteralPath $runnerPath)) {
    throw "Missing runner: $runnerPath"
}

$stageArgs = @()
if (-not $SkipStage) {
    if ([string]::IsNullOrWhiteSpace($ImagePath) -or [string]::IsNullOrWhiteSpace($VideoPath)) {
        throw "ImagePath and VideoPath are required unless -SkipStage is used."
    }

    $stageArgs += @(
        "-ImagePath", (Resolve-Path -LiteralPath $ImagePath).Path,
        "-VideoPath", (Resolve-Path -LiteralPath $VideoPath).Path,
        "-R2Prefix", $R2Prefix,
        "-R2Bucket", $R2Bucket,
        "-R2PublicBaseUrl", $R2PublicBaseUrl
    )
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
    if ([string]::IsNullOrWhiteSpace($OfferId)) {
        throw "OfferId is required unless -SkipLaunch is used."
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
    Profile = "001skills"
    JobName = $JobName
    SkipStage = [bool]$SkipStage
    SkipLaunch = [bool]$SkipLaunch
    SkipDownload = [bool]$SkipDownload
    SkipPublish = [bool]$SkipPublish
    DestroyInstance = [bool]$DestroyInstance
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

if ($LASTEXITCODE -ne 0) {
    throw "run_vast_workflow_job.ps1 failed."
}
