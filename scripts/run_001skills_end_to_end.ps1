param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$ImagePath,

    [string]$VideoPath,

    [string]$OfferId,

    [string]$RegistryPath = ".\data\vast-machine-registry.json",

    [string]$SearchQuery = "gpu_name=RTX_3090 num_gpus=1 gpu_ram>=24 cuda_max_good>=12.4 disk_space>180 direct_port_count>=4 rented=False geolocation notin [CN]",

    [switch]$FreshMachine,

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [ValidateSet("1.0-cold", "1.1-machine-registry")]
    [string]$RuntimeVersion = "1.1-machine-registry",

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

    [switch]$WarmStart,

    [int]$DownloadIntervalSeconds = 30,

    [int]$DownloadMaxChecks = 240
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$runnerPath = Join-Path $repoRoot "scripts\run_vast_workflow_job.ps1"
$selectorPath = Join-Path $repoRoot "scripts\select_001skills_vast_offer.ps1"
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
if ([string]::IsNullOrWhiteSpace($R2Prefix) -and $env:ASSET_S3_PREFIX) {
    $R2Prefix = $env:ASSET_S3_PREFIX.TrimEnd("/") + "/001skills"
}
if ([string]::IsNullOrWhiteSpace($R2Bucket) -and $env:ASSET_S3_BUCKET) {
    $R2Bucket = $env:ASSET_S3_BUCKET
}
if ([string]::IsNullOrWhiteSpace($R2PublicBaseUrl) -and $env:ASSET_S3_PUBLIC_BASE_URL) {
    $R2PublicBaseUrl = $env:ASSET_S3_PUBLIC_BASE_URL
}
if ([string]::IsNullOrWhiteSpace($R2AccessKeyId) -and $env:ASSET_S3_ACCESS_KEY_ID) {
    $R2AccessKeyId = $env:ASSET_S3_ACCESS_KEY_ID
}
if ([string]::IsNullOrWhiteSpace($R2SecretAccessKey) -and $env:ASSET_S3_SECRET_ACCESS_KEY) {
    $R2SecretAccessKey = $env:ASSET_S3_SECRET_ACCESS_KEY
}
$R2AccountId = Resolve-R2AccountId -CloudflareAccountId $R2AccountId -AssetAccountId $env:ASSET_S3_ACCOUNT_ID -Endpoint $env:ASSET_S3_ENDPOINT

Write-Host "runtime_version=$RuntimeVersion"
Write-Host "runtime_image=$Image"

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
        $selectionJson = & pwsh -File $selectorPath `
            -RegistryPath $RegistryPath `
            -SearchQuery $SearchQuery `
            -Storage $DiskGb `
            -ExcludeKnownMachines:$FreshMachine
        if ($LASTEXITCODE -ne 0) {
            throw "Automatic Vast offer selection failed."
        }

        $selection = $selectionJson | ConvertFrom-Json
        if (-not $selection.offer_id) {
            throw "Automatic Vast offer selection returned no offer_id."
        }

        $OfferId = [string]$selection.offer_id
        if ($selection.warm_start) {
            if ($RuntimeVersion -ne "1.0-cold" -and -not $FreshMachine) {
                $WarmStart = $true
            }
        }
        Write-Host "selection_mode=$($selection.selection_mode)"
        Write-Host "selection_reason=$($selection.selection_reason)"
        Write-Host "selected_offer_id=$OfferId"
        Write-Host "selected_machine_id=$($selection.machine_id)"
        Write-Host "selected_host_id=$($selection.host_id)"
        Write-Host "warm_start=$([int][bool]$WarmStart)"
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
    if ($WarmStart) {
        $launchArgs += "-WarmStart"
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
    MachineRegistryPath = $RegistryPath
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
